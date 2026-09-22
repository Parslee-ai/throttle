import XCTest

/// ISC-136: no analytics and no crash reporter. Throttle's only update check
/// is its own, user-initiated one against the project's GitHub Releases: it
/// runs when the user clicks Check for Updates, never on launch or a timer,
/// and it is built in, not an embedded update SDK.
///
/// Throttle's whole value rests on the claim that it talks to two vendors, and
/// to its own release page only when asked, and nobody else. A crash reporter
/// contradicts that claim silently, and would also be the one component with a
/// legitimate-looking reason to serialize process memory, which is where the
/// tokens are.
final class NoAnalyticsTests: XCTestCase {
    /// Matched case-sensitively, as the identifiers are actually spelled. The
    /// case matters: SF Symbol names are lowercase, and Throttle's Anthropic
    /// row uses the symbol `sparkles`, which a case-insensitive match on
    /// `Sparkle` would report as an embedded updater. Every real SDK reaches a
    /// source file capitalized, in an `import`, a type name, or a plist key.
    private let forbiddenIdentifiers = [
        "Sparkle",
        "Sentry",
        "Crashlytics",
        "TelemetryDeck",
        "Analytics",
    ]

    func testNoAnalyticsOrUpdateSDKAppearsInSources() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() {
            let hits = forbiddenIdentifiers.filter(line.text.contains)
            guard !hits.isEmpty else { continue }
            offenders.append("\(line.location): \(hits.joined(separator: ", ")) in \(line.trimmed)")
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report(
                "ISC-136: analytics, crash reporting, or update-check identifier in Sources/:",
                offenders
            )
        )
    }
}
