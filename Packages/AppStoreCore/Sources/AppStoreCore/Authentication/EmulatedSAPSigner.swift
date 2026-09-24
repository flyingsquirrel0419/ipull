import Foundation

/// Real SAP signer backed by the emulated Apple signing binary.
/// Replaces the approximated SAPSigner once assets are available.
///
/// Flow (matching the documented protocol):
///   1. fetch sign-sap-setup-cert from the bag
///   2. initialize(context) with the device hardware ID
///   3. exchange(version, hardware, context, certificate) → request bytes
///   4. POST sign-sap-setup with the request → server reply
///   5. exchange(..., reply) → session established
///   6. sign(body) per request → X-Apple-ActionSignature
public actor EmulatedSAPSigner: SAPSigning {

    public enum State: Sendable, Equatable {
        case idle
        case establishing
        case ready
        case failed
    }

    /// Current state for UI observation.
    public var currentState: State { state }

    private let http: HTTPClient
    private let bagProvider: BagProviding
    private let assetProvider: SAPAssetProviding
    private let hardwareID: Data
    private let progress: (@Sendable (AuthenticationProgress) -> Void)?

    private var runtime: SAPRuntime?
    private var context: UInt64 = 0
    private var state: State = .idle
    private var inflight: Task<Void, Error>?

    public init(http: HTTPClient, bagProvider: BagProviding,
                assetProvider: SAPAssetProviding, hardwareID: Data,
                progress: (@Sendable (AuthenticationProgress) -> Void)? = nil) {
        self.http = http
        self.bagProvider = bagProvider
        self.assetProvider = assetProvider
        self.hardwareID = hardwareID
        self.progress = progress
    }

    public func sign(body: Data) async throws -> String {
        try await ensureEstablished()
        guard let runtime else { throw AppStoreError.unknown("SAP runtime not ready") }
        let signature = try runtime.sign(context: context, input: body)
        // The header value is base64-encoded (per ipatool's http client).
        return signature.base64EncodedString()
    }

    private func ensureEstablished() async throws {
        switch state {
        case .ready:
            return
        case .establishing:
            // Coalesce: wait for the in-flight establish instead of erroring.
            if let inflight {
                try await inflight.value
                return
            }
        case .failed:
            Log.info(.auth, "retrying SAP session after previous failure")
        case .idle:
            break
        }

        state = .establishing
        let task = Task { try await self.establish() }
        inflight = task
        do {
            try await task.value
            state = .ready
            inflight = nil
        } catch {
            state = .failed
            inflight = nil
            throw error
        }
    }

    private func establish() async throws {
        let guid = hardwareID.map { String(format: "%02X", $0) }.joined()
        let bag = try await bagProvider.bag(guid: guid)

        guard let certURL = bag.sapSetupCertEndpoint, let setupURL = bag.sapSetupEndpoint else {
            throw AppStoreError.unknown("Bag does not contain SAP setup endpoints")
        }
        let version = UInt32(bag.sapVersion ?? "200") ?? 200

        // 1. Certificate
        progress?(.fetchingCertificate)
        let certResponse = try await http.send(HTTPRequest(url: certURL), body: nil)
        guard certResponse.statusCode == 200,
              let certPlist = try? PropertyListSerialization.propertyList(from: certResponse.data, format: nil) as? [String: Any],
              let certificate = certPlist["sign-sap-setup-cert"] as? Data
        else {
            throw AppStoreError.unknown("Failed to fetch SAP setup certificate")
        }
        Log.info(.auth, "SAP cert fetched")

        // 2. Assets + runtime
        let assets = try await assetProvider.load()
        progress?(.initializingSigner)
        let runtime = try SAPRuntime(assets: assets, hardwareID: hardwareID)
        Log.info(.auth, "SAP runtime ready; initializing session")
        let context = try runtime.initialize(hardwareID: hardwareID)
        Log.info(.auth, "SAP session initialized")

        // 3. First exchange with the certificate
        progress?(.establishingSession)
        let (request, _) = try runtime.exchange(
            version: version, hardwareID: hardwareID, context: context, input: certificate
        )

        // 4. POST the exchange request to the setup endpoint
        let envelope = try PropertyListSerialization.data(
            fromPropertyList: ["sign-sap-setup-buffer": request],
            format: .xml, options: 0
        )
        let setupResponse = try await http.send(
            HTTPRequest(url: setupURL, method: "POST",
                        headers: ["Content-Type": "application/x-plist"]),
            body: envelope
        )
        guard setupResponse.statusCode == 200,
              let setupPlist = try? PropertyListSerialization.propertyList(from: setupResponse.data, format: nil) as? [String: Any],
              let reply = setupPlist["sign-sap-setup-buffer"] as? Data
        else {
            Log.error(.auth, "SAP setup exchange failed (HTTP \(setupResponse.statusCode))")
            throw AppStoreError.unknown("SAP setup exchange failed")
        }
        Log.info(.auth, "SAP setup exchange OK")

        // 5. Complete the session
        _ = try runtime.exchange(
            version: version, hardwareID: hardwareID, context: context, input: reply
        )

        self.runtime = runtime
        self.context = context
    }
}
