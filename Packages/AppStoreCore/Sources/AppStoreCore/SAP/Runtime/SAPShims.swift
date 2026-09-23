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

    private let engine: UnicornEngine
    private var entriesByAddress: [UInt64: Entry] = [:]
    private var symbols: [String: UInt64] = [:]
    private var codeCursor: UInt64 = shimBase
    private var dataCursor: UInt64 = shimBase + shimCodeSize
    private var hookID: UInt64?

    /// Monotonic fake-handle counter for opaque object references returned
    /// to the guest (CF objects, IO iterators, …).
    private var fakeHandle: UInt64 = 0xF0F0_0000_0000_0000

    /// errno cell inside the guest address space.
    public private(set) var errnoAddress: UInt64 = 0

    public init(engine: UnicornEngine) throws {
        self.engine = engine
        try engine.map(address: Self.shimBase, size: Self.shimSize)
        try registerPlatformServices()
        try installHook()
    }

    // MARK: - Registration

    private func register(names: [String], handler: @escaping Handler) throws {
        let address = codeCursor
        // One-byte stub; the hook dispatches on the address before execute.
        try engine.write(address: address, data: Data([0xCC])) // int3
        codeCursor += Self.slotSize
        let entry = Entry(names: names, handler: handler, address: address)
        entriesByAddress[address] = entry
        for name in names {
            symbols[name] = address
        }
    }

    /// Resolve an imported symbol name to its shim address.
    public func address(of symbol: String) -> UInt64? {
        symbols[symbol]
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
        } catch {
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
