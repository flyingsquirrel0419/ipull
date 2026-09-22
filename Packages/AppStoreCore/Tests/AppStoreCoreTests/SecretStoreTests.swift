import XCTest
@testable import AppStoreCore

final class SecretStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let store = InMemorySecretStore()
        let payload = Data("session-token".utf8)
        try store.save(payload, for: "k")
        XCTAssertEqual(try store.load(key: "k"), payload)
    }

    func testDelete() throws {
        let store = InMemorySecretStore()
        try store.save(Data("x".utf8), for: "k")
        try store.delete(key: "k")
        XCTAssertNil(try store.load(key: "k"))
    }

    func testOverwrite() throws {
        let store = InMemorySecretStore()
        try store.save(Data("a".utf8), for: "k")
        try store.save(Data("b".utf8), for: "k")
        XCTAssertEqual(try store.load(key: "k"), Data("b".utf8))
    }
}
