import XCTest
@testable import AppStoreCore

final class StorefrontTests: XCTestCase {
    func testStorefrontHeaderParsing() {
        XCTAssertEqual(Storefront.countryCode(forStorefrontID: "143466-1,29"), "kr")
        XCTAssertEqual(Storefront.countryCode(forStorefrontID: "143441-1,29"), "us")
        XCTAssertEqual(Storefront.countryCode(forStorefrontID: "143462-7,29"), "jp")
    }

    func testStorefrontWithoutSuffix() {
        XCTAssertEqual(Storefront.countryCode(forStorefrontID: "143466"), "kr")
    }

    func testUnknownStorefront() {
        XCTAssertNil(Storefront.countryCode(forStorefrontID: "999999-1"))
    }

    func testCountryToStorefront() {
        XCTAssertEqual(Storefront.storefrontID(forCountryCode: "KR"), "143466")
        XCTAssertEqual(Storefront.storefrontID(forCountryCode: "us"), "143441")
    }
}
