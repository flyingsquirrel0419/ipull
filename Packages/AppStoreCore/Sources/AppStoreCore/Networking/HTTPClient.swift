import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A platform-independent HTTP request description. On Apple platforms it
/// converts to URLRequest; on Linux it drives URLSession via
/// FoundationNetworking. Keeping our own type makes the core testable on
/// any Swift toolchain.
public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]

    public init(url: URL, method: String = "GET", headers: [String: String] = [:]) {
        self.url = url
        self.method = method
        self.headers = headers
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String], data: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Minimal HTTP abstraction so protocol services are testable.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse
}

public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    public init() {}

    public func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
        #if canImport(FoundationNetworking) || canImport(Darwin)
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue(
            "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6",
            forHTTPHeaderField: "User-Agent")
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw AppStoreError.unknown("Non-HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
        } catch let error as URLError {
            // Surface the real URLError code in the (redacted) debug log so
            // on-device failures are diagnosable; user-facing text stays generic.
            Log.error(.network, "request failed: URLError \(error.code.rawValue) \(error.code)")
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw AppStoreError.networkUnavailable
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
                throw AppStoreError.unknown("TLS failure \(error.code.rawValue)")
            default:
                throw AppStoreError.unknown("HTTP failure \(error.code.rawValue)")
            }
        }
        #else
        throw AppStoreError.unknown("URLSession unavailable on this platform")
        #endif
    }
}
