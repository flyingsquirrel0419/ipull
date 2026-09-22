import XCTest
@testable import AppStoreCore

final class BagServiceTests: XCTestCase {

    /// Real bag.xml shape: XML Document envelope wrapping a plist.
    private func makeEnvelopedBag() -> Data {
        let inner = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>urlBag</key><dict>
                <key>authenticateAccount</key>
                <string>https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate</string>
                <key>sign-sap-version</key><string>200</string>
                <key>redownloadProduct</key>
                <string>https://buy.itunes.apple.com/WebObjects/MZFinance.woa</string>
            </dict>
        </dict></plist>
        """
        let doc = "<?xml version=\"1.0\"?><Document><Protocol>" + inner + "</Protocol></Document>"
        return Data(doc.utf8)
    }

    func testParsesEnvelopedBag() throws {
        let bag = try BagService.parse(data: makeEnvelopedBag())
        XCTAssertEqual(bag.authEndpoint.host, "buy.itunes.apple.com")
        XCTAssertEqual(bag.sapVersion, "200")
        XCTAssertNotNil(bag.redownloadEndpoint)
    }

    func testParsesBarePlist() throws {
        let plist: [String: Any] = [
            "urlBag": ["authenticateAccount": "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let bag = try BagService.parse(data: data)
        XCTAssertEqual(bag.authEndpoint.host, "buy.itunes.apple.com")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try BagService.parse(data: Data("not xml at all".utf8)))
    }

    func testFallbackAuthEndpointWhenBagOmitsKeys() throws {
        // Current live bag.xml omits authenticateAccount — must fall back to the
        // documented default host.
        let plist: [String: Any] = ["urlBag": ["unrelated": "x"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let bag = try BagService.parse(data: data)
        XCTAssertEqual(bag.authEndpoint.host, "buy.itunes.apple.com")
    }

    func testRejectsNonAppleAuthHost() {
        let plist: [String: Any] = [
            "urlBag": ["authenticateAccount": "https://evil.example.com/authenticate"]
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertThrowsError(try BagService.parse(data: data))
    }
}
