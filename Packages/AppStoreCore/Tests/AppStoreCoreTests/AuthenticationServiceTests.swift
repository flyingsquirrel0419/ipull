import XCTest
@testable import AppStoreCore

final class AuthenticationServiceTests: XCTestCase {

    final class MockHTTP: HTTPClient, @unchecked Sendable {
        var responses: [HTTPResponse] = []
        var requests: [HTTPRequest] = []

        func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
            requests.append(request)
            guard !responses.isEmpty else { throw AppStoreError.networkUnavailable }
            return responses.removeFirst()
        }
    }

    struct MockSigner: SAPSigning {
        func sign(body: Data) async throws -> String { "SAP-200:test" }
    }

    struct MockBag: BagProviding {
        func bag(guid: String) async throws -> Bag {
            Bag(authEndpoint: URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate")!)
        }
    }

    private func plist(_ dict: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private func makeService(http: MockHTTP) -> AuthenticationService {
        AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signer: MockSigner(),
            secrets: InMemorySecretStore(),
            guidProvider: { "AABBCCDDEEFF" }
        )
    }

    func testSuccessfulLogin() async throws {
        let http = MockHTTP()
        http.responses = [HTTPResponse(
            statusCode: 200,
            headers: ["X-Set-Apple-Store-Front": "143466-1,29", "pod": "31"],
            data: plist([
                "dsPersonId": "12345",
                "passwordToken": "tok",
                "accountInfo": ["appleId": "user@example.com", "address": ["firstName": "Test", "lastName": "User"]],
            ])
        )]

        let service = makeService(http: http)
        let result = try await service.signIn(email: "user@example.com", password: "pw", twoFactorCode: nil)

        guard case .success(let session) = result else { return XCTFail() }
        XCTAssertEqual(session.directoryServicesID, "12345")
        XCTAssertEqual(session.storefront, "143466-1,29")
        XCTAssertEqual(session.pod, "31")
        XCTAssertEqual(session.displayName, "Test User")

        // Session must be persisted.
        let restored = try await service.restoreSession()
        XCTAssertEqual(restored, session)
    }

    func testTwoFactorFlow() async throws {
        let http = MockHTTP()
        http.responses = [
            HTTPResponse(statusCode: 200, headers: [:],
                data: plist(["customerMessage": "MZFinance.BadLogin.Configurator_message"])),
            HTTPResponse(statusCode: 200, headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok", "accountInfo": ["appleId": "u@e.com"]])),
        ]

        let service = makeService(http: http)
        let first = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        XCTAssertEqual(first, .twoFactorRequired)

        let second = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
        guard case .success = second else { return XCTFail() }
    }

    func testBadTwoFactorCodeRejected() async {
        let service = makeService(http: MockHTTP())
        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "12 45")
            XCTFail("Expected invalidTwoFactorCode")
        } catch AppStoreError.invalidTwoFactorCode {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testInvalidCredentials() async {
        let http = MockHTTP()
        http.responses = [
            HTTPResponse(statusCode: 200, headers: [:], data: plist(["failureType": "-5000"])),
            HTTPResponse(statusCode: 200, headers: [:], data: plist(["failureType": "-5000"])),
        ]
        let service = makeService(http: http)
        do {
            _ = try await service.signIn(email: "u@e.com", password: "wrong", twoFactorCode: nil)
            XCTFail()
        } catch AppStoreError.authenticationFailed {
            // expected: retried once, then failed
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testSessionNeverPrintsToken() {
        let session = AppleAccountSession(
            email: "u@e.com", displayName: "U", directoryServicesID: "1",
            storefront: "143441-1,29", pod: nil, passwordToken: "SECRET-TOKEN"
        )
        XCTAssertFalse(String(describing: session).contains("SECRET-TOKEN"))
        XCTAssertFalse(String(reflecting: session).contains("SECRET-TOKEN"))
    }

    func testRateLimited() async {
        let http = MockHTTP()
        http.responses = (0...AuthenticationService.maxRateLimitRetries).map { _ in
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "30"], data: Data())
        }
        let service = makeService(http: http, sleeps: Sleeps())
        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            XCTFail()
        } catch AppStoreError.rateLimited(let seconds) {
            XCTAssertEqual(seconds, 30)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Rate limiting (bounded exponential backoff)

    final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
        var responses: [HTTPResponse] = []
        var requestCount = 0
        func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
            requestCount += 1
            guard !responses.isEmpty else { throw AppStoreError.networkUnavailable }
            return responses.removeFirst()
        }
    }

    private func makeService(http: HTTPClient, sleeps: Sleeps) -> AuthenticationService {
        AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signer: MockSigner(),
            secrets: InMemorySecretStore(),
            guidProvider: { "AABBCCDDEEFF" },
            sleep: { ns in sleeps.record(ns) }
        )
    }

    final class Sleeps: @unchecked Sendable {
        private(set) var delaysNs: [UInt64] = []
        func record(_ ns: UInt64) { delaysNs.append(ns) }
    }

    func testRateLimitRetriesWithBoundedBackoffThenSucceeds() async throws {
        let http = ScriptedHTTP()
        http.responses = [
            HTTPResponse(statusCode: 429, headers: [:], data: Data()),
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "5"], data: Data()),
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let sleeps = Sleeps()
        let service = makeService(http: http, sleeps: sleeps)

        let result = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        guard case .success = result else { return XCTFail("Expected success after retries") }

        // 1s floor, then max(2s, Retry-After 5s) = 5s; both under the 30s cap.
        XCTAssertEqual(sleeps.delaysNs, [1_000_000_000, 5_000_000_000])
        XCTAssertEqual(http.requestCount, 3)
    }

    func testRateLimitBackoffCappedAtMaxDelay() async throws {
        let http = ScriptedHTTP()
        http.responses = [
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "600"], data: Data()),
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let sleeps = Sleeps()
        let service = makeService(http: http, sleeps: sleeps)

        _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)

        // Retry-After of 600s must be clamped to the 30s ceiling.
        XCTAssertEqual(sleeps.delaysNs, [30_000_000_000])
    }

    func testRateLimitRetriesExhaustedRethrows() async {
        let http = ScriptedHTTP()
        http.responses = (0..<10).map { _ in
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "12"], data: Data())
        }
        let sleeps = Sleeps()
        let service = makeService(http: http, sleeps: sleeps)

        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            XCTFail("Expected rateLimited after retries exhausted")
        } catch AppStoreError.rateLimited(let seconds) {
            XCTAssertEqual(seconds, 12)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertEqual(sleeps.delaysNs.count, AuthenticationService.maxRateLimitRetries)
        XCTAssertEqual(http.requestCount, 1 + AuthenticationService.maxRateLimitRetries)
    }

    // MARK: - Session-expired clears stored token

    func testSessionExpiredResponseEvictsStoredToken() async throws {
        let secrets = InMemorySecretStore()
        // Pre-seed a stale session in the store.
        let stale = AppleAccountSession(
            email: "u@e.com", displayName: "U", directoryServicesID: "1",
            storefront: "143441-1,29", pod: nil, passwordToken: "OLD"
        )
        try secrets.save(JSONEncoder().encode(stale), for: AuthenticationService.sessionKeychainKey)

        let http = ScriptedHTTP()
        http.responses = [
            HTTPResponse(statusCode: 200, headers: [:], data: plist(["failureType": "2034"])),
        ]
        let service = AuthenticationService(
            http: http, bagProvider: MockBag(), signer: MockSigner(),
            secrets: secrets, guidProvider: { "AABBCCDDEEFF" }, sleep: { _ in }
        )

        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            XCTFail("Expected sessionExpired")
        } catch AppStoreError.sessionExpired {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }

        let restored = try await service.restoreSession()
        XCTAssertNil(restored, "expired token must be evicted from the store")
    }

    // MARK: - Two-factor normalization

    func testTwoFactorCodeNormalizationAcceptsFormattedInput() async throws {
        let http = ScriptedHTTP()
        http.responses = [
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let service = makeService(http: http, sleeps: Sleeps())
        let result = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123 456")
        guard case .success = result else { return XCTFail("formatted code should normalize") }
    }

    func testRestoreSessionReturnsNilWhenStoreEmpty() async throws {
        let service = makeService(http: MockHTTP())
        let restored = try await service.restoreSession()
        XCTAssertNil(restored)
    }

    func testSignOutRemovesPersistedSession() async throws {
        let http = ScriptedHTTP()
        http.responses = [HTTPResponse(
            statusCode: 200,
            headers: ["X-Set-Apple-Store-Front": "143466-1,29"],
            data: plist(["dsPersonId": "9", "passwordToken": "tok"])
        )]
        let secrets = InMemorySecretStore()
        let service = AuthenticationService(
            http: http, bagProvider: MockBag(), signer: MockSigner(),
            secrets: secrets, guidProvider: { "AABBCCDDEEFF" }, sleep: { _ in }
        )
        _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        let signedInSession = try await service.restoreSession()
        XCTAssertNotNil(signedInSession)

        try await service.signOut()
        let signedOutSession = try await service.restoreSession()
        XCTAssertNil(signedOutSession)
    }
}
