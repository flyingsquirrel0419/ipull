import Foundation

/// Guest-OS service shims for the SAP runtime. When emulated code calls an
/// imported symbol (malloc, CFString*, objc_msgSend, …), the call lands on a
/// trampoline address in a mapped "shim region"; a code hook on that region
/// dispatches to the Swift handler, which reads/writes guest registers and
/// memory, then redirects RIP back to the caller's return address.
///
/// Behavior modeled after ipatool's machine/shim_*.go (MIT).
public final class SAPShims {

    public enum Error: Swift.Error {
        case dispatchFailed(String)
    }

    /// x86-64 trampoline stub: a single `int3`-style byte we hook on.
    /// Unicorn code hooks fire per instruction; the hook checks whether RIP
    /// is inside the shim region and dispatches by address.
    static let shimBase: UInt64 = 0x0000200000000000
    static let shimCodeSize: UInt64 = 0x80000
    static let shimSize: UInt64 = 0x100000
    static let slotSize: UInt64 = 16

    public typealias Handler = (SAPShims) throws -> Void

    private struct Entry {
        let names: [String]
        let handler: Handler
        let address: UInt64
    }

    let engine: UnicornEngine
    private var entriesByAddress: [UInt64: Entry] = [:]
    private var symbols: [String: UInt64] = [:]
    private var codeCursor: UInt64 = shimBase
    private var dataCursor: UInt64 = shimBase + shimCodeSize
    private var hookID: UInt64?

    /// Monotonic fake-handle counter for opaque object references returned
    /// to the guest (CF objects, IO iterators, …).
    var fakeHandle: UInt64 = 0xF0F0_0000_0000_0000

    /// errno cell inside the guest address space.
    public private(set) var errnoAddress: UInt64 = 0

    /// CoreFP.icxs bytes served to the guest through open()/read().
    public var icxsData = Data()

    /// Resolve a symbol in the loaded guest images (set by SAPRuntime).
    public var imageSymbolResolver: ((String) -> UInt64?)?

    /// CoreFP export addresses (set by SAPRuntime) for dlsym.
    public var coreFPExports: [String: UInt64] = [:]

    static let coreFPPath = "./CoreFP"
    static let fakeCoreFPHandle: UInt64 = 0xC0DE_F00D
    var icxsOffset = 0
    static let coreFPIcxsPath = "./../CoreFP.icxs"
    static let coreFPFileDescriptor: UInt64 = 0x4943_5853  // "ICXS"

    /// Last shim fault — surfaced by the runtime after emu stops.
    public var fault: Error?

    public init(engine: UnicornEngine) throws {
        self.engine = engine
        try engine.map(address: Self.shimBase, size: Self.shimSize)
        try registerPlatformServices()
        try installHook()
    }

    // MARK: - Registration

    func register(names: [String], handler: @escaping Handler) throws {
        let address = codeCursor
        // One-byte stub; the hook dispatches on the address before execute.
        try engine.write(address: address, data: Data([0xC3])) // ret — hook fires first
        codeCursor += Self.slotSize
        let entry = Entry(names: names, handler: handler, address: address)
        entriesByAddress[address] = entry
        for name in names {
            symbols[name] = address
        }
    }

    /// Register an inert data cell for a constant object reference
    /// (kCF*/NS*/CSSM OID symbols — read as addresses, never called).
    @discardableResult
    public func addData(_ name: String, contents: Data = Data(count: 8)) throws -> UInt64 {
        if let existing = symbols[name] { return existing }
        dataCursor = (dataCursor + 7) & ~UInt64(7)
        let address = dataCursor
        dataCursor += UInt64(max(contents.count, 8))
        try engine.write(address: address, data: contents)
        symbols[name] = address
        return address
    }

    /// Resolve an imported symbol name to its shim address.
    public func address(of symbol: String) -> UInt64? {
        symbols[symbol]
    }

    /// Resolve like ipatool: known symbols return their slot; unknown imports
    /// get a trap slot whose handler records a fault and stops emulation with
    /// a clear error instead of jumping to address 0.
    public func resolve(_ symbol: String) throws -> UInt64 {
        if let existing = symbols[symbol] { return existing }
        let address = codeCursor
        try engine.write(address: address, data: Data([0xC3]))
        codeCursor += Self.slotSize
        let entry = Entry(names: [symbol], handler: { shims in
            shims.fault = .dispatchFailed("unsupported import: \(symbol)")
            throw Error.dispatchFailed("unsupported import: \(symbol)")
        }, address: address)
        entriesByAddress[address] = entry
        symbols[symbol] = address
        return address
    }

    private func installHook() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        hookID = try engine.addCodeHook(
            begin: Self.shimBase,
            end: Self.shimBase + Self.shimCodeSize - 1,
            callback: { address, _, userData in
                guard let userData else { return }
                let shims = Unmanaged<SAPShims>.fromOpaque(userData).takeUnretainedValue()
                shims.dispatch(at: address)
            },
            userData: selfPtr
        )
    }

    private func dispatch(at address: UInt64) {
        guard let entry = entriesByAddress[address] else {
            // Unknown shim slot — trap loudly by stopping emulation.
            engine.stop()
            return
        }
        do {
            try entry.handler(self)
            try returnToCaller()
        } catch let error as Error {
            fault = error
            engine.stop()
        } catch {
            fault = .dispatchFailed("unknown shim failure")
            engine.stop()
        }
    }

    /// Pop the return address from the guest stack and resume there.
    private func returnToCaller() throws {
        let rsp = try engine.read(.rsp)
        let bytes = try engine.read(address: rsp, size: 8)
        let returnAddress = bytes.withUnsafeBytes { $0.load(as: UInt64.self) }
        try engine.write(.rsp, rsp + 8)
        try engine.write(.rip, returnAddress)
    }

    // MARK: - Guest helpers

    /// Read a null-terminated UTF-8 string from guest memory.
    public func readGuestString(at address: UInt64, maxLength: Int = 4096) throws -> String {
        var bytes: [UInt8] = []
        var cursor = address
        while bytes.count < maxLength {
            let chunk = try engine.read(address: cursor, size: 1)
            if chunk[0] == 0 { break }
            bytes.append(chunk[0])
            cursor += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func writeGuestString(_ string: String, at address: UInt64) throws {
        var bytes = Data(string.utf8)
        bytes.append(0)
        try engine.write(address: address, data: bytes)
    }

    public func setReturn(_ value: UInt64) throws {
        try engine.write(.rax, value)
    }

    public func argument(_ index: Int) throws -> UInt64 {
        // x86-64 SysV: rdi, rsi, rdx, rcx, r8, r9
        let regs: [UnicornEngine.Register] = [.rdi, .rsi, .rdx, .rcx, .r8, .r9]
        guard index < regs.count else { throw Error.dispatchFailed("arg\(index)") }
        return try engine.read(regs[index])
    }

    // MARK: - Platform services (behavior from ipatool shim_platform.go)

    private func registerPlatformServices() throws {
        // Grouped exactly like the reference implementation.
        try register(names: ["_CFBundleGetMainBundle", "_CFDataGetBytePtr", "_CFDataGetLength",
                             "_CFStringGetLength", "_CFStringGetMaximumSizeForEncoding",
                             "_CFUUIDCreateString", "_IORegistryEntryFromPath",
                             "_IORegistryEntrySearchCFProperty", "_IOServiceMatching",
                             "_getenv", "_pthread_self"]) { try $0.setReturn(0) }

        try register(names: ["_CFDictionaryGetValue", "_DADiskCopyDescription",
                             "_DADiskCreateFromBSDName", "_DASessionCreate",
                             "_IORegistryEntryCreateCFProperty"]) { shims in
            shims.fakeHandle &+= 8
            try shims.setReturn(shims.fakeHandle)
        }

        try register(names: ["_CFRelease", "_IOObjectRelease", "_close", "_close$UNIX2003",
                             "_pthread_mutex_lock", "_pthread_mutex_unlock",
                             "_pthread_rwlock_init", "_pthread_rwlock_init$UNIX2003",
                             "_pthread_rwlock_unlock", "_pthread_rwlock_unlock$UNIX2003",
                             "_pthread_rwlock_wrlock", "_pthread_rwlock_wrlock$UNIX2003"]) {
            try $0.setReturn(0)
        }

        try register(names: ["_CFStringCreateWithCString"]) { shims in
            // Read C string arg, copy into guest data area, return pointer.
            let source = try shims.argument(0)
            let text = try shims.readGuestString(at: source)
            let address = shims.dataCursor
            shims.dataCursor += UInt64(text.utf8.count + 8)
            try shims.writeGuestString(text, at: address)
            try shims.setReturn(address)
        }

        try register(names: ["_CFStringGetCString"]) { shims in
            let source = try shims.argument(0)
            let dest = try shims.argument(1)
            let text = try shims.readGuestString(at: source)
            try shims.writeGuestString(text, at: dest)
            try shims.setReturn(1)
        }

        try register(names: ["_arc4random"]) { shims in
            try shims.setReturn(UInt64(UInt32.random(in: 0...UInt32.max)))
        }

        try register(names: ["_gettimeofday"]) { shims in
            let timeval = try shims.argument(0)
            if timeval != 0 {
                let now = Date().timeIntervalSince1970
                var tv = Data(count: 16)
                tv.withUnsafeMutableBytes { ptr in
                    ptr.storeBytes(of: UInt64(now), toByteOffset: 0, as: UInt64.self)
                    ptr.storeBytes(of: UInt64(now.truncatingRemainder(dividingBy: 1) * 1_000_000),
                                   toByteOffset: 8, as: UInt64.self)
                }
                try shims.engine.write(address: timeval, data: tv)
            }
            try shims.setReturn(0)
        }

        // File shim for CoreFP.icxs (the guest reads it from "disk").
        try register(names: ["_open", "_open$UNIX2003"]) { shims in
            let pathAddress = try shims.argument(0)
            let path = try shims.readGuestString(at: pathAddress)
            if path == Self.coreFPIcxsPath {
                shims.icxsOffset = 0
                try shims.setReturn(Self.coreFPFileDescriptor)
            } else {
                try shims.setReturn(UInt64(bitPattern: -1))
            }
        }

        try register(names: ["_read", "_read$UNIX2003"]) { shims in
            let descriptor = try shims.argument(0)
            let buffer = try shims.argument(1)
            let requested = Int(try shims.argument(2))
            guard descriptor == Self.coreFPFileDescriptor else {
                try shims.setReturn(UInt64(bitPattern: -1))
                return
            }
            let remaining = shims.icxsData.count - shims.icxsOffset
            let size = min(requested, max(remaining, 0))
            if size > 0 {
                let chunk = shims.icxsData.subdata(in: shims.icxsOffset..<(shims.icxsOffset + size))
                try shims.engine.write(address: buffer, data: chunk)
                shims.icxsOffset += size
            }
            try shims.setReturn(UInt64(size))
        }

        try register(names: ["_pthread_once"]) { shims in
            let control = try shims.argument(0)
            let initializer = try shims.argument(1)
            let current = try shims.engine.read(address: control, size: 8)
                .withUnsafeBytes { $0.load(as: UInt64.self) }
            if current != 0 {
                // Call the initializer once by pushing it as the return target.
                try shims.engine.write(address: control,
                                       data: withUnsafeBytes(of: UInt64(0).littleEndian) { Data($0) })
                var rsp = try shims.engine.read(.rsp)
                rsp -= 8
                try shims.engine.write(address: rsp,
                                       data: withUnsafeBytes(of: initializer.littleEndian) { Data($0) })
                try shims.engine.write(.rsp, rsp)
            }
            try shims.setReturn(0)
        }

        try register(names: ["_IOIteratorNext"]) { shims in
            // Return 0 (no more items) — iterator exhaustion.
            try shims.setReturn(0)
        }
        try register(names: ["_IORegistryEntryGetParentEntry"]) { shims in
            let out = try shims.argument(1)
            if out != 0 {
                try shims.engine.write(address: out,
                                       data: withUnsafeBytes(of: UInt64(0).littleEndian) { Data($0) })
            }
            try shims.setReturn(0)
        }
        try register(names: ["_IOServiceGetMatchingServices"]) { shims in
            let iteratorOut = try shims.argument(2)
            if iteratorOut != 0 {
                try shims.engine.write(address: iteratorOut,
                                       data: withUnsafeBytes(of: UInt64(0).littleEndian) { Data($0) })
            }
            try shims.setReturn(0)
        }
        try register(names: ["_IOServiceGetMatchingService"]) { shims in
            try shims.setReturn(UInt64(UInt32.max))
        }
        try register(names: ["_OSAtomicCompareAndSwap32Barrier"]) { shims in
            let oldValue = try shims.argument(0)
            let address = try shims.argument(2)
            let current = try shims.engine.read(address: address, size: 4)
                .withUnsafeBytes { $0.load(as: UInt32.self) }
            let matched = UInt64(current) == (oldValue & 0xFFFFFFFF)
            if matched {
                let newValue = UInt32(truncatingIfNeeded: try shims.argument(1))
                try shims.engine.write(address: address,
                                       data: withUnsafeBytes(of: newValue.littleEndian) { Data($0) })
            }
            try shims.setReturn(matched ? 1 : 0)
        }
        try register(names: ["___error"]) { shims in
            try shims.setReturn(shims.errnoAddress)
        }

        try register(names: ["_abort"]) { shims in
            shims.fault = .dispatchFailed("guest called abort")
            throw Error.dispatchFailed("guest called abort")
        }
        try register(names: ["___stack_chk_fail"]) { shims in
            shims.fault = .dispatchFailed("stack canary check failed")
            throw Error.dispatchFailed("stack canary check failed")
        }
        try register(names: ["dyld_stub_binder"]) { shims in
            shims.fault = .dispatchFailed("dyld_stub_binder called (unpatched lazy stub)")
            throw Error.dispatchFailed("dyld_stub_binder called")
        }

        try register(names: ["_dlopen"]) { shims in
            let pathAddress = try shims.argument(0)
            let path = try shims.readGuestString(at: pathAddress)
            if path == Self.coreFPPath {
                try shims.setReturn(Self.fakeCoreFPHandle)
            } else {
                try shims.setReturn(0)
            }
        }

        try register(names: ["_dlsym"]) { shims in
            // ipatool: resolve "_" + name in the CoreFP export table only.
            let nameAddress = try shims.argument(1)
            let symbol = "_" + (try shims.readGuestString(at: nameAddress))
            let address = shims.coreFPExports[symbol] ?? 0
            try shims.setReturn(address)
        }

        try register(names: ["_sysctlbyname"]) { shims in
            let nameAddress = try shims.argument(0)
            let oldp = try shims.argument(1)
            let oldlenp = try shims.argument(2)
            let name = try shims.readGuestString(at: nameAddress)
            if name == "kern.osversion", oldp != 0 {
                try shims.writeGuestString("24C5089c", at: oldp)
                if oldlenp != 0 {
                    try shims.engine.write(address: oldlenp,
                                           data: withUnsafeBytes(of: UInt64(9).littleEndian) { Data($0) })
                }
            }
            try shims.setReturn(0)
        }

        // Objective-C runtime stubs — the guest calls objc_msgSend for a
        // couple of read-only lookups; returning 0/nil is safe for the SAP
        // signing path (verified by the reference implementation's handler).
        try register(names: ["_objc_msgSend", "_objc_msgSendSuper2", "_objc_msgSend_fixup"]) { shims in
            try shims.setReturn(0)
        }
        try register(names: ["_objc_retain", "_objc_release", "_objc_retainAutoreleasedReturnValue",
                             "_objc_autoreleasePoolPush"]) { shims in
            try shims.setReturn(0)
        }
        try register(names: ["_objc_autoreleasePoolPop", "_objc_storeStrong"]) { shims in
            try shims.setReturn(0)
        }
        try register(names: ["_NSClassFromString", "_NSSelectorFromString"]) { shims in
            try shims.setReturn(0)
        }
        try register(names: ["_pthread_rwlock_rdlock", "_pthread_rwlock_destroy"]) { shims in
            try shims.setReturn(0)
        }

        // errno cell + stack guard + well-known const addresses
        errnoAddress = dataCursor
        dataCursor += 8
        let stackGuard = Data([0xA5, 0x71, 0x3C, 0xD9, 0x86, 0x42, 0xEF, 0x10])
        let guardAddress = dataCursor
        dataCursor += 8
        try engine.write(address: guardAddress, data: stackGuard)
        symbols["___stack_chk_guard"] = guardAddress

        for name in ["_kCFAllocatorDefault", "_kCFAllocatorNull",
                     "_kDADiskDescriptionVolumeUUIDKey", "_kIOMasterPortDefault"] {
            symbols[name] = dataCursor
            dataCursor += 8
        }
    }
}
