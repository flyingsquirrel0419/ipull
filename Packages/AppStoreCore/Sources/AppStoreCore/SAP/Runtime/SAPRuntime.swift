import Foundation

/// Orchestrates a SAP signing session by executing Apple's signing binary
/// under emulation. Call ABI, memory layout, and entry points follow
/// ipatool's machine.go (MIT) — reimplemented against the observed
/// behavior of the guest binary.
///
/// Memory layout:
///   CoreFP        @ 0x0000100000000000
///   CommerceCore  @ 0x0000100040000000
///   CommerceKit   @ 0x0000100080000000
///   shims         @ 0x0000200000000000
///   scratch       @ 0x0000300000000000 ( 8 MB)
///   heap          @ 0x0000400000000000 (32 MB)
///   stack         @ 0x0000500000000000 ( 8 MB)
///   return trap   @ 0x0000000100000000 (HLT page)
public final class SAPRuntime {

    public enum Error: Swift.Error, Equatable {
        case exportMissing(String)
        case initializeFailed(Int32)
        case exchangeFailed(Int32)
        case signFailed(Int32)
        case teardownFailed(Int32)
        case guestFault(String)
        case unexpectedStop(UInt64)
        case scratchExhausted
        case inputTooLarge
        case closed
    }

    static let coreFPBase: UInt64 = 0x0000100000000000
    static let commerceCoreBase: UInt64 = 0x0000100040000000
    static let commerceKitBase: UInt64 = 0x0000100080000000
    static let scratchBase: UInt64 = 0x0000300000000000
    static let scratchSize: UInt64 = 8 << 20
    static let stackBase: UInt64 = 0x0000500000000000
    static let stackSize: UInt64 = 8 << 20
    static let stackEnd: UInt64 = stackBase + stackSize
    static let returnAddress: UInt64 = 0x0000000100000000
    static let guestTimeoutMicroseconds: UInt64 = 60_000_000

    /// Entry point exports resolved from CommerceKit (names per ipatool).
    private static let entryNames = [
        "_cp2g1b9ro",   // initialize
        "_Mib5yocT",     // exchange
        "_Fc3vhtJDvr",   // sign
        "_IPaI1oem5iL",   // teardown
        "_jEHf8Xzsv8K",   // dispose
    ]

    /// CoreFP exports the other images bind against (per ipatool).
    private static let coreFPExportNames = [
        "_WIn9UJ86JKdV4dM", "_X46O5IeS", "_YlCJ3lg",
        "_dku592fbFAj", "_fdjkDSAFjklaf2s", "_lxpgvVMLd0S7uRl",
    ]

    private let engine: UnicornEngine
    private let shims: SAPShims
    private let heapState = SAPShims.HeapState()
    private var scratchCursor: UInt64 = 0
    private var isClosed = false

    private var entries: [String: UInt64] = [:]
    private var lastTrace: UnsafeMutableRawPointer?

    public init(assets: SAPAssetBundle, hardwareID: Data) throws {
        engine = try UnicornEngine()

        // Return trap page with HLT (0xF4) so emu stops at returnAddress.
        try engine.map(address: Self.returnAddress, size: 0x1000)
        try engine.write(address: Self.returnAddress, data: Data([0xF4]))

        try engine.map(address: Self.scratchBase, size: Self.scratchSize)
        try engine.map(address: SAPShims.heapBase, size: SAPShims.heapSize)
        try engine.map(address: Self.stackBase, size: Self.stackSize)

        shims = try SAPShims(engine: engine)
        shims.icxsData = assets.coreFPICXS

        // Trace the last executed instructions so a fault shows the path.
        let tracePtr = Unmanaged.passRetained(TraceBox()).toOpaque()
        _ = try? engine.addCodeHook(begin: 0, end: UInt64.max, callback: { address, _, userData in
            guard let userData else { return }
            let box = Unmanaged<TraceBox>.fromOpaque(userData).takeUnretainedValue()
            box.addresses.append(address)
            if box.addresses.count > 64 { box.addresses.removeFirst() }
        }, userData: tracePtr)
        lastTrace = tracePtr

        // Log the exact faulting address on unmapped access, then stop.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        _ = try? engine.addInvalidMemHook(callback: { address, size, type, _ in
            Log.error(.auth, "guest invalid mem access at \(String(address, radix: 16)) size \(size) type \(type)")
            return 0
        }, userData: selfPtr)
        try shims.registerMemoryServices(heap: heapState)

        try loadImages(assets: assets, hardwareID: hardwareID)
    }

    private func loadImages(assets: SAPAssetBundle, hardwareID: Data) throws {
        var coreFP = try MachOImage(name: "CoreFP", data: assets.coreFP)
        var commerceCore = try MachOImage(name: "CommerceCore", data: assets.commerceCore)
        var commerceKit = try MachOImage(name: "CommerceKit", data: assets.commerceKit)

        // Shared export table: entry points (CommerceKit) + CoreFP exports +
        // CommerceCore's MAC address export — all resolvable during binds.
        var exports: [String: UInt64] = [:]

        func exportAddress(_ name: String, in image: MachOImage, base: UInt64) throws -> UInt64 {
            guard let address = image.file.symbolAddress(name) else {
                throw Error.exportMissing(name)
            }
            let (resolved, overflow) = base.addingReportingOverflow(address - image.file.baseAddress)
            if overflow { throw Error.exportMissing(name) }
            return resolved
        }

        for name in Self.entryNames {
            exports[name] = try exportAddress(name, in: commerceKit, base: Self.commerceKitBase)
        }
        for name in Self.coreFPExportNames {
            exports[name] = try exportAddress(name, in: coreFP, base: Self.coreFPBase)
        }
        if let mac = try? exportAddress("_get_mac_address", in: commerceCore, base: Self.commerceCoreBase) {
            exports["_get_mac_address"] = mac
        }
        entries = exports

        var deferredImports = Set<String>()
        let resolve: (String) throws -> UInt64 = { [shims] name in
            if let address = exports[name] { return address }
            if let known = shims.address(of: name) { return known }
            // Mach-O binds include imports from code paths we never execute.
            // The trap reports the symbol only if the guest actually calls it.
            deferredImports.insert(name)
            return try shims.resolve(name)
        }

        try coreFP.relocate(loadBase: Self.coreFPBase, resolve: resolve)
        try commerceCore.relocate(loadBase: Self.commerceCoreBase, resolve: resolve)
        try commerceKit.relocate(loadBase: Self.commerceKitBase, resolve: resolve)
        Log.info(.auth, "SAP images linked; \(deferredImports.count) unused imports deferred")

        let memory = EngineMemory(engine: engine)
        Log.info(.auth, "SAP loading CoreFP into emulator")
        try coreFP.load(into: memory)
        Log.info(.auth, "SAP loading CommerceCore into emulator")
        try commerceCore.load(into: memory)
        Log.info(.auth, "SAP loading CommerceKit into emulator")
        try commerceKit.load(into: memory)
        Log.info(.auth, "SAP images loaded into emulator")

        // Pre-register inert data slots for constant-object imports so binds
        // resolve them to valid guest memory instead of trap stubs.
        let dataSymbolPrefixes = ["_kCF", "_kSec", "_kDADisk", "_kIOMaster", "_NS", "_CSSMOID", "__NS", "__kCF"]
        let allSymbols = Set(coreFP.file.binds.map(\.symbolName)
            + commerceCore.file.binds.map(\.symbolName)
            + commerceKit.file.binds.map(\.symbolName))
        for symbol in allSymbols where dataSymbolPrefixes.contains(where: { symbol.hasPrefix($0) }) {
            if exports[symbol] == nil, shims.address(of: symbol) == nil {
                try? shims.addData(symbol)
            }
        }

        // dlsym resolves against CoreFP's export table (relocated).
        var fpExports: [String: UInt64] = [:]
        for (name, address) in coreFP.file.symbols {
            fpExports[name] = Self.coreFPBase + (address - coreFP.file.baseAddress)
        }
        shims.coreFPExports = fpExports
    }

    // MARK: - Session

    /// Initialize the SAP session; returns the context value.
    public func initialize(hardwareID: Data) throws -> UInt64 {
        let hardware = try Self.hardwareBlock(hardwareID)
        beginCall()
        defer { clearScratch() }

        let contextField = try scratch(nil, size: 8)
        let hardwareAddress = try scratch(hardware, size: UInt64(hardware.count))

        Log.info(.auth, "SAP entering guest initialization")
        let status = try invoke(entries[Self.entryNames[0]] ?? 0, contextField, hardwareAddress)
        guard Int32(truncatingIfNeeded: status) == 0 else {
            throw Error.initializeFailed(Int32(truncatingIfNeeded: status))
        }
        let context = try readUInt64(at: contextField)
        return context
    }

    /// Exchange a SAP message (setup round-trip).
    public func exchange(version: UInt32, hardwareID: Data, context: UInt64, input: Data) throws -> (output: Data, state: Int32) {
        let hardware = try Self.hardwareBlock(hardwareID)
        beginCall()
        defer { clearScratch() }

        let hardwareAddress = try scratch(hardware, size: UInt64(hardware.count))
        let inputAddress = try scratch(input, size: UInt64(input.count))
        let outputField = try scratch(nil, size: 8)
        let lengthField = try scratch(nil, size: 8)
        let resultField = try scratch(nil, size: 4)

        let status = try invoke(
            entries[Self.entryNames[1]] ?? 0,
            UInt64(version), hardwareAddress, context, inputAddress, UInt64(input.count),
            outputField, lengthField, resultField
        )
        guard Int32(truncatingIfNeeded: status) == 0 else {
            throw Error.exchangeFailed(Int32(truncatingIfNeeded: status))
        }

        let output = try consumeOutput(pointerField: outputField, lengthField: lengthField)
        let state = Int32(bitPattern: try readUInt32(at: resultField))
        return (output, state)
    }

    /// Sign an authenticate request body; returns the X-Apple-ActionSignature bytes.
    public func sign(context: UInt64, input: Data) throws -> Data {
        beginCall()
        defer { clearScratch() }

        let inputAddress = try scratch(input, size: UInt64(input.count))
        let outputField = try scratch(nil, size: 8)
        let lengthField = try scratch(nil, size: 8)

        let status = try invoke(
            entries[Self.entryNames[2]] ?? 0,
            context, inputAddress, UInt64(input.count), outputField, lengthField
        )
        guard Int32(truncatingIfNeeded: status) == 0 else {
            throw Error.signFailed(Int32(truncatingIfNeeded: status))
        }
        return try consumeOutput(pointerField: outputField, lengthField: lengthField)
    }

    public func teardown(context: UInt64) throws {
        let status = try invoke(entries[Self.entryNames[3]] ?? 0, context)
        guard Int32(truncatingIfNeeded: status) == 0 else {
            throw Error.teardownFailed(Int32(truncatingIfNeeded: status))
        }
    }

    public func close() {
        isClosed = true
    }

    // MARK: - Call machinery

    /// Invoke a guest function with up to 6 register arguments; extras spill
    /// to the guest stack. Returns RAX.
    private func invoke(_ function: UInt64, _ arguments: UInt64...) throws -> UInt64 {
        guard !isClosed else { throw Error.closed }
        guard function != 0 else { throw Error.guestFault("null entry point") }

        let registers: [UnicornEngine.Register] = [.rdi, .rsi, .rdx, .rcx, .r8, .r9]
        for (index, reg) in registers.enumerated() {
            try engine.write(reg, index < arguments.count ? arguments[index] : 0)
        }

        let extra = max(arguments.count - registers.count, 0)
        var stackPointer = Self.stackEnd - UInt64(extra + 1) * 8
        if stackPointer % 16 != 8 { stackPointer -= 8 }

        try writeUInt64(Self.returnAddress, at: stackPointer)
        for index in 0..<extra {
            try writeUInt64(arguments[registers.count + index], at: stackPointer + 8 + UInt64(index) * 8)
        }
        try engine.write(.rsp, stackPointer)

        do {
            try engine.run(from: function, until: Self.returnAddress,
                           timeoutMicroseconds: Self.guestTimeoutMicroseconds)
        } catch {
            let rip = (try? engine.read(.rip)) ?? 0
            let rsp = (try? engine.read(.rsp)) ?? 0
            Log.error(.auth, "guest fault at RIP=\(String(rip, radix: 16)) RSP=\(String(rsp, radix: 16))")
            if let lastTrace {
                let box = Unmanaged<TraceBox>.fromOpaque(lastTrace).takeUnretainedValue()
                let tail = box.addresses.suffix(16).map { String($0, radix: 16) }.joined(separator: " ")
                Log.error(.auth, "guest trace tail: \(tail)")
            }
            throw error
        }

        // A shim handler may have recorded a fault and stopped emulation.
        if let fault = shims.fault {
            shims.fault = nil
            throw fault
        }

        let rip = try engine.read(.rip)
        guard rip == Self.returnAddress else {
            throw Error.unexpectedStop(rip)
        }
        return try engine.read(.rax)
    }

    // MARK: - Scratch space

    private func beginCall() { scratchCursor = 0 }

    private func scratch(_ data: Data?, size: UInt64) throws -> UInt64 {
        let reserved = SAPShims.align(max(size, 1), to: 16)
        guard scratchCursor + reserved <= Self.scratchSize else {
            throw Error.scratchExhausted
        }
        let address = Self.scratchBase + scratchCursor
        scratchCursor += reserved
        if let data, !data.isEmpty {
            guard data.count <= size else { throw Error.inputTooLarge }
            try engine.write(address: address, data: data)
        } else if size > 0 {
            try engine.write(address: address, data: Data(count: Int(size)))
        }
        return address
    }

    private func clearScratch() {
        if scratchCursor > 0 {
            try? engine.write(address: Self.scratchBase, data: Data(count: Int(scratchCursor)))
        }
        scratchCursor = 0
    }

    private func consumeOutput(pointerField: UInt64, lengthField: UInt64) throws -> Data {
        let pointer = try readUInt64(at: pointerField)
        let length = try readUInt64(at: lengthField)

        var output = Data()
        if length > 0 && length <= Self.scratchSize && pointer != 0 {
            output = try engine.read(address: pointer, size: Int(length))
        }
        // The guest heap-allocated the output buffer; hand it back (dispose).
        if pointer != 0, let disposeEntry = entries[Self.entryNames[4]], disposeEntry != 0 {
            _ = try? invoke(disposeEntry, pointer)
        }
        return output
    }

    private func readUInt32(at address: UInt64) throws -> UInt32 {
        try engine.read(address: address, size: 4).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
    }
    private func readUInt64(at address: UInt64) throws -> UInt64 {
        try engine.read(address: address, size: 8).withUnsafeBytes { UInt64(littleEndian: $0.load(as: UInt64.self)) }
    }
    private func writeUInt64(_ value: UInt64, at address: UInt64) throws {
        try engine.write(address: address, data: withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }

    /// Hardware ID block: 4-byte LE length prefix + up to 20 bytes, in a
    /// 24-byte buffer (layout per ipatool).
    static func hardwareBlock(_ hardwareID: Data) throws -> Data {
        guard !hardwareID.isEmpty, hardwareID.count <= 20 else {
            throw Error.inputTooLarge
        }
        var block = Data(count: 24)
        block.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(hardwareID.count).littleEndian, toByteOffset: 0, as: UInt32.self)
        }
        block.replaceSubrange(4..<(4 + hardwareID.count), with: hardwareID)
        return block
    }
}

/// Adapts UnicornEngine to MachOImage.Memory.
private struct EngineMemory: MachOImage.Memory {
    let engine: UnicornEngine
    func map(address: UInt64, size: UInt64) throws { try engine.map(address: address, size: size) }
    func write(address: UInt64, data: Data) throws { try engine.write(address: address, data: data) }
}

final class TraceBox {
    var addresses: [UInt64] = []
}
