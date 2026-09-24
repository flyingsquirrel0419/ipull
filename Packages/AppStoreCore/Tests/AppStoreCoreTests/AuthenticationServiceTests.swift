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

    final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [AuthenticationProgress] = []

        func record(_ progress: AuthenticationProgress) {
            lock.lock()
            storage.append(progress)
            lock.unlock()
        }

        var values: [AuthenticationProgress] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testSignInReportsActualStagesInOrder() async throws {
        let http = MockHTTP()
        http.responses = [HTTPResponse(
            statusCode: 200,
            headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
            data: plist(["dsPersonId": "1", "passwordToken": "tok"])
        )]
        let recorder = ProgressRecorder()
        let service = AuthenticationService(
            http: http, bagProvider: MockBag(), signer: MockSigner(),
            secrets: InMemorySecretStore(), guidProvider: { "AABBCCDDEEFF" },
            progress: { recorder.record($0) }
        )

        _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        XCTAssertEqual(recorder.values, [
            .initializingSigner, .fetchingConfiguration, .signingRequest, .authenticating, .savingSession,
        ])
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
        ]
        let service = makeService(http: http)
        do {
            _ = try await service.signIn(email: "u@e.com", password: "wrong", twoFactorCode: nil)
            XCTFail()
        } catch AppStoreError.authenticationFailed {
            // expected: desktop attempt values leave no room for a
            // client-side retry on -5000
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testTwoFactorCodeSendsDesktopAttemptAndCreateSession() async throws {
        final class BodyCapture: SAPSigning, @unchecked Sendable {
            private(set) var lastBody: Data?
            func sign(body: Data) async throws -> String {
                lastBody = body
                return "SAP-200:test"
            }
        }
        let http = MockHTTP()
        http.responses = [HTTPResponse(
            statusCode: 200,
            headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
            data: plist(["dsPersonId": "1", "passwordToken": "tok"])
        )]
        let signer = BodyCapture()
        let service = AuthenticationService(
            http: http, bagProvider: MockBag(), signer: signer,
            secrets: InMemorySecretStore(), guidProvider: { "AABBCCDDEEFF" }
        )
        _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
        let body = try XCTUnwrap(signer.lastBody)
        let bodyPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any])
        // Desktop values with a code attached: attempt "2", password+code.
        XCTAssertEqual(bodyPlist["attempt"] as? String, "2")
        XCTAssertEqual(bodyPlist["password"] as? String, "pw123456")
        XCTAssertEqual(bodyPlist["createSession"] as? String, "true")
    }

    func testTwoFactorSubmissionReusesEstablishedSigner() async throws {
        let http = ScriptedHTTP()
        http.responses = [
            // First signIn: 2FA required.
            HTTPResponse(statusCode: 200, headers: [:],
                data: plist(["customerMessage": "MZFinance.BadLogin.Configurator_message"])),
            // Second signIn with code: success.
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let factory = RecordingSignerFactory()
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { id in try await factory.make(id) },
            secrets: InMemorySecretStore(),
            sleep: { _ in }
        )

        let first = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        XCTAssertEqual(first, .twoFactorRequired)

        let second = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
        guard case .success = second else { return XCTFail("Expected success") }

        // The code submission must reuse the signer established for the
        // challenge; creating a new one would start a fresh SAP session
        // and make Apple unable to verify password+code (failureType 5020).
        XCTAssertEqual(factory.hardwareIDs.count, 1)
    }

    func testFailureType5020WithCodeMapsToInvalidTwoFactorCode() async {
        let http = ScriptedHTTP()
        http.responses = [
            HTTPResponse(statusCode: 200, headers: [:],
                data: plist(["failureType": "5020", "customerMessage": "Did you forget your password?"])),
        ]
        let service = makeService(http: http, sleeps: Sleeps())
        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
            XCTFail("Expected invalidTwoFactorCode")
        } catch AppStoreError.invalidTwoFactorCode {
            // expected
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

        // 10s floor, then max(20s, Retry-After 5s) = 20s; under the 30s cap.
        XCTAssertEqual(sleeps.delaysNs, [10_000_000_000, 20_000_000_000])
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

    // MARK: - GUID rotation on persistent empty 404

    /// Records the hardware IDs the signer factory was asked to build with.
    final class RecordingSignerFactory: @unchecked Sendable {
        private(set) var hardwareIDs: [Data] = []
        func make(_ hardwareID: Data) async throws -> any SAPSigning {
            hardwareIDs.append(hardwareID)
            return MockSigner()
        }
    }

    func testPersistentEmpty404RotatesGUIDAndRetries() async throws {
        let http = ScriptedHTTP()
        // Four empty 404s (initial + 3 retries) exhaust the retry budget,
        // then the rotated identity's request succeeds.
        http.responses = [
            HTTPResponse(statusCode: 404, headers: [:], data: Data()),
            HTTPResponse(statusCode: 404, headers: [:], data: Data()),
            HTTPResponse(statusCode: 404, headers: [:], data: Data()),
            HTTPResponse(statusCode: 404, headers: [:], data: Data()),
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let secrets = InMemorySecretStore()
        try secrets.save(Data("AABBCCDDEEFF".utf8), for: DeviceIdentity.keychainKey)
        let factory = RecordingSignerFactory()
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { id in try await factory.make(id) },
            secrets: secrets,
            sleep: { _ in }
        )

        let result = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        guard case .success = result else { return XCTFail("Expected success after GUID rotation") }

        // The factory was asked for two signers: one for the stored GUID,
        // one for the rotated GUID.
        XCTAssertEqual(factory.hardwareIDs.count, 2)
        guard factory.hardwareIDs.count == 2 else { return }
        XCTAssertEqual(factory.hardwareIDs[0], Data("AABBCCDDEEFF".utf8))

        // The rotated GUID was persisted and is a fresh, valid GUID.
        let stored = try XCTUnwrap(secrets.load(key: DeviceIdentity.keychainKey))
        let rotatedGUID = try XCTUnwrap(String(data: stored, encoding: .utf8))
        XCTAssertNotEqual(rotatedGUID, "AABBCCDDEEFF")
        XCTAssertTrue(DeviceIdentity.isValidGUID(rotatedGUID))
        XCTAssertEqual(factory.hardwareIDs[1], Data(rotatedGUID.utf8))
    }

    func testPersistentEmpty404AfterRotationStillFails() async {
        let http = ScriptedHTTP()
        // Rotation happens once per sign-in; continued 404s after the
        // rotated identity also exhausts its retries must throw.
        http.responses = (0..<12).map { _ in
            HTTPResponse(statusCode: 404, headers: [:], data: Data())
        }
        let secrets = InMemorySecretStore()
        try? secrets.save(Data("AABBCCDDEEFF".utf8), for: DeviceIdentity.keychainKey)
        let factory = RecordingSignerFactory()
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { id in try await factory.make(id) },
            secrets: secrets,
            sleep: { _ in }
        )

        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            XCTFail("Expected networkUnavailable after rotation also 404s")
        } catch AppStoreError.networkUnavailable {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }

        // One rotation: two signers total, eight requests (two retry
        // sequences of four).
        XCTAssertEqual(factory.hardwareIDs.count, 2)
        XCTAssertEqual(http.requestCount, 8)
    }
}
