import XCTest
@testable import AppStoreCore

final class VersionServiceTests: XCTestCase {
    struct Bag: BagProviding {
        func bag(guid: String) async throws -> AppStoreCore.Bag {
            AppStoreCore.Bag(authEndpoint: URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate")!)
        }
    }

    final class OneShot: HTTPClient, @unchecked Sendable {
        let data: Data
        init(_ plist: [String: Any]) {
            data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        }
        func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: [:], data: data)
        }
    }

    func testVersionsAreNewestFirst() async throws {
        let http = OneShot(["songList": [["metadata": [
            "softwareVersionExternalIdentifiers": [800_000_001, 800_000_010, 800_000_100],
            "softwareVersionExternalIdentifier": 800_000_100,
        ]]]])
        let service = VersionService(http: http, bagProvider: Bag(), guidProvider: { "AABBCCDDEEFF" })
        let session = AppleAccountSession(email: "u@e.com", displayName: "U", directoryServicesID: "1",
                                          storefront: "143441-1,29", pod: nil, passwordToken: "t")
        let result = try await service.listVersions(app: AppStoreApp(id: 1, bundleID: "b", name: "n"), session: session)
        XCTAssertEqual(result.versions.map(\.externalVersionID), ["800000100", "800000010", "800000001"])
        XCTAssertTrue(result.versions[0].isLatest)
        XCTAssertEqual(result.latestExternalVersionID, "800000100")
    }
}
