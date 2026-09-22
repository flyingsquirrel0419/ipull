import XCTest
@testable import AppStoreCore

final class AppStoreErrorTests: XCTestCase {
    func testUserMessagesContainNoInternals() {
        let errors: [AppStoreError] = [
            .authenticationFailed, .sessionExpired, .twoFactorRequired,
            .appNotOwned, .downloadFailed("cdn timeout 54.123.x.x"), .unknown("plist parse at byte 8821"),
        ]
        for error in errors {
            let message = error.userMessage
            XCTAssertFalse(message.contains("passwordToken"))
            XCTAssertFalse(message.contains("MZFinance"))
            XCTAssertFalse(message.contains("dsid"))
        }
    }

    func testReauthMapping() {
        XCTAssertTrue(AppStoreError.sessionExpired.requiresReauthentication)
        XCTAssertTrue(AppStoreError.authenticationRequired.requiresReauthentication)
        XCTAssertFalse(AppStoreError.appNotFound.requiresReauthentication)
    }
}
