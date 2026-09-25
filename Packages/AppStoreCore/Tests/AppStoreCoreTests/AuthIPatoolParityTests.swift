import XCTest
@testable import AppStoreCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Behaviors pinned to majd/ipatool@735b689 pkg/appstore/appstore_login.go
/// and pkg/http/client.go.
final class AuthIPatoolParityTests: XCTestCase {

    final class RecordingHTTP: HTTPClient, @unchecked Sendable {
        var responses: [HTTPResponse] = []
        var requests: [HTTPRequest] = []
        var bodies: [[String: Any]] = []
        func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
            requests.append(request)
            if let body, let dict = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] {
                bodies.append(dict)
            }
            guard !responses.isEmpty else { throw AppStoreError.networkUnavailable }
            return responses.removeFirst()
        }
    }

    final class CountingSigner: SAPSigning, @unchecked Sendable {
        private(set) var signCount = 0
        func sign(body: Data) async throws -> String {
            signCount += 1
            return "c2ln"
        }
    }

    struct Bag: BagProviding {
        func bag(guid: String) async throws -> AppStoreCore.Bag {
            AppStoreCore.Bag(authEndpoint: URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate")!)
        }
    }

    private let podURL = "https://p35-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?Pod=35&PRH=35"

    private func plist(_ dict: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private var success: HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                     data: plist(["dsPersonId": "1", "passwordToken": "tok"]))
    }

    private func service(_ http: HTTPClient, signer: SAPSigning = CountingSigner()) -> AuthenticationService {
        AuthenticationService(http: http, bagProvider: Bag(), signer: signer,
                              secrets: InMemorySecretStore(), guidProvider: { "AABBCCDDEEFF" },
                              sleep: { _ in }, experiment: .testA)
    }

    func testInvalidCredentialsOnFirstAttemptResendsWithAttempt2() async throws {
        let http = RecordingHTTP()
        http.responses = [HTTPResponse(statusCode: 200, headers: [:], data: plist(["failureType": "-5000"])), success]
        let result = try await service(http).signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        guard case .success = result else { return XCTFail("Expected success") }
        XCTAssertEqual(http.bodies.map { $0["attempt"] as? String }, ["1", "2"])
    }

    func testRedirectIsFreshlySignedPOSTAtPodWithAttempt1() async throws {
        let http = RecordingHTTP()
        http.responses = [HTTPResponse(statusCode: 302, headers: ["Location": podURL], data: Data()), success]
        let signer = CountingSigner()
        _ = try await service(http, signer: signer).signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
        XCTAssertEqual(http.requests.map(\.method), ["POST", "POST"])
        XCTAssertEqual(http.requests[1].url.absoluteString, podURL)
        XCTAssertEqual(http.requests[1].headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(signer.signCount, 2)
        XCTAssertEqual(http.bodies[1]["attempt"] as? String, "1")
        XCTAssertEqual(http.bodies[1]["password"] as? String, "pw123456")
        XCTAssertEqual(Set(http.bodies[1].keys), ["appleId", "attempt", "guid", "password", "rmp", "why"])
    }

    func testTwoFactorSubmitStartsAtBagEndpointAfterPasswordRedirect() async throws {
        let http = RecordingHTTP()
        http.responses = [
            HTTPResponse(statusCode: 302, headers: ["Location": podURL], data: Data()),
            HTTPResponse(statusCode: 200, headers: [:],
                         data: plist(["customerMessage": "MZFinance.BadLogin.Configurator_message"])),
            success,
        ]
        let auth = service(http)
        let first = try await auth.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        XCTAssertEqual(first, .twoFactorRequired)
        _ = try await auth.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
        XCTAssertEqual(http.requests[2].url.host, "buy.itunes.apple.com")
        XCTAssertEqual(http.bodies[2]["guid"] as? String, http.bodies[0]["guid"] as? String)
    }

    func testRedirectWithoutLocationFails() async {
        let http = RecordingHTTP()
        http.responses = [HTTPResponse(statusCode: 302, headers: [:], data: Data())]
        do {
            _ = try await service(http).signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            XCTFail("Expected failure")
        } catch {}
        XCTAssertEqual(http.requests.count, 1)
    }

    func testRedirectToOtherPathOnAppleHostIsRejected() async {
        let http = RecordingHTTP()
        http.responses = [HTTPResponse(statusCode: 302,
            headers: ["Location": "https://p35-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/other"], data: Data())]
        do {
            _ = try await service(http).signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            XCTFail("Expected rejection")
        } catch {}
        XCTAssertEqual(http.requests.count, 1)
    }

    func testPlist404IsVerdictNotTransportRetry() async {
        let http = RecordingHTTP()
        http.responses = [HTTPResponse(statusCode: 404, headers: [:], data: plist(["failureType": "9999"]))]
        do {
            _ = try await service(http).signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            XCTFail("Expected failure")
        } catch AppStoreError.networkUnavailable {
            XCTFail("A plist verdict must not be treated as a transport failure")
        } catch {}
        XCTAssertEqual(http.requests.count, 1)
    }

    func testRetryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(AuthenticationService.retryAfterSeconds("7", now: now), 7)
        XCTAssertEqual(AuthenticationService.retryAfterSeconds("600", now: now), 31)
        XCTAssertNil(AuthenticationService.retryAfterSeconds(nil, now: now))
        XCTAssertNil(AuthenticationService.retryAfterSeconds("soon", now: now))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(AuthenticationService.retryAfterSeconds(formatter.string(from: now.addingTimeInterval(12)), now: now), 12)
        XCTAssertEqual(AuthenticationService.retryAfterSeconds(formatter.string(from: now.addingTimeInterval(-5)), now: now), 0)
    }

    func testZeroRetryAfterWaitsOneSecond() async throws {
        let http = RecordingHTTP()
        http.responses = [HTTPResponse(statusCode: 429, headers: ["Retry-After": "0"], data: Data()), success]
        final class Sleeps: @unchecked Sendable { var values: [UInt64] = [] }
        let sleeps = Sleeps()
        let auth = AuthenticationService(http: http, bagProvider: Bag(), signer: CountingSigner(),
                                         secrets: InMemorySecretStore(), guidProvider: { "AABBCCDDEEFF" },
                                         sleep: { sleeps.values.append($0) }, experiment: .testA)
        _ = try await auth.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        XCTAssertEqual(sleeps.values, [1_000_000_000])
    }

    // MARK: - Transport: the authenticate 302 is surfaced, not followed
    // swift-corelibs-foundation cannot deliver URLProtocol redirects, so this
    // runs on Darwin (CI core-tests run on macOS).
    #if canImport(Darwin)

    final class RedirectStub: URLProtocol {
        nonisolated(unsafe) static var followedTo: [URL] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            if url.host == "buy.itunes.apple.com" {
                let pod = URL(string: "https://p35-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate")!
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": pod.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: pod), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                Self.followedTo.append(url)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {}
    }

    func testAuthenticatePOSTRedirectIsNotFollowed() async throws {
        RedirectStub.followedTo = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        let client = URLSessionHTTPClient(configuration: configuration)
        let request = HTTPRequest(
            url: URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate")!,
            method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"])
        let response = try await client.send(request, body: Data("x".utf8))
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertNotNil(response.header("Location"))
        XCTAssertTrue(RedirectStub.followedTo.isEmpty)
    }
    #endif
}
