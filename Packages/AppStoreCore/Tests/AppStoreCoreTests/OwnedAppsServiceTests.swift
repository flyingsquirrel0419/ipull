import XCTest
@testable import AppStoreCore

/// Pinned to ipatool's appstore_owned_apps.go DAAP flow.
final class OwnedAppsServiceTests: XCTestCase {

    final class DAAPServer: HTTPClient, @unchecked Sendable {
        var requests: [(HTTPRequest, Data?)] = []
        func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
            requests.append((request, body))
            let path = request.url.path
            let data: Data
            if path.hasSuffix("/login") {
                data = DMAP.tag("mlog", DMAP.uint32("mstt", 200) + DMAP.uint32("mlid", 77))
            } else if path.hasSuffix("/update") {
                data = DMAP.tag("mupd", DMAP.uint32("mstt", 200) + DMAP.uint32("musr", 5))
            } else {
                let item1 = DMAP.tag("mlit", itemTags(id: 111, bundle: "com.a.one", name: "One", date: 1_700_000_000))
                let item2 = DMAP.tag("mlit", itemTags(id: 222, bundle: "com.a.two", name: "Two", date: 1_800_000_000))
                data = DMAP.tag("adbs", DMAP.uint32("mstt", 200) + DMAP.tag("mlcl", item1 + item2))
            }
            return HTTPResponse(statusCode: 200, headers: [:], data: data)
        }

        private func itemTags(id: UInt32, bundle: String, name: String, date: UInt32) -> Data {
            DMAP.uint32("aeSI", id) + DMAP.string("aeBI", bundle) + DMAP.string("aeLN", name)
                + DMAP.uint32("asdp", date)
        }
    }

    final class CountingSigner: SAPSigning, SAPSessionClosing, @unchecked Sendable {
        var signed: [Data] = []
        var closed = false
        func sign(body: Data) async throws -> String { signed.append(body); return "c2ln" }
        func closeSession() async { closed = true }
    }

    private let session = AppleAccountSession(email: "u@e.com", displayName: "U", directoryServicesID: "9",
                                              storefront: "143466-1,29", pod: nil, passwordToken: "tok")

    func testThreeStepFlowPerStorefrontAndParsing() async throws {
        let server = DAAPServer()
        let signer = CountingSigner()
        let service = OwnedAppsService(http: server, signerFactory: { _ in signer }, guidProvider: { "AABBCCDDEEFF" })

        let page = try await service.ownedApps(session: session, page: 1, limit: 0)

        XCTAssertEqual(server.requests.map { $0.0.url.path.components(separatedBy: "/purchase").last! },
                       ["/login", "/update", "/databases/5/items", "/login", "/update", "/databases/5/items"])
        XCTAssertEqual(server.requests.map { $0.0.headers["X-Apple-Store-Front"]! },
                       ["143466-1,34", "143466-1,34", "143466-1,34", "143466-1,13", "143466-1,13", "143466-1,13"])
        // Login is unsigned; update and items are signed over their bodies.
        XCTAssertNil(server.requests[0].0.headers["X-Apple-ActionSignature"])
        XCTAssertNotNil(server.requests[1].0.headers["X-Apple-ActionSignature"])
        XCTAssertEqual(signer.signed.count, 4)
        XCTAssertTrue(String(decoding: server.requests[1].1!, as: UTF8.self)
            .hasPrefix("session-id=77&revision-number=(null)&query=('com.apple.itunes.extended\\-media\\-kind:131072'"))
        XCTAssertEqual(server.requests[2].0.headers["Content-Type"], "application/x-dmap-tagged")
        XCTAssertEqual(server.requests[0].0.headers["X-Guid"], "AABBCCDDEEFF")
        XCTAssertTrue(signer.closed)

        // Merged across storefronts and sorted newest purchase first.
        XCTAssertEqual(page.apps.map(\.id), [222, 111])
        XCTAssertEqual(page.apps.first?.bundleID, "com.a.two")
        XCTAssertEqual(page.totalCount, 2)
    }

    func testItemsBodyLayoutMatchesIPatool() throws {
        let body = OwnedAppsService.itemsBody(sessionID: 7, revision: 3, query: "q", now: Date(timeIntervalSince1970: 1))
        var tags: [String] = []
        try DMAP.walk(body) { name, _ in tags.append(name) }
        XCTAssertEqual(tags, ["adsr", "mstc", "mlid", "mikd", "musr", "mder", "mque", "aetl"])
        XCTAssertEqual(try DMAP.firstUInt(body, "mlid"), 7)
    }

    func testUnauthorizedDAAPStatusMeansSessionExpired() async {
        final class Rejecting: HTTPClient, @unchecked Sendable {
            func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
                HTTPResponse(statusCode: 200, headers: [:], data: DMAP.tag("mlog", DMAP.uint32("mstt", 401)))
            }
        }
        let signer = CountingSigner()
        let service = OwnedAppsService(http: Rejecting(), signerFactory: { _ in signer }, guidProvider: { "AABBCCDDEEFF" })
        do {
            _ = try await service.ownedApps(session: session, page: 1, limit: 0)
            XCTFail("Expected sessionExpired")
        } catch {
            XCTAssertEqual(error as? AppStoreError, .sessionExpired)
        }
        XCTAssertTrue(signer.closed)
    }
}
