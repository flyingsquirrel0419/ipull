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
///   bag → POST authenticateAccount (plist form body, SAP-signed)
///       → on MZFinance.BadLogin → require 2FA code, retry with code appended
///       → on 302 → follow pod redirect with attempt reset to 1
///       → on 429 → bounded exponential backoff honoring Retry-After,
///         then rethrow .rateLimited
///       → success: dsPersonId + passwordToken + X-Set-Apple-Store-Front
///
/// Passwords are never persisted; only the resulting session token goes to
/// the Keychain (device-bound accessibility).
public final class AuthenticationService: AuthenticationServicing, @unchecked Sendable {
    public static let sessionKeychainKey = "apple-account-session"

    /// Bounds for 429 handling: bounded exponential backoff (1s, 2s, 4s)
    /// honoring a server Retry-After hint, capped at 30s.
    static let maxRateLimitRetries = 3
    static let rateLimitMaxDelaySeconds: UInt64 = 30

    private let http: HTTPClient
    private let bagProvider: BagProviding
    private let signer: SAPSigning
    private let secrets: SecretStore
    private let guidProvider: @Sendable () throws -> String
    private let sleep: @Sendable (UInt64) async -> Void
    private let progress: (@Sendable (AuthenticationProgress) -> Void)?

    public init(
        http: HTTPClient,
        bagProvider: BagProviding,
        signer: SAPSigning,
        secrets: SecretStore,
        guidProvider: @escaping @Sendable () throws -> String,
        sleep: (@Sendable (UInt64) async -> Void)? = nil,
        progress: (@Sendable (AuthenticationProgress) -> Void)? = nil
    ) {
        self.http = http
        self.bagProvider = bagProvider
        self.signer = signer
        self.secrets = secrets
        self.guidProvider = guidProvider
        self.sleep = sleep ?? { ns in
            try? await Task.sleep(nanoseconds: ns)
        }
        self.progress = progress
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

        let guid = try guidProvider()
        progress?(.fetchingConfiguration)
        Log.info(.auth, "sign-in start (guid resolved)")
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

        var endpoint = bag.authEndpoint
        var attempt = 1
        var redirectHop = false
        var rateLimitRetries = 0

        // Allow the normal retry and redirect in addition to rate-limit retries.
        for _ in 0..<(4 + Self.maxRateLimitRetries) {
            let requestAttempt = redirectHop ? 1 : attempt
            let passwordField = password + (normalizedCode ?? "")
            let body = try Self.authRequestBody(
                appleID: trimmedEmail,
                password: passwordField,
                guid: guid,
                attempt: requestAttempt
            )
            let signature: String
            do {
                progress?(.signingRequest)
                signature = try await signer.sign(body: body)
                Log.info(.auth, "SAP signature produced (attempt \(requestAttempt))")
            } catch {
                // Log only the error type: emulator errors may embed the
                // signed body, which contains the password in percent-encoded
                // form that pattern-based redaction cannot recognize.
                Log.error(.auth, "SAP signing failed: \(String(describing: type(of: error)))")
                throw error
            }

            let request = HTTPRequest(
                url: endpoint,
                method: "POST",
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "X-Apple-ActionSignature": signature,
                ]
            )
            let response: HTTPResponse
            do {
                progress?(.authenticating)
                response = try await http.send(request, body: body)
                let serverHint = [response.header("server"), response.header("x-apple-request-uuid"),
                                  response.header("x-daiquiri-instance")].compactMap { $0 }.joined(separator: " ")
                Log.info(.auth, "authenticate response HTTP \(response.statusCode)\(serverHint.isEmpty ? "" : " [\(serverHint)]")")
            } catch {
                Log.error(.auth, "authenticate request failed: \(String(describing: type(of: error)))")
                throw error
            }

            if response.statusCode == 429 {
                let retryAfter = response.header("Retry-After").flatMap { Int($0) }
                if rateLimitRetries < Self.maxRateLimitRetries {
                    let backoff = UInt64(1) << rateLimitRetries
                    let delay = min(
                        max(UInt64(max(retryAfter ?? 0, 0)), backoff),
                        Self.rateLimitMaxDelaySeconds
                    )
                    rateLimitRetries += 1
                    Log.info(.auth, "authenticate rate limited; retry \(rateLimitRetries) after \(delay)s")
                    progress?(.retryingAfterRateLimit(seconds: delay))
                    await sleep(delay * 1_000_000_000)
                    continue
                }
                Log.error(.auth, "authenticate still rate limited after \(rateLimitRetries) retries")
                throw AppStoreError.rateLimited(retryAfterSeconds: retryAfter)
            }

            // Apple intermittently answers authenticate with an empty 404
            // (transient; observed on-device right after the 2FA prompt).
            // Retry it like a rate limit, with backoff.
            if response.statusCode == 404 && response.data.isEmpty {
                if rateLimitRetries < Self.maxRateLimitRetries {
                    rateLimitRetries += 1
                    let delay = min(UInt64(1) << (rateLimitRetries - 1), Self.rateLimitMaxDelaySeconds)
                    Log.info(.auth, "authenticate empty 404; retry \(rateLimitRetries) after \(delay)s")
                    progress?(.retryingAfterRateLimit(seconds: delay))
                    await sleep(delay * 1_000_000_000)
                    continue
                }
                Log.error(.auth, "authenticate still 404 after \(rateLimitRetries) retries")
                throw AppStoreError.networkUnavailable
            }

            if response.statusCode == 302,
               let location = response.header("Location"),
               let redirectURL = URL(string: location) {
                try BagService.validate(authEndpoint: redirectURL)
                endpoint = redirectURL
                redirectHop = true
                continue
            }

            guard let plist = try? PropertyListSerialization.propertyList(from: response.data, format: nil) as? [String: Any] else {
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

            if attempt == 1 && failureType == "-5000" && normalizedCode == nil {
                attempt += 1
                continue
            }

            if failureType == nil && customerMessage == "MZFinance.BadLogin.Configurator_message" {
                if normalizedCode == nil {
                    Log.info(.auth, "account requires two-factor code")
                    return .twoFactorRequired
                }
                throw AppStoreError.invalidTwoFactorCode
            }

            if customerMessage == "Your account is disabled." {
                throw AppStoreError.accountDisabled
            }

            if failureType == "-5000" {
                throw AppStoreError.authenticationFailed
            }

            if failureType == "2034" || failureType == "2042" {
                // The stored token can no longer authenticate; remove it so
                // restoreSession() fails cleanly instead of resurrecting a
                // dead session.
                try? secrets.delete(key: Self.sessionKeychainKey)
                throw AppStoreError.sessionExpired
            }

            throw AppStoreError.unknown(customerMessage ?? failureType ?? "Authentication failed")
        }

        throw AppStoreError.authenticationFailed
    }

    static func normalizeTwoFactorCode(_ raw: String) -> String? {
        let digits = raw.filter { $0 >= "0" && $0 <= "9" }
        return digits.count == 6 ? digits : nil
    }

    /// XML plist body matching the desktop client (ipatool's XMLPayload),
    /// serialized with Swift's PropertyListSerialization — the same encoder
    /// Apple's own Configurator uses. Content-Type stays form-urlencoded.
    static func authRequestBody(appleID: String, password: String, guid: String, attempt: Int) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "appleId": appleID,
                "attempt": String(attempt),
                "guid": guid,
                "password": password,
                "rmp": "0",
                "why": "signIn",
            ],
            format: .xml,
            options: 0
        )
    }

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
