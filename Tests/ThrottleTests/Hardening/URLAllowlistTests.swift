import XCTest

/// ISC-133: every network call is HTTPS to one of five hosts, and the only
/// cleartext URLs are the OAuth loopback redirect and its parser.
///
/// This is a text audit of `Sources/`, not a runtime check, because the point is
/// that no sixth host can be *introduced*. A runtime test only proves that the
/// hosts exercised by that test are allowed.
final class URLAllowlistTests: XCTestCase {
    /// The five vendor surfaces from ISC-133. `platform.claude.com` and
    /// `console.anthropic.com` are the same surface mid-rename, so both appear.
    private let allowedHTTPSHosts: Set<String> = [
        "api.anthropic.com",
        "platform.claude.com",
        "console.anthropic.com",
        "claude.ai",
        "chatgpt.com",
        "auth.openai.com",
    ]

    /// The loopback redirect target. Cleartext is correct here and nowhere else:
    /// the OAuth callback never leaves the machine (ISC-135).
    private let allowedHTTPHosts: Set<String> = ["localhost", "127.0.0.1"]

    /// `https://api.openai.com/auth` is a *claim namespace*, not an endpoint: it
    /// is the JSON key of OpenAI's private claim object inside an already-issued
    /// JWT, read with a dictionary subscript and never resolved. Exempting it
    /// keeps the allowlist about network calls, which is what ISC-133 constrains.
    /// The exemption is deliberately narrow: the same literal on a line that
    /// builds a `URL` or a `URLRequest` still fails.
    private let claimNamespaceLiteral = "https://api.openai.com/auth"
    private let urlConstructionMarkers = ["URL(", "URLRequest", "URLComponents"]

    func testEveryHTTPSHostIsOnTheAllowlist() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() {
            if line.contains(claimNamespaceLiteral),
               !line.containsAny(urlConstructionMarkers) {
                continue
            }
            for occurrence in RepoAudit.hosts(ofScheme: "https", in: line.text)
            where !allowedHTTPSHosts.contains(occurrence.host) {
                offenders.append("\(line.location): \(occurrence.snippet)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report(
                "ISC-133: https host not on the allowlist \(allowedHTTPSHosts.sorted()):",
                offenders
            )
        )
    }

    func testEveryCleartextURLIsLoopback() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() {
            for occurrence in RepoAudit.hosts(ofScheme: "http", in: line.text)
            where !allowedHTTPHosts.contains(occurrence.host) {
                offenders.append("\(line.location): \(occurrence.snippet)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report(
                "ISC-133: cleartext http:// URL that is not localhost or 127.0.0.1:",
                offenders
            )
        )
    }

    /// Guards the guard: if the audit ever stops finding URLs at all, the two
    /// tests above pass vacuously and stop protecting anything.
    func testTheAuditActuallyReadsTheSources() throws {
        let lines = try RepoAudit.sourceLines()
        XCTAssertGreaterThan(lines.count, 100, "Source audit found almost no lines; check the repo root derivation")
        let httpsCount = lines.reduce(0) { $0 + RepoAudit.hosts(ofScheme: "https", in: $1.text).count }
        XCTAssertGreaterThan(httpsCount, 0, "Source audit found no https:// URLs at all")
    }
}
