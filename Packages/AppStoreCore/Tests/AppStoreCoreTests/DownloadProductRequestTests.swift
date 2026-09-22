import XCTest
@testable import AppStoreCore

final class DownloadProductRequestTests: XCTestCase {

    private func plist(_ dict: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private let session = AppleAccountSession(
        email: "u@e.com", displayName: "U", directoryServicesID: "1",
        storefront: "143441-1,29", pod: nil, passwordToken: "tok"
    )

    func testVersionListParsing() throws {
        let item = try XCTUnwrap(DownloadProductRequest.interpret(plist: [
            "items": [[
                "metadata": [
                    "softwareVersionExternalIdentifiers": [8_000_000_001, 8_000_000_002, 8_000_000_003],
                    "softwareVersionExternalIdentifier": 8_000_000_003,
                ],
                "URL": "https://cdn.apple.com/example.ipa",
            ]],
        ]))
        let ids = (item.metadata["softwareVersionExternalIdentifiers"] as! [Int]).map(String.init)
        XCTAssertEqual(ids, ["8000000001", "8000000002", "8000000003"])
        XCTAssertEqual(item.downloadURL?.absoluteString, "https://cdn.apple.com/example.ipa")
    }

    func testLicenseNotFoundMapsToAppNotOwned() {
        XCTAssertThrowsError(try DownloadProductRequest.interpret(plist: ["failureType": "9610"])) { error in
            XCTAssertEqual(error as? AppStoreError, .appNotOwned)
        }
    }

    func testPasswordTokenExpiredMapsToSessionExpired() {
        for failureType in ["2034", "2042", "1008", "5002"] {
            XCTAssertThrowsError(try DownloadProductRequest.interpret(plist: ["failureType": failureType])) { error in
                XCTAssertEqual(error as? AppStoreError, .sessionExpired, "failureType \(failureType)")
            }
        }
    }

    func testEmptyItemsReturnsNilForFallback() throws {
        let item = try DownloadProductRequest.interpret(plist: [:])
        XCTAssertNil(item)
    }
}
