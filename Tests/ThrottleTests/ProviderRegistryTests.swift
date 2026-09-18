import XCTest
@testable import Throttle

/// ISC-39/41: the registry answers for every `Provider` case, so `App/` and
/// `UI/` never name an adapter, a login flow, or an import source.
final class ProviderRegistryTests: XCTestCase {
    private let registry = ProviderRegistry(client: AuthMockHTTPClient(responses: []))

    func testEveryCaseHasAUsageProviderThatClaimsIt() {
        for provider in Provider.allCases {
            XCTAssertEqual(registry.usageProvider(for: provider).provider, provider)
        }
        XCTAssertEqual(Set(registry.usageProviders.keys), Set(Provider.allCases))
    }

    func testEveryCaseHasALoginFlow() {
        for provider in Provider.allCases {
            _ = registry.login(for: provider, client: AuthMockHTTPClient(responses: []))
        }
    }

    /// The menu is built from `allCases` plus these properties; a case with a
    /// manual-code mode needs a title for it, and an import needs a source name.
    func testMenuPropertiesAreConsistentPerCase() {
        for provider in Provider.allCases {
            XCTAssertEqual(provider.manualCodeMenuTitle != nil, provider.supportsManualCode, "\(provider)")
            if let source = provider.importSourceName {
                XCTAssertFalse(source.isEmpty, "\(provider)")
            } else {
                XCTAssertFalse(registry.importSourceExists(for: provider), "\(provider) offers no import source")
            }
        }
    }

    func testNoProviderCaseIsNamedInAppOrUI() throws {
        try RepoAudit.requireRepositoryAccess()
        let roots = ["Sources/Throttle/UI", "Sources/Throttle/App"].map { RepoAudit.root.appendingPathComponent($0) }
        var offenders: [String] = []
        for root in roots {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                for line in try RepoAudit.lines(in: url) where line.contains(".anthropic") || line.contains(".openai") {
                    offenders.append(line.location)
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, RepoAudit.report("App/ and UI/ must not branch on a provider case:", offenders))
    }
}
