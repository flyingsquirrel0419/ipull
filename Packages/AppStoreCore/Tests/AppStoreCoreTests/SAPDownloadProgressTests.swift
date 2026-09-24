import XCTest
@testable import AppStoreCore

final class SAPDownloadProgressTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SAPAssetProgress] = []

        func append(_ value: SAPAssetProgress) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var latest: SAPAssetProgress? {
            lock.lock()
            defer { lock.unlock() }
            return values.last
        }
    }

    func testParallelProgressCombinesPartsAndHandlesRetry() {
        let recorder = Recorder()
        let progress = SAPDownloadProgress(parts: 2, total: 100) { recorder.append($0) }

        progress.update(part: 0, bytes: 20)
        progress.update(part: 1, bytes: 30)
        XCTAssertEqual(recorder.latest, .downloading(completedBytes: 50, totalBytes: 100))

        progress.update(part: 0, bytes: 0)
        XCTAssertEqual(recorder.latest, .downloading(completedBytes: 30, totalBytes: 100))

        progress.update(part: 0, bytes: 50)
        progress.update(part: 1, bytes: 50)
        XCTAssertEqual(recorder.latest, .downloading(completedBytes: 100, totalBytes: 100))
    }
}
