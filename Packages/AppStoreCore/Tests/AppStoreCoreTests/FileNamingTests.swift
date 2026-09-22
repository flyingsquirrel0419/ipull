import XCTest
@testable import AppStoreCore

final class FileNamingTests: XCTestCase {
    func testBasicName() {
        XCTAssertEqual(FileNaming.sanitize("Instagram"), "Instagram")
    }

    func testPathSeparatorsRemoved() {
        XCTAssertEqual(FileNaming.sanitize("a/b\\c"), "abc")
    }

    func testControlCharactersRemoved() {
        XCTAssertEqual(FileNaming.sanitize("app\u{0}name"), "appname")
    }

    func testWhitespaceCollapsed() {
        XCTAssertEqual(FileNaming.sanitize("My   App"), "My App")
    }

    func testEmptyBecomesDefault() {
        XCTAssertEqual(FileNaming.sanitize("///"), "app")
    }

    func testLengthCap() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(FileNaming.sanitize(long).count, 80)
    }

    func testIPAFileName() {
        XCTAssertEqual(FileNaming.ipaFileName(appName: "Instagram", version: "446.0.0"), "Instagram_446.0.0.ipa")
    }

    func testLeadingDotsRemoved() {
        XCTAssertEqual(FileNaming.sanitize("..hidden"), "hidden")
    }
}
