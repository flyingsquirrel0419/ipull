import Foundation

/// SAP (Signature Auth Protocol) request signer. The handshake and signing
/// primitive are isolated here so transport and UI remain testable without
/// it. See docs/risks.md R1.
public protocol SAPSigning: Sendable {
    /// Produce the X-Apple-ActionSignature header value for a request body.
    func sign(body: Data) async throws -> String
}

public enum AuthenticationResult: Sendable, Equatable {
    case success(AppleAccountSession)
    case twoFactorRequired
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
///       → success: dsPersonId + passwordToken + X-Set-Apple-Store-Front
///
/// Passwords are never persisted; only the resulting session token goes to
/// the Keychain (device-bound accessibility).
public final class AuthenticationService: AuthenticationServicing, @unchecked Sendable {
    public static let sessionKeychainKey = "apple-account-session"

    private let http: HTTPClient
    private let bagProvider: BagProviding
    private let signer: SAPSigning
    private let secrets: SecretStore
    private let guidProvider: @Sendable () throws -> String

    public init(
        http: HTTPClient,
        bagProvider: BagProviding,
        signer: SAPSigning,
        secrets: SecretStore,
        guidProvider: @escaping @Sendable () throws -> String
    ) {
        self.http = http
        self.bagProvider = bagProvider
        self.signer = signer
        self.secrets = secrets
        self.guidProvider = guidProvider
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
        Log.info(.auth, "sign-in start (guid resolved)")
        let bag: Bag
        do {
            bag = try await bagProvider.bag(guid: guid)
            Log.info(.auth, "bag fetched; auth endpoint host OK")
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

        // Up to 4 attempts: first invalid-credentials retry, pod redirect, 2FA retry.
        for _ in 0..<4 {
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
                signature = try await signer.sign(body: body)
                Log.info(.auth, "SAP signature produced (attempt \(requestAttempt))")
            } catch {
                Log.error(.auth, "SAP signing failed: \(String(describing: error))")
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
                response = try await http.send(request, body: body)
                Log.info(.auth, "authenticate response HTTP \(response.statusCode)")
            } catch {
                Log.error(.auth, "authenticate request failed: \(String(describing: type(of: error)))")
                throw error
            }

            if response.statusCode == 429 {
                let retryAfter = response.header("Retry-After").flatMap { Int($0) }
                throw AppStoreError.rateLimited(retryAfterSeconds: retryAfter)
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
            Log.info(.auth, "auth response keys: \(plist.keys.sorted().joined(separator: ","))")

            let failureType = plist["failureType"] as? String
            let customerMessage = plist["customerMessage"] as? String

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
                try persist(session: session)
                return .success(session)
            }

            if attempt == 1 && failureType == "-5000" && normalizedCode == nil {
                attempt += 1
                continue
            }

            if failureType == nil && customerMessage == "MZFinance.BadLogin.Configurator_message" {
                if normalizedCode == nil {
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
                throw AppStoreError.sessionExpired
            }

            throw AppStoreError.unknown(customerMessage ?? failureType ?? "Authentication failed")
        }

        throw AppStoreError.authenticationFailed
    }

    static func normalizeTwoFactorCode(_ raw: String) -> String? {
        let digits = raw.filter { $0.isNumber }
        return digits.count == 6 ? digits : nil
    }

    /// Form-urlencoded body matching the documented desktop-client flow
    /// (ipatool): appleId, password (+2FA appended), guid, attempt, rmp, why.
    static func authRequestBody(appleID: String, password: String, guid: String, attempt: Int) throws -> Data {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "appleId", value: appleID),
            URLQueryItem(name: "attempt", value: String(attempt)),
            URLQueryItem(name: "guid", value: guid),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "rmp", value: "0"),
            URLQueryItem(name: "why", value: "signIn"),
        ]
        return Data((components.percentEncodedQuery ?? "").utf8)
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
    }
}
