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

    func testRotateGUIDReplacesPersistedIdentity() throws {
        let store = InMemorySecretStore()
        let original = try DeviceIdentity.currentGUID(secretStore: store)
        let rotated = try DeviceIdentity.rotateGUID(secretStore: store)
        XCTAssertTrue(DeviceIdentity.isValidGUID(rotated))
        XCTAssertNotEqual(rotated, original, "rotation must not re-issue the vendor-derived GUID")
        // Subsequent lookups must return the rotated identity.
        XCTAssertEqual(try DeviceIdentity.currentGUID(secretStore: store), rotated)
    }

    func testMachineIDIsRawBytesOfGUID() {
        // ipatool parity: guid == uppercase hex(machineID).
        let id = DeviceIdentity.machineID(forGUID: "AABBCCDDEEFF")
        XCTAssertEqual(id, Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        XCTAssertEqual(id.map { String(format: "%02X", $0) }.joined(), "AABBCCDDEEFF")
    }

    func testValidation() {
        XCTAssertTrue(DeviceIdentity.isValidGUID("AABBCCDDEEFF"))
        XCTAssertFalse(DeviceIdentity.isValidGUID("aabbccddeeff")) // lowercase
        XCTAssertFalse(DeviceIdentity.isValidGUID("AABBCC"))       // too short
        XCTAssertFalse(DeviceIdentity.isValidGUID("ZZZZZZZZZZZZ")) // non-hex
    }
}
