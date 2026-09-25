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
            "songList": [[
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

    func testSongListCarriesSinfs() throws {
        let item = try XCTUnwrap(DownloadProductRequest.interpret(plist: [
            "songList": [["URL": "https://cdn.apple.com/a.ipa", "sinfs": [["id": 0, "sinf": Data([1, 2])]]]],
        ]))
        XCTAssertEqual(item.sinfs.count, 1)
    }

    func testNoLongerAvailableFallsBack() throws {
        XCTAssertNil(try DownloadProductRequest.interpret(plist: ["customerMessage": "This item is no longer available"]))
    }

    func testOtherCustomerMessageIsAnError() {
        XCTAssertThrowsError(try DownloadProductRequest.interpret(plist: ["customerMessage": "Something else"]))
    }

    func testDispatchURLUsesBagEndpointVerbatim() {
        let bag = URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload")
        XCTAssertEqual(DownloadProductRequest.dispatchURL(bag, path: "/r/redownload", guid: "AABBCCDDEEFF")?.absoluteString,
                       "https://downloaddispatch.itunes.apple.com/r/redownload?guid=AABBCCDDEEFF")
        XCTAssertNil(DownloadProductRequest.dispatchURL(URL(string: "https://example.com/r/redownload"),
                                                        path: "/r/redownload", guid: "AABBCCDDEEFF"))
    }
}
