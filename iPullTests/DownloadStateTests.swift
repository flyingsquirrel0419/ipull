import XCTest
@testable import iPull

final class DownloadStateTests: XCTestCase {
    func testProgressCalculation() {
        var record = DownloadRecord(appID: 1, appName: "App", bundleID: "a.b", version: "1.0",
                                    bytesDownloaded: 500, totalBytes: 1000)
        XCTAssertEqual(record.progress, 0.5, accuracy: 0.001)
        record.totalBytes = 0
        XCTAssertEqual(record.progress, 0)
    }

    func testRecordRoundTrip() throws {
        let record = DownloadRecord(appID: 389801252, appName: "Instagram", bundleID: "com.burbn.instagram",
                                    version: "446.0.0", state: .downloading)
        let data = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([DownloadRecord].self, from: data)
        XCTAssertEqual(decoded, [record])
    }
}
