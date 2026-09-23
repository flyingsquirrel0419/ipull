import XCTest
@testable import AppStoreCore

/// Full emulated SAP exchange round-trip with the REAL Apple assets and the
/// REAL setup certificate (fetched from s.mzstatic.com during development;
/// fixtures are gitignored, CI re-downloads them).
final class SAPExchangeTests: XCTestCase {

    private func fixture(_ name: String) -> Data? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try? Data(contentsOf: url)
    }

    func testInitializeAndExchangeRoundTrip() throws {
        guard let kit = fixture("CommerceKit.macho"),
              let core = fixture("CommerceCore.macho"),
              let corefp = fixture("CoreFP"),
              let icxs = fixture("CoreFP.icxs"),
              let cert = fixture("sap-setup-cert.der")
        else { throw XCTSkip("fixtures not present") }

        let bundle = SAPAssetBundle(commerceKit: kit, commerceCore: core, coreFP: corefp, coreFPICXS: icxs)
        let hardwareID = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])

        let runtime = try SAPRuntime(assets: bundle, hardwareID: hardwareID)
        let context = try runtime.initialize(hardwareID: hardwareID)
        XCTAssertNotEqual(context, 0)

        // First exchange with the setup certificate → request buffer for
        // the sign-sap-setup endpoint. This is the payload Apple expects.
        let (request, state) = try runtime.exchange(
            version: 200, hardwareID: hardwareID, context: context, input: cert
        )
        XCTAssertFalse(request.isEmpty, "exchange must produce a setup request buffer")
        XCTAssertGreaterThan(request.count, 16)
        print("exchange request bytes:", request.count, "state:", state)
    }
}
