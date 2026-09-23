import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AppStoreCore

/// End-to-end: the exact flow EmulatedSAPSigner runs in the app, against the
/// live Apple endpoints with the real assets. This mirrors the device path.
final class SAPSignerIntegrationTests: XCTestCase {

    private func fixture(_ name: String) -> Data? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try? Data(contentsOf: url)
    }

    func testFullSignerFlowAgainstLiveEndpoints() async throws {
        guard let kit = fixture("CommerceKit.macho"),
              let core = fixture("CommerceCore.macho"),
              let corefp = fixture("CoreFP"),
              let icxs = fixture("CoreFP.icxs")
        else { throw XCTSkip("fixtures not present") }

        let bundle = SAPAssetBundle(commerceKit: kit, commerceCore: core, coreFP: corefp, coreFPICXS: icxs)

        let http = URLSessionHTTPClient()
        let bagProvider = BagService(http: http)
        let assetProvider = StaticAssets(bundle: bundle)
        let hardwareID = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])

        let signer = EmulatedSAPSigner(
            http: http, bagProvider: bagProvider,
            assetProvider: assetProvider, hardwareID: hardwareID
        )

        // sign() triggers establish(): bag → cert → runtime → setup POST →
        // second exchange → ready.
        let body = Data("appleId=u@e.com&attempt=1&guid=AABBCCDDEEFF&rmp=0&why=signIn".utf8)
        let signature = try await signer.sign(body: body)

        XCTAssertFalse(signature.isEmpty, "signer must produce X-Apple-ActionSignature")
        XCTAssertTrue(signature.allSatisfy(\.isHexDigit), "signature must be hex")
        print("action signature (\(signature.count / 2) bytes): \(signature.prefix(32))…")

        // A second call reuses the established session (no re-setup).
        let again = try await signer.sign(body: body)
        XCTAssertEqual(signature.count, again.count)
    }
}

/// Serves a fixed bundle — skips the download so the test hits only Apple.
private struct StaticAssets: SAPAssetProviding {
    let bundle: SAPAssetBundle
    func load() async throws -> SAPAssetBundle { bundle }
}
