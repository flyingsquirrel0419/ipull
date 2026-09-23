import Foundation

/// Orchestrates the SAP signing session: load assets → map images into the
/// emulator → resolve exports → initialize → exchange (cert) → sign.
///
/// Memory layout follows ipatool's machine.go (MIT):
///   CoreFP        @ 0x0000100000000000
///   CommerceCore  @ 0x0000100040000000
///   CommerceKit   @ 0x0000100080000000
///   scratch       @ 0x0000300000000000 (32 MB)
///   heap          @ 0x0000400000000000 (64 MB)
///   stack         @ 0x0000500000000000 ( 8 MB)
///   shims         @ 0x0000200000000000
public final class SAPRuntime {

    public enum Error: Swift.Error {
        case exportMissing(String)
        case initializeFailed
    }

    static let coreFPBase: UInt64 = 0x0000100000000000
    static let commerceCoreBase: UInt64 = 0x0000100040000000
    static let commerceKitBase: UInt64 = 0x0000100080000000
    static let scratchBase: UInt64 = 0x0000300000000000
    static let scratchSize: UInt64 = 32 << 20
    static let stackBase: UInt64 = 0x0000500000000000
    static let stackSize: UInt64 = 8 << 20
    static let returnAddress: UInt64 = 0x0000000100000000

    /// Export names in CoreFP that drive the SAP session (from ipatool).
    private static let exportInitialize = "_cp2g1b9ro"
    private static let exportExchange = "_Mib5yocT"
    private static let exportSign = "_Fc3vhtJDvr"
    private static let exportTeardown = "_IPaI1oem5iL"
    private static let exportDispose = "_gk0ZZbuoP"  // dispose entry

    private let engine: UnicornEngine
    private let shims: SAPShims
    private let heapState = SAPShims.HeapState()

    private var entryPoints: (initialize: UInt64, exchange: UInt64, sign: UInt64,
                              teardown: UInt64, dispose: UInt64)?

    public init(assets: SAPAssetBundle) throws {
        engine = try UnicornEngine()
        shims = try SAPShims(engine: engine)
        try shims.registerMemoryServices(heap: heapState)

        try engine.map(address: Self.scratchBase, size: Self.scratchSize)
        try engine.map(address: SAPShims.heapBase, size: SAPShims.heapSize)
        try engine.map(address: Self.stackBase, size: Self.stackSize)

        // Map return trap
        try engine.map(address: Self.returnAddress, size: 0x1000)

        try loadImages(assets: assets)
    }

    private func loadImages(assets: SAPAssetBundle) throws {
        var coreFP = try MachOImage(name: "CoreFP", data: assets.coreFP)
        var commerceCore = try MachOImage(name: "CommerceCore", data: assets.commerceCore)
        var commerceKit = try MachOImage(name: "CommerceKit", data: assets.commerceKit)

        let resolve: (String) throws -> UInt64 = { [shims] name in
            if let address = shims.address(of: name) { return address }
            // Unknown import: return 0 and let the hook trap if called.
            Log.error(.auth, "unresolved SAP import: \(name)")
            return 0
        }

        try coreFP.relocate(loadBase: Self.coreFPBase, resolve: resolve)
        try commerceCore.relocate(loadBase: Self.commerceCoreBase, resolve: resolve)
        try commerceKit.relocate(loadBase: Self.commerceKitBase, resolve: resolve)

        let memory = EngineMemory(engine: engine)
        try coreFP.load(into: memory)
        try commerceCore.load(into: memory)
        try commerceKit.load(into: memory)

        let initialize = try coreFP.exportAddress(Self.exportInitialize, loadBase: Self.coreFPBase)
        let exchange = try coreFP.exportAddress(Self.exportExchange, loadBase: Self.coreFPBase)
        let sign = try coreFP.exportAddress(Self.exportSign, loadBase: Self.coreFPBase)
        let teardown = try coreFP.exportAddress(Self.exportTeardown, loadBase: Self.coreFPBase)
        let dispose = (try? coreFP.exportAddress(Self.exportDispose, loadBase: Self.coreFPBase)) ?? 0

        entryPoints = (initialize, exchange, sign, teardown, dispose)
    }

    /// Initialize the SAP session with the device hardware ID.
    public func initialize(hardwareID: Data) throws -> UInt64 {
        guard let entries = entryPoints else { throw Error.initializeFailed }
        let idAddress = Self.scratchBase
        try engine.write(address: idAddress, data: hardwareID)

        // SysV ABI: rdi = context-out pointer, rsi = hardware id pointer,
        // rdx = hardware id length. Push return address on the guest stack.
        let stackTop = Self.stackBase + Self.stackSize
        try engine.write(.rsp, stackTop - 8)
        try engine.write(address: stackTop - 8,
                         data: withUnsafeBytes(of: Self.returnAddress.littleEndian) { Data($0) })
        try engine.write(.rdi, Self.scratchBase + 0x100)
        try engine.write(.rsi, idAddress)
        try engine.write(.rdx, UInt64(hardwareID.count))

        try engine.run(from: entries.initialize, until: Self.returnAddress)
        let context = try engine.read(address: Self.scratchBase + 0x100, size: 8)
            .withUnsafeBytes { $0.load(as: UInt64.self) }
        return context
    }
}

/// Adapts UnicornEngine to MachOImage.Memory.
private struct EngineMemory: MachOImage.Memory {
    let engine: UnicornEngine
    func map(address: UInt64, size: UInt64) throws { try engine.map(address: address, size: size) }
    func write(address: UInt64, data: Data) throws { try engine.write(address: address, data: data) }
}
