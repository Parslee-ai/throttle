import XCTest

/// ISC-67: no token, refresh token, or `Authorization` header value ever reaches
/// `print`, `os_log`, or a `Logger`.
///
/// The rule is enforced on the *line*, not on the runtime value, because a
/// bearer token that reaches the unified log is already leaked by the time a
/// runtime assertion could catch it. The single sanctioned way to put
/// credential-adjacent text in a log line is to route it through `Redactor`.
final class NoTokenLoggingTests: XCTestCase {
    private let loggingMarkers = ["print(", "os_log", "Logger(", "logger.", "NSLog("]

    /// `Authorization` covers the header name and its value; `credential` is
    /// matched case-insensitively so `AccountCredential` is caught too.
    private let caseSensitiveSecretMarkers = ["accessToken", "refreshToken", "Authorization"]
    private let caseInsensitiveSecretMarkers = ["credential"]

    private let redactionEscapeHatch = "Redactor.redact("

    func testNoLogLineNamesACredential() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() {
            guard !line.isComment else { continue }
            guard line.containsAny(loggingMarkers) else { continue }
            guard !line.contains(redactionEscapeHatch) else { continue }

            var hits = caseSensitiveSecretMarkers.filter(line.text.contains)
            let lowered = line.text.lowercased()
            hits += caseInsensitiveSecretMarkers.filter(lowered.contains)
            guard !hits.isEmpty else { continue }

            offenders.append("\(line.location): \(hits.joined(separator: ", ")) in \(line.trimmed)")
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report(
                "ISC-67: log line references a credential without passing it through \(redactionEscapeHatch)):",
                offenders
            )
        )
    }
}
