import XCTest

/// ISC-56 and ISC-77: Throttle reads status and never spends quota to learn
/// quota. These path fragments are the endpoints that would send a prompt or
/// burn a credit, so their presence anywhere under `Sources/` is the failure.
final class ForbiddenEndpointTests: XCTestCase {
    private let forbiddenFragments = [
        "/v1/messages",
        "/complete",
        "/consume",
        "/responses",
        "rate-limit-reset-credits",
    ]

    func testNoQuotaSpendingEndpointAppearsInSources() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() {
            for fragment in forbiddenFragments where line.contains(fragment) {
                offenders.append("\(line.location): \(fragment) in \(line.trimmed)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report(
                "ISC-56/ISC-77: endpoint that sends a prompt or spends quota:",
                offenders
            )
        )
    }
}
