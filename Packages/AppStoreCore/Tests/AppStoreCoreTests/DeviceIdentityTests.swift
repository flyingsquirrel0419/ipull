import XCTest
@testable import AppStoreCore

final class DeviceIdentityTests: XCTestCase {
    func testGUIDFormat() {
        let guid = DeviceIdentity.guidFromUUID(UUID())
        XCTAssertTrue(DeviceIdentity.isValidGUID(guid))
        XCTAssertEqual(guid.count, 12)
    }

    func testGUIDStableAcrossCalls() throws {
        let store = InMemorySecretStore()
        let first = try DeviceIdentity.currentGUID(secretStore: store)
        let second = try DeviceIdentity.currentGUID(secretStore: store)
        XCTAssertEqual(first, second)
    }

    func testValidation() {
        XCTAssertTrue(DeviceIdentity.isValidGUID("AABBCCDDEEFF"))
        XCTAssertFalse(DeviceIdentity.isValidGUID("aabbccddeeff")) // lowercase
        XCTAssertFalse(DeviceIdentity.isValidGUID("AABBCC"))       // too short
        XCTAssertFalse(DeviceIdentity.isValidGUID("ZZZZZZZZZZZZ")) // non-hex
    }
}
