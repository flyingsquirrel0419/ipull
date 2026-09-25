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
            HTTPResponse(statusCode: 200, headers: [:], data: plist(["failureType": "-5000"])),
        ]
        let service = makeService(http: http)
        do {
            _ = try await service.signIn(email: "u@e.com", password: "wrong", twoFactorCode: nil)
            XCTFail()
        } catch AppStoreError.authenticationFailed {
            // expected: ipatool resends -5000 once with attempt 2, then fails
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertEqual(http.requests.count, 2)
    }

    func testTwoFactorCodeMatchesIPatoolSubmitShape() async throws {
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
        // ipatool's 2FA submit shape: attempt "1", password+code, and no
        // createSession field. attempt "2" with createSession is answered
        // with an empty 404 by Apple's edge on-device.
        XCTAssertEqual(bodyPlist["attempt"] as? String, "1")
        XCTAssertEqual(bodyPlist["password"] as? String, "pw123456")
        XCTAssertNil(bodyPlist["createSession"])
    }

    /// The controlled experiment matrix: password and 2FA in one flow must
    /// share the same payload schema and attempt value; the four
    /// combinations are selected only via AuthExperiment.
    func testExperimentMatrixProducesIdenticalSchemaAcrossStages() async throws {
        final class BodyCapture: SAPSigning, @unchecked Sendable {
            private(set) var bodies: [Data] = []
            func sign(body: Data) async throws -> String {
                bodies.append(body)
                return "SAP-200:test"
            }
        }
        let experiments: [(AuthenticationService.AuthExperiment, String, Bool)] = [
            (.testA, "1", false),
            (.testB, "4", false),
            (.testC, "1", true),
            (.testD, "4", true),
        ]
        for (experiment, expectedAttempt, expectsCreateSession) in experiments {
            let http = MockHTTP()
            http.responses = [
                HTTPResponse(statusCode: 200, headers: [:],
                    data: plist(["customerMessage": "MZFinance.BadLogin.Configurator_message"])),
                HTTPResponse(statusCode: 200,
                    headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                    data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
            ]
            let signer = BodyCapture()
            let service = AuthenticationService(
                http: http, bagProvider: MockBag(), signer: signer,
                secrets: InMemorySecretStore(), guidProvider: { "AABBCCDDEEFF" },
                experiment: experiment
            )
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")

            // Both stages signed exactly one body each, with identical
            // schema: same attempt field, same createSession presence.
            XCTAssertEqual(signer.bodies.count, 2)
            guard signer.bodies.count == 2 else { continue }
            let passwordPlist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: signer.bodies[0], format: nil) as? [String: Any])
            let twoFAPlist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: signer.bodies[1], format: nil) as? [String: Any])
            XCTAssertEqual(passwordPlist["attempt"] as? String, expectedAttempt)
            XCTAssertEqual(twoFAPlist["attempt"] as? String, expectedAttempt)
            XCTAssertEqual(passwordPlist["createSession"] != nil, expectsCreateSession)
            XCTAssertEqual(twoFAPlist["createSession"] != nil, expectsCreateSession)
            // The only payload difference between the stages is the
            // password field contents (code appended).
            XCTAssertEqual(passwordPlist["password"] as? String, "pw")
            XCTAssertEqual(twoFAPlist["password"] as? String, "pw123456")
        }
    }

    func testTwoFactorSubmissionUsesFreshSignerOnSameIdentity() async throws {
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

        // Reference-flow diagnostic: the 2FA submit builds a NEW signer on
        // the SAME machine identity — two factory calls, identical
        // hardware IDs (GUID/machineID preserved, no rotation).
        XCTAssertEqual(factory.hardwareIDs.count, 2)
        guard factory.hardwareIDs.count == 2 else { return }
        XCTAssertEqual(factory.hardwareIDs[0], factory.hardwareIDs[1])
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

    func testTwoFactorEmpty404RetriesWithoutRotation() async throws {
        let http = ScriptedHTTP()
        // ipatool parity: the 2FA submit keeps the challenge's GUID and
        // backs off on an empty 404 instead of rotating.
        http.responses = [
            HTTPResponse(statusCode: 404, headers: [:], data: Data()),
            HTTPResponse(statusCode: 404, headers: [:], data: Data()),
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let factory = RecordingSignerFactory()
        let secrets = InMemorySecretStore()
        try secrets.save(Data("AABBCCDDEEFF".utf8), for: DeviceIdentity.keychainKey)
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { id in try await factory.make(id) },
            secrets: secrets,
            sleep: { _ in }
        )

        let result = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
        guard case .success = result else { return XCTFail("Expected success after 404 retries") }

        XCTAssertFalse(factory.hardwareIDs.isEmpty)
        for id in factory.hardwareIDs {
            XCTAssertEqual(id, Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        }
        let stored = try XCTUnwrap(secrets.load(key: DeviceIdentity.keychainKey))
        XCTAssertEqual(String(data: stored, encoding: .utf8), "AABBCCDDEEFF")
    }

    func testTwoFactorEmpty404ExhaustedIsTransportFailure() async throws {
        let http = ScriptedHTTP()
        http.responses = (0..<3).map { _ in
            HTTPResponse(statusCode: 404, headers: [:], data: Data())
        }
        let factory = RecordingSignerFactory()
        let secrets = InMemorySecretStore()
        try secrets.save(Data("AABBCCDDEEFF".utf8), for: DeviceIdentity.keychainKey)
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { id in try await factory.make(id) },
            secrets: secrets,
            sleep: { _ in }
        )

        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
            XCTFail("Expected networkUnavailable")
        } catch AppStoreError.networkUnavailable {
            // expected: ipatool reports an empty 404 as a transport failure,
            // never as a wrong code
        } catch {
            XCTFail("Wrong error: \(error)")
        }

        // No rotation: every signer shares the challenge's hardware ID.
        XCTAssertFalse(factory.hardwareIDs.isEmpty)
        for id in factory.hardwareIDs {
            XCTAssertEqual(id, Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        }
        XCTAssertEqual(http.requestCount, 3)
    }

    func testTwoFactor5xxRetriesWithoutRotation() async throws {
        let http = ScriptedHTTP()
        // Bodyless 5xx on the 2FA submit are transient, not a wrong code
        // and not an edge GUID refusal: retry on the same GUID, then succeed.
        http.responses = [
            HTTPResponse(statusCode: 503, headers: [:], data: Data()),
            HTTPResponse(statusCode: 500, headers: [:], data: Data()),
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let factory = RecordingSignerFactory()
        let secrets = InMemorySecretStore()
        try secrets.save(Data("AABBCCDDEEFF".utf8), for: DeviceIdentity.keychainKey)
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { id in try await factory.make(id) },
            secrets: secrets,
            sleep: { _ in }
        )

        let result = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
        guard case .success = result else { return XCTFail("Expected success after transient retries") }
        XCTAssertFalse(factory.hardwareIDs.isEmpty)
        for id in factory.hardwareIDs {
            XCTAssertEqual(id, Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        }
        XCTAssertEqual(http.requestCount, 3)
    }

    func testPasswordStage5xxRetriesThenSucceeds() async throws {
        let http = ScriptedHTTP()
        http.responses = [
            HTTPResponse(statusCode: 500, headers: [:], data: Data()),
            HTTPResponse(statusCode: 503, headers: [:], data: Data()),
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

        let result = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        guard case .success = result else { return XCTFail("Expected success after transient retries") }
        // Retries within budget: no rotation needed.
        XCTAssertEqual(factory.hardwareIDs.count, 1)
        XCTAssertEqual(http.requestCount, 3)
    }

    func testExhausted2FARestartsWithFreshChallengeFlow() async throws {
        let http = ScriptedHTTP()
        // 2FA submit 404s through the whole retry budget; the next sign-in
        // must start a fresh password flow (new signer, attempt "4") and
        // receive a fresh challenge instead of reusing the dead one.
        http.responses = (0..<3).map { _ in
            HTTPResponse(statusCode: 404, headers: [:], data: Data())
        } + [
            HTTPResponse(statusCode: 200, headers: [:],
                data: plist(["customerMessage": "MZFinance.BadLogin.Configurator_message"])),
        ]
        let factory = RecordingSignerFactory()
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { id in try await factory.make(id) },
            secrets: InMemorySecretStore(),
            sleep: { _ in }
        )

        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
            XCTFail("Expected networkUnavailable")
        } catch AppStoreError.networkUnavailable {
            // expected
        }

        let next = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        XCTAssertEqual(next, .twoFactorRequired)
        // One signer per invocation, as in ipatool's Login.
        XCTAssertEqual(factory.hardwareIDs.count, 2)
    }

    func testPodHeaderNeverBecomesRequestHost() async throws {
        // Regression for v0.3.27: the Pod/itspod response header ("20") is
        // routing metadata, not a hostname. The 2FA submit must keep using
        // the bag auth endpoint; only an actual 302 Location may change it.
        let http = MockHTTP()
        http.responses = [
            // Password: backend assigns pod 20 and requires 2FA.
            HTTPResponse(statusCode: 200,
                headers: ["pod": "20", "itspod": "20"],
                data: plist(["customerMessage": "MZFinance.BadLogin.Configurator_message"])),
            // 2FA submit: succeeds.
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { _ in MockSigner() },
            secrets: InMemorySecretStore(),
            sleep: { _ in }
        )

        let first = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        XCTAssertEqual(first, .twoFactorRequired)
        let second = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: "123456")
        guard case .success = second else { return XCTFail("Expected success") }

        // Both requests went to real hosts; "20" was never used as a host.
        XCTAssertEqual(http.requests.count, 2)
        for request in http.requests {
            let host = try XCTUnwrap(request.url.host)
            XCTAssertTrue(host.hasSuffix("itunes.apple.com"), "pod ID leaked into host: \(host)")
        }
    }

    func test302LocationBecomesEndpointVerbatim() async throws {
        // A real 302 from Apple carries the full pod URL; the next request
        // uses that exact Location, including its Pod/PRH query.
        let podURL = "https://p35-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?Pod=35&PRH=35"
        let http = MockHTTP()
        http.responses = [
            HTTPResponse(statusCode: 302, headers: ["Location": podURL], data: Data()),
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { _ in MockSigner() },
            secrets: InMemorySecretStore(),
            sleep: { _ in }
        )

        let result = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
        guard case .success = result else { return XCTFail("Expected success") }
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[1].url.absoluteString, podURL)
        XCTAssertEqual(http.requests[1].url.host, "p35-buy.itunes.apple.com")
    }

    func testNonAppleRedirectIsRejected() async {
        // A redirect outside Apple's authentication pods is refused; the
        // endpoint must never become an arbitrary host.
        let http = MockHTTP()
        http.responses = [
            HTTPResponse(statusCode: 302,
                headers: ["Location": "https://example.com/steal"], data: Data()),
        ]
        let service = AuthenticationService(
            http: http,
            bagProvider: MockBag(),
            signerFactory: { _ in MockSigner() },
            secrets: InMemorySecretStore(),
            sleep: { _ in }
        )

        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            XCTFail("Expected rejection of non-Apple redirect")
        } catch {
            // Expected: BagService.validate throws; example.com never used.
        }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests[0].url.host, "buy.itunes.apple.com")
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
        var bodies: [Data] = []
        func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
            requestCount += 1
            if let body { bodies.append(body) }
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

        // 10s fallback, then Retry-After 5s takes precedence (ipatool).
        XCTAssertEqual(sleeps.delaysNs, [10_000_000_000, 5_000_000_000])
        XCTAssertEqual(http.requestCount, 3)
    }

    func testRetryAfterOverBudgetAborts() async throws {
        let http = ScriptedHTTP()
        http.responses = [
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "600"], data: Data()),
            HTTPResponse(statusCode: 200,
                headers: ["X-Set-Apple-Store-Front": "143441-1,29"],
                data: plist(["dsPersonId": "1", "passwordToken": "tok"])),
        ]
        let sleeps = Sleeps()
        let service = makeService(http: http, sleeps: sleeps)

        do {
            _ = try await service.signIn(email: "u@e.com", password: "pw", twoFactorCode: nil)
            XCTFail("Expected rateLimited")
        } catch AppStoreError.rateLimited(let seconds) {
            XCTAssertEqual(seconds, 600)
        }
        // ipatool ends the login instead of retrying before Apple's deadline.
        XCTAssertEqual(sleeps.delaysNs, [])
        XCTAssertEqual(http.requestCount, 1)
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

    // MARK: - Stable identity on empty 404 (ipatool never rotates)

    /// Records the hardware IDs the signer factory was asked to build with.
    final class RecordingSignerFactory: @unchecked Sendable {
        private(set) var hardwareIDs: [Data] = []
        func make(_ hardwareID: Data) async throws -> any SAPSigning {
            hardwareIDs.append(hardwareID)
            return MockSigner()
        }
    }

    func testPasswordEmpty404RetriesOnSameGUID() async throws {
        let http = ScriptedHTTP()
        http.responses = [
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
        guard case .success = result else { return XCTFail("Expected success after retry") }
        XCTAssertEqual(http.requestCount, 2)
        XCTAssertEqual(factory.hardwareIDs, [Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])])
        let stored = try XCTUnwrap(secrets.load(key: DeviceIdentity.keychainKey))
        XCTAssertEqual(String(data: stored, encoding: .utf8), "AABBCCDDEEFF")
        // Both sends carry the same GUID in the body.
        for body in http.bodies {
            let dict = try XCTUnwrap(PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any])
            XCTAssertEqual(dict["guid"] as? String, "AABBCCDDEEFF")
        }
    }

    func testPersistentEmpty404FailsAfterThreeSends() async {
        let http = ScriptedHTTP()
        http.responses = (0..<6).map { _ in
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
            XCTFail("Expected networkUnavailable")
        } catch AppStoreError.networkUnavailable {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertEqual(factory.hardwareIDs.count, 1)
        XCTAssertEqual(http.requestCount, 3)
    }
}
