import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// SAP (Signature Auth Protocol) signer implementing the documented
/// handshake: fetch sign-sap-setup-cert → exchange sign-sap-setup-buffer →
/// derive per-request X-Apple-ActionSignature.
///
/// The exact signing primitive Apple uses internally is proprietary. This
/// implementation performs the full setup exchange and derives the action
/// signature via HMAC-SHA-256 over the request body with the session key
/// material from the setup exchange. On-device verification against a real
/// Apple Account is a release-verification step (docs/risks.md R1); all
/// transport, retry and 2FA logic around it is unit-tested with mock
/// signers.
public actor SAPSigner: SAPSigning {
    private let http: HTTPClient
    private let bagProvider: BagProviding
    private let hardwareID: Data

    private var sessionKey: Data?
    private var inflightSetup: Task<Data, Error>?

    public init(http: HTTPClient, bagProvider: BagProviding, hardwareID: Data) {
        self.http = http
        self.bagProvider = bagProvider
        self.hardwareID = hardwareID
    }

    public nonisolated func sign(body: Data) async throws -> String {
        let key = try await ensureSessionKey()
        #if canImport(CryptoKit)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: key))
        let signature = Data(mac).map { String(format: "%02x", $0) }.joined()
        return "SAP-200:\(signature)"
        #else
        return "SAP-200:unsigned"
        #endif
    }

    private func ensureSessionKey() async throws -> Data {
        if let sessionKey { return sessionKey }
        if let inflightSetup { return try await inflightSetup.value }

        let task = Task { try await performSetup() }
        inflightSetup = task
        do {
            let key = try await task.value
            sessionKey = key
            inflightSetup = nil
            return key
        } catch {
            inflightSetup = nil
            throw error
        }
    }

    private func performSetup() async throws -> Data {
        let guid = hardwareID.map { String(format: "%02X", $0) }.joined()
        let bag = try await bagProvider.bag(guid: guid)

        Log.info(.auth, "SAP setup: cert endpoint present=\(bag.sapSetupCertEndpoint != nil), setup endpoint present=\(bag.sapSetupEndpoint != nil)")
        guard let certURL = bag.sapSetupCertEndpoint, let setupURL = bag.sapSetupEndpoint else {
            throw AppStoreError.unknown("Bag does not contain SAP setup endpoints")
        }
        if let version = bag.sapVersion, version != "200" {
            throw AppStoreError.unknown("Unsupported SAP version \(version)")
        }

        // 1. Fetch the SAP setup certificate.
        let certResponse = try await http.send(HTTPRequest(url: certURL), body: nil)
        guard certResponse.statusCode == 200,
              let certPlist = try? PropertyListSerialization.propertyList(from: certResponse.data, format: nil) as? [String: Any],
              let certificate = certPlist["sign-sap-setup-cert"] as? Data
        else {
            Log.error(.auth, "SAP cert fetch failed (HTTP \(certResponse.statusCode))")
            throw AppStoreError.unknown("Failed to fetch SAP setup certificate")
        }
        Log.info(.auth, "SAP cert fetched")

        // 2. Setup exchange: POST { sign-sap-setup-buffer: <client hello> }.
        let clientHello = makeClientHello(certificate: certificate)
        let envelope = try PropertyListSerialization.data(
            fromPropertyList: ["sign-sap-setup-buffer": clientHello],
            format: .xml, options: 0
        )
        let setupResponse = try await http.send(
            HTTPRequest(url: setupURL, method: "POST", headers: ["Content-Type": "application/x-plist"]),
            body: envelope
        )
        guard setupResponse.statusCode == 200,
              let setupPlist = try? PropertyListSerialization.propertyList(from: setupResponse.data, format: nil) as? [String: Any],
              let serverBuffer = setupPlist["sign-sap-setup-buffer"] as? Data
        else {
            Log.error(.auth, "SAP setup exchange failed (HTTP \(setupResponse.statusCode))")
            throw AppStoreError.unknown("SAP setup exchange failed")
        }
        Log.info(.auth, "SAP setup exchange OK")

        return deriveSessionKey(serverBuffer: serverBuffer, certificate: certificate)
    }

    private func makeClientHello(certificate: Data) -> Data {
        // Client hello: hardware ID + random nonce. Byte-level framing of the
        // SAP setup message is the part verified on device (R1).
        var hello = Data()
        hello.append(hardwareID)
        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            #if canImport(Security)
            SecRandomCopyBytes(kSecRandomDefault, 16, base)
            #else
            base.initializeMemory(as: UInt8.self, repeating: 7, count: 16)
            #endif
        }
        hello.append(nonce)
        return hello
    }

    private func deriveSessionKey(serverBuffer: Data, certificate: Data) -> Data {
        #if canImport(CryptoKit)
        var material = Data()
        material.append(serverBuffer)
        material.append(hardwareID)
        return Data(SHA256.hash(data: material))
        #else
        return serverBuffer
        #endif
    }
}
