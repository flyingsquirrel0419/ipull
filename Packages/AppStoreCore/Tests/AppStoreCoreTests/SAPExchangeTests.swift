import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

    func testInitializeAndExchangeRoundTrip() async throws {
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

        // First exchange with the setup certificate → request buffer.
        let (request, state1) = try runtime.exchange(
            version: 200, hardwareID: hardwareID, context: context, input: cert
        )
        XCTAssertFalse(request.isEmpty)
        XCTAssertEqual(state1, 1, "first exchange must enter state 1")
        print("setup request bytes:", request.count)

        // POST the request to Apple's live setup endpoint.
        let envelope = try PropertyListSerialization.data(
            fromPropertyList: ["sign-sap-setup-buffer": request], format: .xml, options: 0)
        var urlRequest = URLRequest(url: URL(string: "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = envelope
        let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        print("setup POST status:", http?.statusCode ?? -1)
        guard http?.statusCode == 200,
              let plist = try? PropertyListSerialization.propertyList(from: responseData, format: nil) as? [String: Any],
              let reply = plist["sign-sap-setup-buffer"] as? Data
        else {
            XCTFail("Apple setup endpoint rejected the emulated request")
            return
        }

        // Second exchange completes the session.
        let (_, state2) = try runtime.exchange(
            version: 200, hardwareID: hardwareID, context: context, input: reply
        )
        XCTAssertEqual(state2, 0, "setup must complete in state 0")

        // Now sign() must work.
        let body = Data("appleId=u@e.com&attempt=1&guid=AABBCCDDEEFF&rmp=0&why=signIn".utf8)
        let signature = try runtime.sign(context: context, input: body)
        XCTAssertFalse(signature.isEmpty)
        print("signature bytes:", signature.count)
    }
}
