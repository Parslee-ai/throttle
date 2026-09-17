import XCTest
@testable import Throttle

final class ProviderTests: XCTestCase {
    /// ISC-40: exactly two provider cases, no more, no fewer.
    func testExactlyTwoProviders() {
        XCTAssertEqual(Provider.allCases.count, 2)
        XCTAssertEqual(Set(Provider.allCases), [.anthropic, .openai])
    }

    func testRawValuesAreStableStorageKeys() {
        XCTAssertEqual(Provider.anthropic.rawValue, "anthropic")
        XCTAssertEqual(Provider.openai.rawValue, "openai")
    }

    func testDisplayNamesAreProductNames() {
        XCTAssertEqual(Provider.anthropic.displayName, "Claude")
        XCTAssertEqual(Provider.openai.displayName, "Codex")
    }

    /// ISC-41: the "Add account" menu is built by iterating `allCases`, so every
    /// case must carry the label and glyph that menu needs. A third provider
    /// then appears in the menu with no UI edit.
    func testEveryCaseCarriesMenuMetadata() {
        for provider in Provider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) has no displayName")
            XCTAssertFalse(provider.symbolName.isEmpty, "\(provider) has no symbolName")
        }
        let names = Provider.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "displayName must be unique per provider")
    }

    func testProviderRoundTripsThroughJSON() throws {
        for provider in Provider.allCases {
            let data = try JSONEncoder().encode(provider)
            XCTAssertEqual(try JSONDecoder().decode(Provider.self, from: data), provider)
        }
    }
}
