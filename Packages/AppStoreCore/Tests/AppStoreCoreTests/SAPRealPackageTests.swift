import XCTest
@testable import AppStoreCore

final class SAPRealPackageTests: XCTestCase {
    func testExtractsPinnedAssetsFromRealApplePackage() throws {
        guard let path = ProcessInfo.processInfo.environment["IPULL_REAL_SAP_PACKAGE"] else {
            throw XCTSkip("Set IPULL_REAL_SAP_PACKAGE to a locally downloaded Apple update package")
        }
        let assets = SAPAssets(http: URLSessionHTTPClient())
        let bundle = try assets.extractFrom(packageURL: URL(fileURLWithPath: path))
        XCTAssertEqual(bundle.commerceKit.count, 3_271_840)
        XCTAssertEqual(bundle.commerceCore.count, 207_744)
        XCTAssertEqual(bundle.coreFP.count, 29_014_912)
        XCTAssertEqual(bundle.coreFPICXS.count, 5_288_352)
    }
}
