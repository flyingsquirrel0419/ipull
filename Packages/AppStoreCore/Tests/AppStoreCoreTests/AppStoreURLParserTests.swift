import XCTest
@testable import AppStoreCore

final class AppStoreURLParserTests: XCTestCase {

    func testKoreanAppStoreURL() throws {
        let result = AppStoreURLParser.parse("https://apps.apple.com/kr/app/instagram/id389801252")
        guard case .success(.appStoreURL(let id, let storefront)) = result else {
            return XCTFail("Expected appStoreURL, got \(result)")
        }
        XCTAssertEqual(id, 389801252)
        XCTAssertEqual(storefront, "kr")
    }

    func testUSURLWithQueryString() throws {
        let result = AppStoreURLParser.parse("https://apps.apple.com/us/app/discord/id985746746?uo=4&at=11l6hc")
        guard case .success(.appStoreURL(let id, let storefront)) = result else {
            return XCTFail("Expected appStoreURL, got \(result)")
        }
        XCTAssertEqual(id, 985746746)
        XCTAssertEqual(storefront, "us")
    }

    func testURLWithoutStorefront() throws {
        let result = AppStoreURLParser.parse("https://apps.apple.com/app/id389801252")
        guard case .success(.appStoreURL(let id, let storefront)) = result else {
            return XCTFail("Expected appStoreURL, got \(result)")
        }
        XCTAssertEqual(id, 389801252)
        XCTAssertNil(storefront)
    }

    func testSlugIsNotTrusted() throws {
        // Slug says one thing, ID says another — ID wins.
        let result = AppStoreURLParser.parse("https://apps.apple.com/kr/app/totally-fake-slug/id389801252")
        guard case .success(.appStoreURL(let id, _)) = result else {
            return XCTFail()
        }
        XCTAssertEqual(id, 389801252)
    }

    func testRawNumericAppID() {
        let result = AppStoreURLParser.parse("389801252")
        XCTAssertEqual(result, .success(.appID(389801252)))
    }

    func testBundleID() {
        XCTAssertEqual(AppStoreURLParser.parse("com.burbn.instagram"), .success(.bundleID("com.burbn.instagram")))
        XCTAssertEqual(AppStoreURLParser.parse("com.discord.Discord"), .success(.bundleID("com.discord.Discord")))
    }

    func testAppNameBecomesSearchTerm() {
        XCTAssertEqual(AppStoreURLParser.parse("Instagram"), .success(.searchTerm("Instagram")))
    }

    func testEmptyInputInvalid() {
        XCTAssertEqual(AppStoreURLParser.parse("   "), .failure(.invalidInput))
        XCTAssertEqual(AppStoreURLParser.parse(""), .failure(.invalidInput))
    }

    func testInvalidBundleIDs() {
        XCTAssertFalse(AppStoreURLParser.isPlausibleBundleID("com."))
        XCTAssertFalse(AppStoreURLParser.isPlausibleBundleID(".com.example"))
        XCTAssertFalse(AppStoreURLParser.isPlausibleBundleID("com..example"))
        XCTAssertFalse(AppStoreURLParser.isPlausibleBundleID("single"))
        XCTAssertFalse(AppStoreURLParser.isPlausibleBundleID("com.-bad"))
        XCTAssertFalse(AppStoreURLParser.isPlausibleBundleID("has space.com"))
        XCTAssertTrue(AppStoreURLParser.isPlausibleBundleID("a.b"))
        XCTAssertTrue(AppStoreURLParser.isPlausibleBundleID("com.company.app-name"))
    }

    func testNonAppleURLRejected() {
        let result = AppStoreURLParser.parse("https://apps.apple-phishing.example.com/kr/app/x/id389801252")
        // Not our host → falls through; "https..." contains no letters-only path so
        // it becomes a search term or invalid, but never a trusted appStoreURL.
        if case .success(.appStoreURL) = result {
            XCTFail("Non-Apple host must not be trusted")
        }
    }
}
