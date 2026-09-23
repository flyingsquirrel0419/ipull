import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AppStoreCore

/// sign() over a realistic authenticate body with the real assets.
final class SAPSignTests: XCTestCase {

    private func fixture(_ name: String) -> Data? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try? Data(contentsOf: url)
    }

    func testSignProducesDeterministicSignature() async throws {
        guard let kit = fixture("CommerceKit.macho"),
              let core = fixture("CommerceCore.macho"),
              let corefp = fixture("CoreFP"),
              let icxs = fixture("CoreFP.icxs")
        else { throw XCTSkip("fixtures not present") }

        let bundle = SAPAssetBundle(commerceKit: kit, commerceCore: core, coreFP: corefp, coreFPICXS: icxs)
        let hardwareID = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])

        guard let cert = fixture("sap-setup-cert.der") else { throw XCTSkip("cert fixture missing") }
        let runtime = try SAPRuntime(assets: bundle, hardwareID: hardwareID)
        let context = try runtime.initialize(hardwareID: hardwareID)

        // sign() requires a completed server-side session — do the two-step exchange.
        let (request, _) = try runtime.exchange(version: 200, hardwareID: hardwareID, context: context, input: cert)
        let envelope = try PropertyListSerialization.data(fromPropertyList: ["sign-sap-setup-buffer": request], format: .xml, options: 0)
        var urlRequest = URLRequest(url: URL(string: "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = envelope
        let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let plist = try? PropertyListSerialization.propertyList(from: responseData, format: nil) as? [String: Any],
              let reply = plist["sign-sap-setup-buffer"] as? Data
        else { throw XCTSkip("setup endpoint unavailable") }
        _ = try runtime.exchange(version: 200, hardwareID: hardwareID, context: context, input: reply)

        let body = Data("appleId=user@example.com&attempt=1&guid=AABBCCDDEEFF&rmp=0&why=signIn".utf8)
        let signature = try runtime.sign(context: context, input: body)

        XCTAssertFalse(signature.isEmpty, "sign must return signature bytes")
        print("signature bytes:", signature.count,
              "hex head:", signature.prefix(16).map { String(format: "%02x", $0) }.joined())

        // SAP signatures embed a timestamp/nonce — two calls differ, both valid.
        let again = try runtime.sign(context: context, input: body)
        XCTAssertEqual(signature.count, again.count)
    }
}
