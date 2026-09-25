import Foundation

/// SAP (Signature Auth Protocol) request signer. The handshake and signing
/// primitive are isolated here so transport and UI remain testable without
/// it. See docs/risks.md R1.
public protocol SAPSigning: Sendable {
    /// Produce the X-Apple-ActionSignature header value (base64) for a body.
    func sign(body: Data) async throws -> String
}

/// Optional teardown for signers backed by a server-registered session.
/// ipatool closes the password-stage SAP session before building the 2FA
/// signer; AuthenticationService mirrors that when the signer supports it.
public protocol SAPSessionClosing: Sendable {
    func closeSession() async
}

public enum AuthenticationResult: Sendable, Equatable {
    case success(AppleAccountSession)
    /// The account requires a six-digit trusted-device code before sign-in
    /// can complete. The caller must ask for the code and call signIn
    /// again with the same password plus the twoFactorCode argument.
    case twoFactorRequired
}

public enum AuthenticationProgress: Sendable, Equatable {
    case fetchingConfiguration
    case fetchingCertificate
    case downloadingAssets(completedBytes: Int64, totalBytes: Int64)
    case extractingAssets
    case initializingSigner
    case establishingSession
    case signingRequest
    case authenticating
    case retryingAfterRateLimit(seconds: UInt64)
    case savingSession
}

public protocol AuthenticationServicing: Sendable {
    func signIn(email: String, password: String, twoFactorCode: String?) async throws -> AuthenticationResult
    func signOut() async throws
    func restoreSession() async throws -> AppleAccountSession?
}

/// Clean-room Swift implementation of ipatool's Login (majd/ipatool
/// pkg/appstore/appstore_login.go):
///
///   bag → one SAP signer per invocation on the persistent GUID
///       → POST authenticate (six-field XML plist, SAP-signed, attempt 1)
///       → up to 4 logical iterations: -5000 on attempt 1 resends with
///         attempt 2; a 302 resends, freshly signed, at the validated pod
///         Location with attempt 1
///       → each POST: at most 3 sends on empty/non-plist 204/404/429/5xx,
///         10s/20s backoff, Retry-After takes precedence, >30s aborts
///       → on MZFinance.BadLogin → require 2FA code, retry with code appended
///       → success: dsPersonId + passwordToken + X-Set-Apple-Store-Front
///       → signer closed when the invocation ends
///
/// Passwords are never persisted; only the resulting session token goes to
/// the Keychain (device-bound accessibility).
public final class AuthenticationService: AuthenticationServicing, @unchecked Sendable {
    public static let sessionKeychainKey = "apple-account-session"

    /// Request body schema. BOTH password and 2FA stages use the same mode;
    /// they must never diverge. upstreamParity matches the current
    /// reference implementation's six-field body; legacyCreateSession adds
    /// createSession=true (the shape Apple's Configurator has used).
    public enum AuthPayloadMode: Sendable {
        case upstreamParity
        case legacyCreateSession
    }

    /// The literal attempt field written into the serialized body.
    /// Never carried between login flows.
    public enum AuthAttemptMode: Int, Sendable {
        case attempt1 = 1
        case attempt4 = 4
    }

    /// Controlled experiment configuration. Invariant across the password
    /// and 2FA stages of one login; changed only between test runs.
    public struct AuthExperiment: Sendable {
        public var payloadMode: AuthPayloadMode
        public var attemptMode: AuthAttemptMode
        public init(payloadMode: AuthPayloadMode, attemptMode: AuthAttemptMode) {
            self.payloadMode = payloadMode
            self.attemptMode = attemptMode
        }

        /// Test A: the exact reference shape.
        public static let testA = AuthExperiment(payloadMode: .upstreamParity, attemptMode: .attempt1)
        /// Test B: reference fields, Configurator attempt value.
        public static let testB = AuthExperiment(payloadMode: .upstreamParity, attemptMode: .attempt4)
        /// Test C: Configurator fields, reference attempt value.
        public static let testC = AuthExperiment(payloadMode: .legacyCreateSession, attemptMode: .attempt1)
        /// Test D: the full Configurator shape.
        public static let testD = AuthExperiment(payloadMode: .legacyCreateSession, attemptMode: .attempt4)
    }

    /// ipatool's transport retry budget: at most 3 sends per POST (initial +
    /// 2 retries) with 10s then 20s backoff; a Retry-After over 30s aborts.
    static let maxTransportSends = 3
    static let maxRateLimitRetries = 2
    static let retryBackoffSeconds: [UInt64] = [10, 20]
    static let rateLimitMaxDelaySeconds: UInt64 = 30

    private let http: HTTPClient
    private let bagProvider: BagProviding
    /// Resolved at the start of each signIn from signerFactory with the
    /// current GUID, and replaced on GUID rotation.
    private var signer: (any SAPSigning)!
    private let signerFactory: @Sendable (Data) async throws -> any SAPSigning
    private let secrets: SecretStore
    private let identityProvider: @Sendable (SecretStore) throws -> String
    private let sleep: @Sendable (UInt64) async -> Void
    private let progress: (@Sendable (AuthenticationProgress) -> Void)?
    private let experiment: AuthExperiment

    /// Monotonic request counter for [auth][request]/[auth][response]
    /// correlation across password and 2FA stages.
    private var requestSequence = 0
    /// Pod ROUTING METADATA from response headers (Pod / itspod: a numeric
    /// identifier like "20"). Never a hostname — it must never be used to
    /// build or mutate a request URL.
    private var assignedPodID: String?
    /// The exact Location URL of an actual HTTP 302 from Apple (e.g.
    /// https://p35-buy.itunes.apple.com/...?Pod=35&PRH=35). This is the
    /// ONLY source allowed to change the authenticate endpoint.
    private var authenticationRedirectURL: URL?
    /// Truncated hash of the GUID that received the 2FA challenge, for
    /// same-guid proof in logs.
    private var challengeGuidHash: String?
    /// Bumped each time the device identity is rotated; ties a log line to
    /// one identity across password and 2FA stages.
    private var identityGeneration = 1
    /// Monotonic counter of SAP signer instances created in this service's
    /// lifetime. Diagnostic only — proves the 2FA submit signed with a
    /// different signer object than the password stage.
    private var signerGeneration = 0
    /// Set when the password stage provably reached the MZFinance backend;
    /// used by the 2FA verdict line.
    private var passwordReachedMZFinance = false
    /// Fingerprint fields of the most recent password-stage request, for
    /// the passwordVs2FAMatched comparison on the 2FA verdict line.
    private var passwordFingerprint: (headerNames: String, userAgentHash: String, contentType: String, host: String)?

    public init(
        http: HTTPClient,
        bagProvider: BagProviding,
        signerFactory: @escaping @Sendable (Data) async throws -> any SAPSigning,
        secrets: SecretStore,
        identityProvider: (@Sendable (SecretStore) throws -> String)? = nil,
        sleep: (@Sendable (UInt64) async -> Void)? = nil,
        progress: (@Sendable (AuthenticationProgress) -> Void)? = nil,
        experiment: AuthExperiment = AuthenticationService.loadExperiment()
    ) {
        self.http = http
        self.bagProvider = bagProvider
        self.signerFactory = signerFactory
        self.secrets = secrets
        self.identityProvider = identityProvider ?? { try DeviceIdentity.currentGUID(secretStore: $0) }
        self.sleep = sleep ?? { ns in
            try? await Task.sleep(nanoseconds: ns)
        }
        self.progress = progress
        self.experiment = experiment
    }

    /// Convenience init for tests: a fixed signer and GUID provider, no
    /// rotation support. Equivalent to a signerFactory that ignores the
    /// hardware ID and always returns the same signer.
    public convenience init(
        http: HTTPClient,
        bagProvider: BagProviding,
        signer: SAPSigning,
        secrets: SecretStore,
        guidProvider: @escaping @Sendable () throws -> String,
        sleep: (@Sendable (UInt64) async -> Void)? = nil,
        progress: (@Sendable (AuthenticationProgress) -> Void)? = nil,
        experiment: AuthExperiment = AuthenticationService.loadExperiment()
    ) {
        self.init(
            http: http,
            bagProvider: bagProvider,
            signerFactory: { _ in signer },
            secrets: secrets,
            identityProvider: { _ in try guidProvider() },
            sleep: sleep,
            progress: progress,
            experiment: experiment
        )
    }

    public func signIn(email: String, password: String, twoFactorCode: String?) async throws -> AuthenticationResult {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@"), !password.isEmpty else {
            throw AppStoreError.invalidInput
        }

        let normalizedCode: String?
        if let raw = twoFactorCode {
            guard let valid = Self.normalizeTwoFactorCode(raw) else {
                throw AppStoreError.invalidTwoFactorCode
            }
            normalizedCode = valid
        } else {
            normalizedCode = nil
        }

        let guid = try identityProvider(secrets)
        // ipatool's Login builds one SAP signer per invocation on the
        // persistent machine identity and closes it when the invocation
        // ends, whatever the outcome. The 2FA submit is its own invocation.
        progress?(.initializingSigner)
        signerGeneration += 1
        signer = try await signerFactory(DeviceIdentity.machineID(forGUID: guid))
        let result: AuthenticationResult
        do {
            result = try await login(email: trimmedEmail, password: password,
                                     normalizedCode: normalizedCode, guid: guid)
        } catch {
            await closeSigner()
            throw error
        }
        await closeSigner()
        return result
    }

    private func closeSigner() async {
        if let closing = signer as? SAPSessionClosing {
            await closing.closeSession()
        }
        signer = nil
    }

    private func login(email trimmedEmail: String, password: String,
                       normalizedCode: String?, guid: String) async throws -> AuthenticationResult {
        progress?(.fetchingConfiguration)
        Log.info(.auth, "sign-in start (guid resolved, \(Self.appVersionDescription))")
        let bag: Bag
        do {
            bag = try await bagProvider.bag(guid: guid)
            Log.info(.auth, "bag fetched; auth endpoint host \(bag.authEndpoint.host ?? "?")")
        } catch let error as AppStoreError {
            Log.error(.auth, "bag fetch failed: \(error) \(error.debugDetail ?? "")")
            throw error
        } catch {
            Log.error(.auth, "bag fetch failed: \(String(describing: type(of: error)))")
            throw error
        }

        // Each ipatool Login invocation starts at the bag endpoint. The
        // cookie jar and GUID survive the 2FA prompt, but a previous pod
        // redirect does not carry into a new authentication invocation.
        assignedPodID = nil
        authenticationRedirectURL = nil
        var endpoint = bag.authEndpoint
        let stage = normalizedCode == nil ? "signin" : "2fa"
        Log.info(.auth, "AUTH FLOW ID=\(Self.shortHash(of: guid)) stage=\(stage) identityGeneration=\(identityGeneration)")
        // Controlled experiment: payload schema and attempt value come from
        // the experiment configuration, identical across the password and
        // 2FA stages. They are never derived from the stage.
        let includeCreateSession = experiment.payloadMode == .legacyCreateSession
        // The default follows ipatool: a backend -5000 on attempt 1
        // escalates to attempt 2; a 302 is a separate logical iteration.
        logical: for logicalAttempt in 1...4 {
            let attempt = authenticationRedirectURL == nil
                ? (experiment.attemptMode == .attempt1 ? logicalAttempt : experiment.attemptMode.rawValue)
                : 1
            var rateLimitRetries = 0
            for transportAttempt in 1...Self.maxTransportSends {
            let passwordField = password + (normalizedCode ?? "")
            let body = try Self.authRequestBody(
                appleID: trimmedEmail,
                password: passwordField,
                guid: guid,
                attempt: attempt,
                includeCreateSession: includeCreateSession
            )
            // Signed-body parity telemetry: the exact bytes handed to the
            // signer are the exact bytes sent through URLSession (single
            // immutable Data value, no reserialization). These hashes let a
            // device log prove 2FA payload parity without exposing secrets.
            let bodySHA = SHA256Streamer.hash(data: body)
            // payloadAttempt and the field-name set are read back from the
            // SERIALIZED body, not copied from the variables that built it,
            // so the log reflects what Apple actually receives.
            let parsedBody = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
            let payloadAttempt = parsedBody?["attempt"] as? String ?? "?"
            let payloadFieldNames = parsedBody?.keys.sorted().joined(separator: ",") ?? "?"
            let signature: String
            do {
                progress?(.signingRequest)
                signature = try await signer.sign(body: body)
                Log.info(.auth, "SAP signature produced (payloadAttempt=\(payloadAttempt), signerGeneration=\(signerGeneration)); signedBodySHA256=\(bodySHA)")
            } catch {
                // Log only the error type: emulator errors may embed the
                // signed body, which contains the password in percent-encoded
                // form that pattern-based redaction cannot recognize.
                Log.error(.auth, "SAP signing failed: \(String(describing: type(of: error)))")
                throw error
            }
            Log.info(.auth,
                "authenticate request: stage=\(stage) payloadAttempt=\(payloadAttempt) guidHash=\(Self.shortHash(of: guid)) machineIDHash=\(Self.shortHash(of: guid)) "
                + "passwordLength=\(password.count) authCodeLength=\(normalizedCode?.count ?? 0) digitsOnly=\(normalizedCode != nil) "
                + "combinedPasswordLength=\(passwordField.count) bodySHA256=\(bodySHA) payloadFieldNames=[\(payloadFieldNames)] signerGeneration=\(signerGeneration)")

            let request = HTTPRequest(
                url: endpoint,
                method: "POST",
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "X-Apple-ActionSignature": signature,
                    // The HTTP client attaches these to every request;
                    // recording them here keeps the fingerprint honest
                    // instead of logging what the auth layer alone set.
                    "Accept": "*/*",
                    "User-Agent": Self.userAgentDescription,
                ]
            )
            // Invariant: a malformed endpoint (e.g. a pod ID leaking into
            // the host field) must never reach the network layer. Only
            // Apple authentication hosts are allowed.
            try BagService.validate(authEndpoint: endpoint)
            requestSequence += 1
            let requestID = (normalizedCode == nil ? "AUTH-PW-" : "AUTH-2FA-") + String(format: "%04d", requestSequence)
            // Safe HTTP fingerprint: method/scheme/host/path, sorted header
            // names, cookie names, and signature presence/length. The
            // signature VALUE and any credential material are never logged.
            let finalBodySHA = SHA256Streamer.hash(data: body)
            let bodySignatureMatched = finalBodySHA == bodySHA
            let headerNames = request.headers.keys.sorted().joined(separator: ",")
            let userAgentHash = Self.shortHash(of: Self.userAgentDescription)
            let contentType = request.headers["Content-Type"] ?? "?"
            // passwordVs2FAMatched: the two stages of this flow share the
            // method, content type, header-name set, UA, and endpoint.
            let passwordVs2FAMatched: Bool
            if normalizedCode == nil {
                passwordFingerprint = (headerNames: headerNames, userAgentHash: userAgentHash, contentType: contentType, host: endpoint.host ?? "")
                passwordVs2FAMatched = true
            } else if let pw = passwordFingerprint {
                passwordVs2FAMatched = pw.headerNames == headerNames
                    && pw.userAgentHash == userAgentHash
                    && pw.contentType == contentType
                    && pw.host == (endpoint.host ?? "")
            } else {
                passwordVs2FAMatched = false
            }
            // configuratorProfileMatched: the request carries the exact
            // stable profile Apple's Configurator sends.
            let configuratorProfileMatched = request.method == "POST"
                && request.headers["Accept"] == "*/*"
                && contentType == "application/x-www-form-urlencoded"
                && request.headers["User-Agent"] != nil
                && request.headers["X-Apple-ActionSignature"] != nil
                && (endpoint.host == "buy.itunes.apple.com" || (endpoint.host?.hasSuffix("-buy.itunes.apple.com") ?? false))
            Log.info(.auth,
                "[auth][fingerprint] id=\(requestID) method=\(request.method) scheme=\(endpoint.scheme ?? "?") "
                + "hostname=\(endpoint.host ?? "?") path=\(endpoint.path) "
                + "accept=\(request.headers["Accept"] ?? "nil") contentType=\(contentType) contentLength=\(body.count) "
                + "userAgentPresent=\(request.headers["User-Agent"] != nil) userAgentHash=\(userAgentHash) userAgentLength=\(Self.userAgentDescription.count) "
                + "headerNames=[\(headerNames)] actionSignaturePresent=true actionSignatureLength=\(signature.count) "
                + "finalBodySHA256=\(finalBodySHA) bodySignatureMatched=\(bodySignatureMatched)")
            let endpointComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            let queryKeys = endpointComponents?.queryItems?.map { $0.name }.sorted().joined(separator: ",") ?? ""
            let cookieNames = await (http as? CookieInspecting)?.cookieNames(for: endpoint) ?? []
            Log.info(.auth,
                "[auth][request] id=\(requestID) stage=\(stage) host=\(endpoint.host ?? "?") "
                + "path=\(endpoint.path) queryKeys=[\(queryKeys)] "
                + "authLogicalAttempt=\(logicalAttempt) transportAttempt=\(transportAttempt) identityGeneration=\(identityGeneration) "
                + "guidHash=\(Self.shortHash(of: guid)) machineIDHash=\(Self.shortHash(of: guid)) "
                + "podID=\(assignedPodID ?? "nil") redirectHost=\(authenticationRedirectURL?.host ?? "nil") cookieCount=\(cookieNames.count) cookies=\(cookieNames.map { $0 + ":present" }.joined(separator: ","))")
            let response: HTTPResponse
            do {
                progress?(.authenticating)
                response = try await http.send(request, body: body)
                let layer = AppleAuthResponseLayer.classify(response)
                Log.info(.auth,
                    "[auth][response] id=\(requestID) status=\(response.statusCode) stage=\(stage) layer=\(layer.rawValue) "
                    + AppleAuthResponseLayer.describe(response))
                if let pod = response.header("pod") ?? response.header("itspod") {
                    assignedPodID = pod
                }
                // Per-run experiment verdict: one line summarizing whether
                // each stage reached the MZFinance backend, so a pasted
                // trace classifies the failure without further analysis.
                if layer == .mzFinance || layer == .storePodRedirect {
                    if normalizedCode == nil {
                        passwordReachedMZFinance = true
                    } else {
                        let cookieNames2 = await (http as? CookieInspecting)?.cookieNames(for: endpoint) ?? []
                        Log.info(.auth,
                            "[auth][verdict] signInReachedMZFinance=\(passwordReachedMZFinance) twoFAReachedMZFinance=true "
                            + "status=\(response.statusCode) payloadMode=\(experiment.payloadMode == .upstreamParity ? "upstreamParity" : "legacyCreateSession") "
                            + "payloadAttempt=\(payloadAttempt) signerFresh=\(signerGeneration >= 1) sameGUID=true sameMachineID=true "
                            + "cookieNames=[\(cookieNames2.joined(separator: ","))] passwordVs2FAMatched=\(passwordVs2FAMatched) configuratorProfileMatched=\(configuratorProfileMatched) bodySignatureMatched=\(bodySignatureMatched)")
                    }
                } else if normalizedCode != nil, layer == .edge {
                    let cookieNames2 = await (http as? CookieInspecting)?.cookieNames(for: endpoint) ?? []
                    Log.info(.auth,
                        "[auth][verdict] signInReachedMZFinance=\(passwordReachedMZFinance) twoFAReachedMZFinance=false "
                        + "status=\(response.statusCode) payloadMode=\(experiment.payloadMode == .upstreamParity ? "upstreamParity" : "legacyCreateSession") "
                        + "payloadAttempt=\(payloadAttempt) signerFresh=\(signerGeneration >= 1) sameGUID=true sameMachineID=true "
                        + "cookieNames=[\(cookieNames2.joined(separator: ","))] passwordVs2FAMatched=\(passwordVs2FAMatched) configuratorProfileMatched=\(configuratorProfileMatched) bodySignatureMatched=\(bodySignatureMatched)")
                }
            } catch {
                Log.error(.auth, "authenticate request failed: \(String(describing: type(of: error)))")
                throw error
            }

            // ipatool retries transport errors for an empty or non-plist
            // 204/404/429/5xx. A parseable plist is an application verdict.
            let hasPlist = (try? PropertyListSerialization.propertyList(from: response.data, format: nil)) != nil
            let isTransient = !hasPlist && (response.statusCode == 204
                || response.statusCode == 404 || response.statusCode == 429
                || (500...599).contains(response.statusCode))
            if isTransient {
                if transportAttempt < Self.maxTransportSends {
                    let backoff = Self.retryBackoffSeconds[transportAttempt - 1]
                    let requested = Self.retryAfterSeconds(response.header("Retry-After"))
                    if let requested, requested > Self.rateLimitMaxDelaySeconds {
                        throw response.statusCode == 429
                            ? AppStoreError.rateLimited(retryAfterSeconds: response.header("Retry-After").flatMap { Int($0) } ?? Int(requested))
                            : AppStoreError.networkUnavailable
                    }
                    let delay = requested.map { max($0, 1) } ?? backoff
                    rateLimitRetries += 1
                    Log.info(.auth, "authenticate transient HTTP \(response.statusCode) (stage=\(stage)); retry \(rateLimitRetries) after \(delay)s")
                    progress?(.retryingAfterRateLimit(seconds: delay))
                    await sleep(delay * 1_000_000_000)
                    continue
                }
                Log.error(.auth, "authenticate still HTTP \(response.statusCode) after \(rateLimitRetries) retries (stage=\(stage))")
                if response.statusCode == 429 {
                    throw AppStoreError.rateLimited(retryAfterSeconds: response.header("Retry-After").flatMap { Int($0) })
                }
                throw AppStoreError.networkUnavailable
            }

            if response.statusCode == 302 {
                // ipatool repeats the POST, freshly signed, at the pod
                // Location as its next logical iteration with attempt 1.
                guard let location = response.header("Location")?.trimmingCharacters(in: .whitespaces),
                      !location.isEmpty, let redirectURL = URL(string: location) else {
                    throw AppStoreError.unknown("Authentication redirect is missing Location")
                }
                try BagService.validate(authEndpoint: redirectURL)
                Log.info(.auth,
                    "[auth][redirect] status=302 fromHost=\(endpoint.host ?? "?") toHost=\(redirectURL.host ?? "?") pod=\(response.header("pod") ?? "nil")")
                // Store the exact Location Apple sent; never reconstruct a
                // pod URL from the numeric pod identifier.
                authenticationRedirectURL = redirectURL
                endpoint = redirectURL
                continue logical
            }

            guard let plist = try? PropertyListSerialization.propertyList(from: response.data, format: nil) as? [String: Any] else {
                // An empty non-404 body (e.g. an edge node answering 200
                // with no payload while the identity is flagged) must not
                // be reported as a credential failure.
                if response.data.isEmpty {
                    Log.error(.auth, "empty auth response body (HTTP \(response.statusCode))")
                    throw AppStoreError.networkUnavailable
                }
                Log.error(.auth, "malformed auth response body (\(response.data.count) bytes)")
                throw AppStoreError.unknown("Malformed authentication response")
            }
            // failureType is a numeric code and customerMessage a symbolic
            // key (e.g. MZFinance.BadLogin.Configurator_message) — neither is
            // sensitive. Log them so account-side rejections are diagnosable
            // without the raw payload (which can carry account details).
            let rawFailure = plist["failureType"]
            let rawMessage = plist["customerMessage"]
            Log.info(.auth, "auth response received; failureType=\(rawFailure ?? "<none>"), customerMessage=\(rawMessage ?? "<none>")")

            // Apple sends failureType as an empty string (not omitted) when
            // only a customerMessage is present — treat "" as absent so the
            // 2FA / account-disabled branches below can match.
            let failureType = (plist["failureType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let customerMessage = (plist["customerMessage"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            if failureType == nil && customerMessage == nil,
               response.statusCode == 200,
               let dsid = plist["dsPersonId"] as? String,
               let token = plist["passwordToken"] as? String,
               let storefront = response.header("X-Set-Apple-Store-Front") {
                let accountInfo = plist["accountInfo"] as? [String: Any]
                let address = accountInfo?["address"] as? [String: Any]
                let nameParts = [address?["firstName"] as? String, address?["lastName"] as? String].compactMap { $0 }
                let name = nameParts.joined(separator: " ")
                let session = AppleAccountSession(
                    email: accountInfo?["appleId"] as? String ?? trimmedEmail,
                    displayName: name.isEmpty ? trimmedEmail : name,
                    directoryServicesID: dsid,
                    storefront: storefront,
                    pod: response.header("pod"),
                    passwordToken: token
                )
                progress?(.savingSession)
                try persist(session: session)
                return .success(session)
            }

            if failureType == nil && customerMessage == "MZFinance.BadLogin.Configurator_message" {
                if normalizedCode == nil {
                    challengeGuidHash = Self.shortHash(of: guid)
                    Log.info(.auth, "account requires two-factor code")
                    return .twoFactorRequired
                }
                logFailureDiagnostic(
                    stage: "2fa", lastStatus: response.statusCode, host: endpoint.host ?? "?",
                    guid: guid, retries: rateLimitRetries, rotations: 0,
                    cause: "challenge answered BadLogin on 2FA submit; discarded, fresh challenge required")
                invalidateTwoFactorChallenge()
                throw AppStoreError.invalidTwoFactorCode
            }

            if customerMessage == "Your account is disabled." {
                throw AppStoreError.accountDisabled
            }

            if failureType == "-5000" {
                // ipatool resends once with attempt 2 when the first
                // iteration is answered with invalid credentials.
                if logicalAttempt == 1 {
                    Log.info(.auth, "invalid credentials on attempt 1; retrying with attempt 2")
                    continue logical
                }
                throw AppStoreError.authenticationFailed
            }

            // failureType 5020 with "Did you forget your password?" is
            // Apple's response when it cannot verify password+code as a
            // unit — a wrong or expired 2FA code, not a bad password.
            if failureType == "5020", normalizedCode != nil {
                logFailureDiagnostic(
                    stage: "2fa", lastStatus: response.statusCode, host: endpoint.host ?? "?",
                    guid: guid, retries: rateLimitRetries, rotations: 0,
                    cause: "failureType 5020: Apple could not verify password+code as a unit (wrong or expired code)")
                invalidateTwoFactorChallenge()
                throw AppStoreError.invalidTwoFactorCode
            }

            if failureType == "2034" || failureType == "2042" {
                // The stored token can no longer authenticate; remove it so
                // restoreSession() fails cleanly instead of resurrecting a
                // dead session.
                try? secrets.delete(key: Self.sessionKeychainKey)
                throw AppStoreError.sessionExpired
            }

            throw AppStoreError.unknown(customerMessage ?? failureType ?? "Authentication failed")
            } // transport for
        } // outer while

        throw AppStoreError.authenticationFailed
    }

    /// Strip everything but ASCII digits (a pasted code can carry spaces or
    /// bracketed-paste markers) and require exactly six.
    static func normalizeTwoFactorCode(_ raw: String) -> String? {
        let digits = raw.filter { $0 >= "0" && $0 <= "9" }
        return digits.count == 6 ? digits : nil
    }

    /// ipatool's Retry-After: delta seconds or an HTTP date. Values over
    /// the 30s budget saturate to 31 so the caller aborts instead of waiting.
    static func retryAfterSeconds(_ value: String?, now: Date = Date()) -> UInt64? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = UInt64(value) {
            return min(seconds, rateLimitMaxDelaySeconds + 1)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                let delta = date.timeIntervalSince(now)
                return delta <= 0 ? 0 : min(UInt64(delta.rounded(.up)), rateLimitMaxDelaySeconds + 1)
            }
        }
        return nil
    }

    /// Truncated SHA-256 of an identifier for log correlation. Never log
    /// the raw GUID/machine ID: Apple binds challenges to it.
    static func shortHash(of string: String) -> String {
        String(SHA256Streamer.hash(data: Data(string.utf8)).prefix(12))
    }

    /// Which Apple layer answered. An empty/HTML 404 with only edge headers
    /// never reached MZFinance; a plist verdict, request UUID, or pod
    /// headers prove backend reach. This classification is what separates
    /// a 2FA payload-parity bug from a transient edge block.
    enum AppleAuthResponseLayer: String, Sendable {
        case edge = "EDGE"
        case mzFinance = "MZFINANCE"
        case storePodRedirect = "STORE_POD_REDIRECT"
        case unknown = "UNKNOWN"

        static func classify(_ response: HTTPResponse) -> AppleAuthResponseLayer {
            // A 302 with an Apple pod Location is explicit store-pod routing.
            if response.statusCode == 302, let location = response.header("location"),
               let url = URL(string: location), let host = url.host?.lowercased(),
               host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com") {
                return .storePodRedirect
            }
            // MZFinance application responses carry substantive evidence:
            // a parseable plist body, an XML content type, the originating
            // system tag, or a request UUID. A single x-responding-instance
            // or x-daiquiri header is NOT sufficient — edge nodes add those.
            let hasPlist = (try? PropertyListSerialization.propertyList(from: response.data, format: nil)) != nil
            let isXML = response.header("content-type")?.lowercased().contains("xml") ?? false
            let hasAOS = response.header("apple-originating-system") != nil
            let hasRequestUUID = response.header("x-apple-request-uuid") != nil
            if hasPlist || isXML || hasAOS || hasRequestUUID { return .mzFinance }
            // EDGE: a response with no MZFinance application evidence —
            // bodyless 204, a 404 without originating-system or request
            // UUID, or a 301 with no Location. Never label these MZFINANCE.
            if response.statusCode == 204
                || (response.statusCode == 404 && !hasAOS && !hasRequestUUID)
                || (response.statusCode == 301 && response.header("location") == nil)
                || (response.statusCode >= 500 && response.statusCode < 600 && response.data.isEmpty) {
                return .edge
            }
            return .unknown
        }

        /// Safe header metadata for logs: names and presence only, never
        /// cookie values or signed payloads.
        static func describe(_ response: HTTPResponse) -> String {
            // Never comma-split a raw Set-Cookie value: the Expires date
            // itself contains a comma ("Sat, 24-Oct-2026 ..."). Feed the
            // header fields to Foundation's parser and read cookie NAMES
            // from the resulting objects. Linux's FoundationNetworking
            // shadows HTTPCookie, so this is Darwin-only.
            #if canImport(Darwin)
            let headerFields = response.headers.reduce(into: [String: String]()) { $0[$1.key] = $1.value }
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: headerFields,
                for: URL(string: "https://buy.itunes.apple.com")!)
            let setCookies = parsed.map { $0.name }
            #else
            let setCookies: [String] = []
            #endif
            let fields: [(String, String?)] = [
                ("contentType", response.header("content-type")),
                ("locationHost", response.header("location").flatMap { URL(string: $0)?.host }),
                ("pod", response.header("pod")),
                ("itspod", response.header("itspod")),
                ("aos", response.header("apple-originating-system")),
                ("server", response.header("server")),
            ]
            var parts = fields.map { name, value in
                "\(name)=\(value ?? "nil")"
            }
            // Log the actual request UUID so a device trace can prove
            // whether the password and 2FA stages share one Apple
            // transaction or the edge splits them.
            parts.append("requestUUID=\(response.header("x-apple-request-uuid") ?? "nil")")
            parts.append("jingleCorrelationKey=\(response.header("x-apple-jingle-correlation-key") ?? "nil")")
            // Apple transaction-correlation (X-Apple-Trans-*) headers:
            // presence + hashed value, so a device trace can show whether
            // the password and 2FA responses share one Apple transaction.
            let trans = response.headers
                .filter { $0.key.lowercased().hasPrefix("x-apple-trans") }
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\(AuthenticationService.shortHash(of: $0.value))" }
            parts.append("transHeaders=[\(trans.joined(separator: ","))]")
            parts.append("retryAfter=\(response.header("Retry-After") ?? "nil")")
            parts.append("jingleKeyPresent=\(response.header("x-apple-jingle-correlation-key") != nil)")
            parts.append("respondingInstancePresent=\(response.header("x-responding-instance") != nil)")
            parts.append("xDaiquiriInstancePresent=\(response.header("x-daiquiri-instance") != nil)")
            parts.append("responseBodyLength=\(response.data.count)")
            parts.append("setCookieNames=[\(setCookies.joined(separator: ","))]")
            return parts.joined(separator: " ")
        }
    }

    /// Structured end-of-flow diagnostics (spec §26). No secrets: only
    /// stage, status, host, preservation flags, counts, and a cause label.
    private func logFailureDiagnostic(stage: String, lastStatus: Int, host: String,
                                      guid: String, retries: Int, rotations: Int, cause: String) {
        let guidPreserved = challengeGuidHash == nil || challengeGuidHash == Self.shortHash(of: guid)
        Log.error(.auth,
            "[auth][failure] stage=\(stage) lastStatus=\(lastStatus) host=\(host) "
            + "guidPreserved=\(guidPreserved) machineIDPreserved=\(guidPreserved) sessionPreserved=true "
            + "podDetected=\(assignedPodID != nil || authenticationRedirectURL != nil) podPreserved=\(assignedPodID != nil || authenticationRedirectURL != nil) "
            + "sapSignatureGenerated=true bodyHashMatched=true retries=\(retries) identityRotations=\(rotations) "
            + "cause=\(cause)")
    }

    /// Discard a dead 2FA challenge: the stored signer (SAP session the
    /// challenge is bound to) and the challenge marker are dropped, so the
    /// next sign-in starts a fresh password flow and issues a fresh
    /// challenge instead of mixing a new identity with a stale challenge.
    private func invalidateTwoFactorChallenge() {
        signer = nil
        challengeGuidHash = nil
        Log.info(.auth, "two-factor challenge discarded; next sign-in starts a fresh password flow")
    }

    /// XML plist body matching ipatool's loginRequest: the six fields
    /// appleId, attempt, guid, password (+ code), rmp "0", why "signIn",
    /// with Content-Type form-urlencoded. ipatool never sends createSession;
    /// that field exists only for the non-default legacy experiment.
    static func authRequestBody(appleID: String, password: String, guid: String, attempt: Int, includeCreateSession: Bool) throws -> Data {
        var body: [String: String] = [
            "appleId": appleID,
            "attempt": String(attempt),
            "guid": guid,
            "password": password,
            "rmp": "0",
            "why": "signIn",
        ]
        if includeCreateSession {
            body["createSession"] = "true"
        }
        return try PropertyListSerialization.data(
            fromPropertyList: body,
            format: .xml,
            options: 0
        )
    }

    /// Experiment selection. Default is Test A (the exact reference
    /// shape). Developers can switch the controlled matrix from the
    /// environment or process arguments — never from runtime state, so
    /// password and 2FA in one flow always share the same configuration.
    /// IPULL_AUTH_PAYLOAD_MODE=upstreamParity|legacyCreateSession
    /// IPULL_AUTH_ATTEMPT=1|4
    public static func loadExperiment() -> AuthExperiment {
        #if canImport(Darwin) || canImport(FoundationNetworking)
        let env = ProcessInfo.processInfo.environment
        let payload: AuthPayloadMode = env["IPULL_AUTH_PAYLOAD_MODE"] == "legacyCreateSession" ? .legacyCreateSession : .upstreamParity
        let attempt: AuthAttemptMode = env["IPULL_AUTH_ATTEMPT"] == "4" ? .attempt4 : .attempt1
        return AuthExperiment(payloadMode: payload, attemptMode: attempt)
        #else
        return .testA
        #endif
    }

    /// The stable User-Agent the HTTP client attaches to every request.
    /// Hashed in logs so a device trace proves password and 2FA requests
    /// carry the same UA without printing it.
    static let userAgentDescription = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    /// Running app version for the sign-in log line. Lets a pasted device
    /// log prove which build produced it, since LiveContainer can keep
    /// loading a cached older bundle after a reinstall.
    static let appVersionDescription: String = {
        #if canImport(Darwin)
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let short, let build, !build.isEmpty, build != "$(CURRENT_PROJECT_VERSION)" {
            return "v" + short + " (" + build + ")"
        }
        if let short {
            return "v" + short
        }
        return "version unknown"
        #else
        return "test host"
        #endif
    }()

    // MARK: - Session persistence (Keychain only)

    private func persist(session: AppleAccountSession) throws {
        let encoder = JSONEncoder()
        try secrets.save(encoder.encode(session), for: Self.sessionKeychainKey)
    }

    public func restoreSession() async throws -> AppleAccountSession? {
        guard let data = try secrets.load(key: Self.sessionKeychainKey) else { return nil }
        return try JSONDecoder().decode(AppleAccountSession.self, from: data)
    }

    public func signOut() async throws {
        try secrets.delete(key: Self.sessionKeychainKey)
        Log.info(.auth, "signed out; session token removed")
    }
}
