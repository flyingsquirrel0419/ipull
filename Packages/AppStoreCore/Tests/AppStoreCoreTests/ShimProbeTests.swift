import XCTest
@testable import AppStoreCore

final class ShimProbeTests: XCTestCase {
    func testRegisteredSymbolsResolve() throws {
        let engine = try UnicornEngine()
        let shims = try SAPShims(engine: engine)
        let direct = shims.address(of: "_CFBundleGetMainBundle")
        print("direct lookup:", direct.map { String($0, radix: 16) } ?? "nil")
        XCTAssertNotNil(direct, "_CFBundleGetMainBundle should be pre-registered")
        let resolved = try shims.resolve("_CFBundleGetMainBundle")
        XCTAssertEqual(resolved, direct, "resolve must return the registered slot, not a trap")
    }
}
