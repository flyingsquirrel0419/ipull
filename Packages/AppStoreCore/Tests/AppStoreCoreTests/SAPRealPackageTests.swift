import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AppStoreCore

final class SAPRealPackageTests: XCTestCase {
    func testExtractsAndSignsWithRealApplePackage() async throws {
        guard let path = ProcessInfo.processInfo.environment["IPULL_REAL_SAP_PACKAGE"] else {
            throw XCTSkip("Set IPULL_REAL_SAP_PACKAGE to a locally downloaded Apple update package")
        }
        let assets = SAPAssets(http: URLSessionHTTPClient())
        let bundle = try assets.extractFrom(packageURL: URL(fileURLWithPath: path))
        XCTAssertEqual(bundle.commerceKit.count, 3_271_840)
        XCTAssertEqual(bundle.commerceCore.count, 207_744)
        XCTAssertEqual(bundle.coreFP.count, 29_014_912)
        XCTAssertEqual(bundle.coreFPICXS.count, 5_288_352)

        let hardwareID = Data("AABBCCDDEEFF".utf8)
        let runtime = try SAPRuntime(assets: bundle, hardwareID: hardwareID)
        let context = try runtime.initialize(hardwareID: hardwareID)
        XCTAssertNotEqual(context, 0)

        let certURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sap-setup-cert.der")
        let certificate = try Data(contentsOf: certURL)
        let (request, _) = try runtime.exchange(
            version: 200, hardwareID: hardwareID, context: context, input: certificate)
        XCTAssertFalse(request.isEmpty)

        let envelope = try PropertyListSerialization.data(
            fromPropertyList: ["sign-sap-setup-buffer": request], format: .xml, options: 0)
        var urlRequest = URLRequest(url: URL(string: "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = envelope
        let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: responseData, format: nil) as? [String: Any])
        let reply = try XCTUnwrap(plist["sign-sap-setup-buffer"] as? Data)
        _ = try runtime.exchange(version: 200, hardwareID: hardwareID, context: context, input: reply)

        let body = Data("appleId=u@e.com&attempt=1&guid=AABBCCDDEEFF&rmp=0&why=signIn".utf8)
        XCTAssertFalse(try runtime.sign(context: context, input: body).isEmpty)
    }
}
