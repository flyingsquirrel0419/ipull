import XCTest
@testable import AppStoreCore

/// Full signIn() flow with the emulated signer, mocked at the HTTP boundary
/// so we assert the 2FA branch — the exact screen the user should reach.
final class AuthenticationFlowTests: XCTestCase {

    /// HTTP mock that serves the bag, cert, setup exchange, then the
    /// authenticate response with MZFinance.BadLogin (2FA required).
    final class FlowHTTP: HTTPClient, @unchecked Sendable {
        var calls: [(String, String)] = []

        func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
            calls.append((request.method, request.url.absoluteString))
            let url = request.url.absoluteString

            if url.contains("init.itunes.apple.com/bag.xml") {
                let bag: [String: Any] = [
                    "urlBag": [
                        "authenticateAccount": "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate",
                        "sign-sap-setup": "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy",
                        "sign-sap-setup-cert": "https://s.mzstatic.com/sap/setupCert.plist",
                        "sign-sap-version": "200",
                    ]
                ]
                let data = try! PropertyListSerialization.data(fromPropertyList: bag, format: .xml, options: 0)
                return HTTPResponse(statusCode: 200, headers: [:], data: data)
            }
            if url.contains("s.mzstatic.com/sap/setupCert.plist") {
                let cert = Data([0x01, 0x02, 0x03, 0x04])
                let plist: [String: Any] = ["sign-sap-setup-cert": cert]
                let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                return HTTPResponse(statusCode: 200, headers: [:], data: data)
            }
            if url.contains("fpinit.itunes.apple.com/v1/signSapSetup/legacy") {
                let plist: [String: Any] = ["sign-sap-setup-buffer": Data([0xDE, 0xAD])]
                let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                return HTTPResponse(statusCode: 200, headers: [:], data: data)
            }
            if url.contains("buy.itunes.apple.com") && url.contains("authenticate") {
                // Apple answers 2FA-required via MZFinance.BadLogin with an
                // empty-string failureType (observed on-device, v0.3.10 log).
                let plist: [String: Any] = [
                    "failureType": "",
                    "customerMessage": "MZFinance.BadLogin.Configurator_message",
                ]
                let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                return HTTPResponse(statusCode: 200, headers: [:], data: data)
            }
            return HTTPResponse(statusCode: 404, headers: [:], data: Data())
        }
    }

    struct FixedAssets: SAPAssetProviding {
        func load() async throws -> SAPAssetBundle {
            // Minimal inert bundle — the signer is only reached after this
            // returns; with a mock HTTP the exchange is scripted.
            SAPAssetBundle(commerceKit: Data(), commerceCore: Data(), coreFP: Data(), coreFPICXS: Data())
        }
    }

    func testSignInReaches2FA() async throws {
        // Use a stub signer that short-circuits SAP — we're testing the auth
        // flow's 2FA branch, not the emulator. The signer must still be
        // called (proves the signing step runs before authenticate).
        let http = FlowHTTP()
        let signer = StubSigner()
        let service = AuthenticationService(
            http: http,
            bagProvider: BagService(http: http),
            signer: signer,
            secrets: InMemorySecretStore(),
            guidProvider: { "AABBCCDDEEFF" }
        )

        let result = try await service.signIn(email: "user@example.com", password: "pw", twoFactorCode: nil)
        XCTAssertEqual(result, .twoFactorRequired)

        // SAP signing must have happened before authenticate.
        XCTAssertTrue(signer.signCalls > 0, "signing must run before authenticate")

        // The authenticate body must be an XML plist — the desktop-client
        // format Apple's servers accept.
        let body = try XCTUnwrap(signer.lastBody)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
            "auth body must be an XML plist")
        XCTAssertEqual(plist["appleId"] as? String, "user@example.com")
        XCTAssertEqual(plist["password"] as? String, "pw")
        XCTAssertEqual(plist["guid"] as? String, "AABBCCDDEEFF")
        XCTAssertEqual(plist["why"] as? String, "signIn")
        // Desktop-client values: attempt "4" for password-only sign-in with
        // createSession "true" (createSession is omitted on 2FA submits).
        XCTAssertEqual(plist["attempt"] as? String, "4")
        XCTAssertEqual(plist["createSession"] as? String, "true")
    }

    final class StubSigner: SAPSigning, @unchecked Sendable {
        private(set) var signCalls = 0
        private(set) var lastBody: Data?
        func sign(body: Data) async throws -> String {
            signCalls += 1
            lastBody = body
            // Header value is base64 (matches the real signer's encoding).
            return Data("stub".utf8).base64EncodedString()
        }
    }
}
