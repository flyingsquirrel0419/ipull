import XCTest
@testable import AppStoreCore

/// End-to-end: build the emulated SAP runtime from the REAL Apple assets
/// (extracted from the actual OSXUpd pkg during development; fixtures are
/// gitignored — CI provides them via the assets download path).
final class SAPRuntimeSmokeTests: XCTestCase {

    private func fixture(_ name: String) -> Data? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try? Data(contentsOf: url)
    }

    private var bundle: SAPAssetBundle? {
        guard let kit = fixture("CommerceKit.macho"),
              let core = fixture("CommerceCore.macho"),
              let corefp = fixture("CoreFP"),
              let icxs = fixture("CoreFP.icxs")
        else { return nil }
        return SAPAssetBundle(commerceKit: kit, commerceCore: core, coreFP: corefp, coreFPICXS: icxs)
    }

    func testRuntimeBuildsFromRealAssets() throws {
        guard let bundle else { throw XCTSkip("fixtures not present") }
        let runtime = try SAPRuntime(assets: bundle, hardwareID: Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        XCTAssertNotNil(runtime)
    }

    func testInitializeRunsOnRealAssets() throws {
        guard let bundle else { throw XCTSkip("fixtures not present") }
        let runtime = try SAPRuntime(assets: bundle, hardwareID: Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        // Initialize executes the real Apple binary under emulation. A non-zero
        // context proves the full chain (relocate → shims → invoke) works.
        let context = try runtime.initialize(hardwareID: Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        XCTAssertNotEqual(context, 0, "initialize returned null context")
    }
}
