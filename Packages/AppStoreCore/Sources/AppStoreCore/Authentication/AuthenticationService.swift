import Foundation

/// SAP (Signature Auth Protocol) request signer. The handshake and signing
/// primitive are isolated here so transport and UI remain testable without
/// it. See docs/risks.md R1.
public protocol SAPSigning: Sendable {
    /// Produce the X-Apple-ActionSignature header value (base64) for a body.
    func sign(body: Data) async throws -> String
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

/// Clean-room Swift implementation of the documented App Store auth flow:
///
///   bag → POST authenticateAccount (XML plist body, SAP-signed, desktop
///         attempt values: "4" + createSession "true" for password-only,
///         ipatool's shape "1" with no createSession for the 2FA submit)
///       → on MZFinance.BadLogin → require 2FA code, retry with code appended
///       → on 302 → follow pod redirect
///       → on 429 → bounded exponential backoff honoring Retry-After,
///         then rethrow .rateLimited
///       → persistent empty 404 → rotate the device GUID once (Apple flags
///         the identity server-side), retry with a fresh signer, then
///         rethrow .networkUnavailable
///       → success: dsPersonId + passwordToken + X-Set-Apple-Store-Front
///
/// Passwords are never persisted; only the resulting session token goes to
/// the Keychain (device-bound accessibility).
public final class AuthenticationService: AuthenticationServicing, @unchecked Sendable {
    public static let sessionKeychainKey = "apple-account-session"

    /// Bounds for 429 / empty-404 handling: ipatool's schedule (10s, 20s,
    /// 30s) honoring a server Retry-After hint, capped at 30s. The old 1/2/4s
    /// backoff hammered edge nodes inside Apple's 404 window and made a
    /// flagged identity look persistent.
    static let maxRateLimitRetries = 3
    static let retryBackoffSeconds: [UInt64] = [10, 20, 30]
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

    public init(
        http: HTTPClient,
        bagProvider: BagProviding,
        signerFactory: @escaping @Sendable (Data) async throws -> any SAPSigning,
        secrets: SecretStore,
        identityProvider: (@Sendable (SecretStore) throws -> String)? = nil,
        sleep: (@Sendable (UInt64) async -> Void)? = nil,
        progress: (@Sendable (AuthenticationProgress) -> Void)? = nil
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
        progress: (@Sendable (AuthenticationProgress) -> Void)? = nil
    ) {
        self.init(
            http: http,
            bagProvider: bagProvider,
            signerFactory: { _ in signer },
            secrets: secrets,
            identityProvider: { _ in try guidProvider() },
            sleep: sleep,
            progress: progress
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

        var guid = try identityProvider(secrets)
        // Reference-flow diagnostic: a 2FA submit is a fresh Login
        // invocation upstream, which builds a NEW SAP signer on the same
        // persistent machine identity (GUID/machineID unchanged, cookies
        // preserved). Reusing the password-stage signer makes the edge
        // answer the 2FA submit with an empty 404 on-device; whether a
        // fresh signer changes that is exactly what this build measures.
        if normalizedCode != nil {
            progress?(.initializingSigner)
            signerGeneration += 1
            Log.info(.auth, "preparing fresh SAP signer for 2FA (signerGeneration=\(signerGeneration), same guid/machineID)")
            signer = try await signerFactory(Data(guid.utf8))
        } else if signer == nil {
            progress?(.initializingSigner)
            signer = try await signerFactory(Data(guid.utf8))
        }
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

        // Endpoint selection rule: the bag's auth endpoint is the default.
        // Only an actual HTTP 302 Location from Apple may replace it —
        // a Pod/itspod response header is routing metadata, never a host.
        // A fresh password flow resets flow-local routing metadata so a
        // stale pod ID from an earlier challenge cannot confuse diagnostics.
        if normalizedCode == nil {
            assignedPodID = nil
            authenticationRedirectURL = nil
        }
        var endpoint = authenticationRedirectURL ?? bag.authEndpoint
        let stage = normalizedCode == nil ? "password" : "2fa"
        Log.info(.auth, "AUTH FLOW ID=\(Self.shortHash(of: guid)) stage=\(stage) identityGeneration=\(identityGeneration)")
        // ipatool's loginRequest shapes: the desktop Configurator sends
        // attempt "4" with createSession "true" for password-only sign-in,
        // and the two-factor verification is a fresh loginRequest with
        // attempt "1" and no createSession field. Sending attempt "2" plus
        // createSession on a 2FA submit is answered with an empty 404 by
        // Apple's edge on-device.
        let attempt = normalizedCode == nil ? 4 : 1
        let includeCreateSession = normalizedCode == nil
        var rateLimitRetries = 0
        var didRotateGUID = false

        // Logical authentication attempts (fresh body + fresh SAP signature
        // each round) vs transport retries (same body, transient statuses).
        // Password stage: 1 logical attempt + one identity rotation. 2FA:
        // up to 4 logical attempts on the same identity, per the on-device
        // experiment to learn whether a fresh signature escapes the edge
        // 404 window.
        let maxLogicalAttempts = normalizedCode == nil ? 2 : 4
        var logicalAttempt = 0
        outer: while logicalAttempt < maxLogicalAttempts {
            logicalAttempt += 1
            var transportAttempt = 0
            for _ in 0..<(1 + Self.maxRateLimitRetries + 1) {
                transportAttempt += 1
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
                ]
            )
            // Invariant: a malformed endpoint (e.g. a pod ID leaking into
            // the host field) must never reach the network layer. Only
            // Apple authentication hosts are allowed.
            try BagService.validate(authEndpoint: endpoint)
            requestSequence += 1
            let requestID = (normalizedCode == nil ? "AUTH-PW-" : "AUTH-2FA-") + String(format: "%04d", requestSequence)
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
            } catch {
                Log.error(.auth, "authenticate request failed: \(String(describing: type(of: error)))")
                throw error
            }

            // Transient statuses (204/404/429/5xx) are never a credential
            // verdict — Apple answers them while an identity or challenge
            // state propagates across edge nodes. ipatool retries exactly
            // this set with 10/20/30s backoff and keeps the same GUID.
            // A non-empty body on a 404/5xx still carries a plist verdict,
            // which is parsed below; only bodyless transient responses and
            // 204/429 retry here.
            let isTransient = response.statusCode == 204
                || response.statusCode == 429
                || (response.statusCode == 404 && response.data.isEmpty)
                || (response.statusCode >= 500 && response.statusCode < 600 && response.data.isEmpty)
            if isTransient {
                let stage = normalizedCode == nil ? "password" : "2fa"
                if rateLimitRetries < Self.maxRateLimitRetries {
                    let retryAfter = response.header("Retry-After").flatMap { Int($0) }
                    let backoff = Self.retryBackoffSeconds[min(rateLimitRetries, Self.retryBackoffSeconds.count - 1)]
                    let delay = min(
                        max(UInt64(max(retryAfter ?? 0, 0)), backoff),
                        Self.rateLimitMaxDelaySeconds
                    )
                    rateLimitRetries += 1
                    Log.info(.auth, "authenticate transient HTTP \(response.statusCode) (stage=\(stage)); retry \(rateLimitRetries) after \(delay)s")
                    progress?(.retryingAfterRateLimit(seconds: delay))
                    await sleep(delay * 1_000_000_000)
                    continue
                }
                Log.error(.auth, "authenticate still HTTP \(response.statusCode) after \(rateLimitRetries) retries (stage=\(stage))")
                if normalizedCode != nil {
                    // The 2FA challenge is bound to this GUID and SAP
                    // session; rotating here would break verification
                    // (failureType 5020). A persistent transient on a 2FA
                    // submit most likely means the code expired during the
                    // retry window, so ask for a fresh one.
                    logFailureDiagnostic(
                        stage: "2fa", lastStatus: response.statusCode, host: endpoint.host ?? "?",
                        guid: guid, retries: rateLimitRetries, rotations: 0,
                        cause: "transient edge 404/204/5xx persisted through the retry budget on a 2FA submit; challenge discarded, next attempt starts a fresh password flow")
                    invalidateTwoFactorChallenge()
                    throw AppStoreError.invalidTwoFactorCode
                }
                if response.statusCode == 429 {
                    throw AppStoreError.rateLimited(retryAfterSeconds: response.header("Retry-After").flatMap { Int($0) })
                }
                // Persistent empty 404/204/5xx on the password step: Apple
                // has flagged this device identity server-side. Rotate the
                // GUID once per sign-in — a fresh GUID in both the SAP
                // signer (hardware ID) and the request body is the only
                // app-side recovery lever. Rotation is not re-armed, so a
                // flagged account terminates after the rotated sequence.
                if !didRotateGUID {
                    didRotateGUID = true
                    identityGeneration += 1
                    Log.info(.auth, "guid rotated; retrying with fresh identity (identityGeneration=\(identityGeneration))")
                    let freshGUID = try DeviceIdentity.rotateGUID(secretStore: secrets)
                    guid = freshGUID
                    signer = try await signerFactory(Data(freshGUID.utf8))
                    rateLimitRetries = 0
                    continue
                }
                throw AppStoreError.networkUnavailable
            }

            if response.statusCode == 302,
               let location = response.header("Location"),
               let redirectURL = URL(string: location) {
                try BagService.validate(authEndpoint: redirectURL)
                Log.info(.auth,
                    "[auth][redirect] status=302 fromHost=\(endpoint.host ?? "?") toHost=\(redirectURL.host ?? "?") pod=\(response.header("pod") ?? "nil")")
                // Store the exact Location Apple sent; never reconstruct a
                // pod URL from the numeric pod identifier.
                authenticationRedirectURL = redirectURL
                endpoint = redirectURL
                continue
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
                    guid: guid, retries: rateLimitRetries, rotations: didRotateGUID ? 1 : 0,
                    cause: "challenge answered BadLogin on 2FA submit; discarded, fresh challenge required")
                invalidateTwoFactorChallenge()
                throw AppStoreError.invalidTwoFactorCode
            }

            if customerMessage == "Your account is disabled." {
                throw AppStoreError.accountDisabled
            }

            if failureType == "-5000" {
                throw AppStoreError.authenticationFailed
            }

            // failureType 5020 with "Did you forget your password?" is
            // Apple's response when it cannot verify password+code as a
            // unit — a wrong or expired 2FA code, not a bad password.
            if failureType == "5020", normalizedCode != nil {
                logFailureDiagnostic(
                    stage: "2fa", lastStatus: response.statusCode, host: endpoint.host ?? "?",
                    guid: guid, retries: rateLimitRetries, rotations: didRotateGUID ? 1 : 0,
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
            // A bodyless 204/404/5xx with no backend evidence never reached
            // the MZFinance application.
            if response.statusCode == 204 || response.statusCode == 404
                || (response.statusCode >= 500 && response.statusCode < 600) {
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
            parts.append("requestUUIDPresent=\(response.header("x-apple-request-uuid") != nil)")
            parts.append("jingleKeyPresent=\(response.header("x-apple-jingle-correlation-key") != nil)")
            parts.append("respondingInstancePresent=\(response.header("x-responding-instance") != nil)")
            parts.append("xDaiquiriInstancePresent=\(response.header("x-daiquiri-instance") != nil)")
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

    /// XML plist body matching the desktop client (ipatool's XMLPayload),
    /// serialized with Swift's PropertyListSerialization — the same encoder
    /// Apple's own Configurator uses. Content-Type stays form-urlencoded.
    ///
    /// Two shapes, matching ipatool's loginRequest exactly:
    ///   - password-only sign-in: attempt "4" with createSession "true"
    ///     (the desktop Configurator values that Apple answers reliably);
    ///   - two-factor verification: attempt "1" and no createSession field
    ///     at all. ipatool's 2FA submit is exactly this six-field body, and
    ///     Apple answers attempt=2 + createSession=true 2FA retries with an
    ///     empty 404 on-device.
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
