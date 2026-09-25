import XCTest

/// ISC-56 and ISC-77: Throttle reads status and never spends quota to learn
/// quota.
///
/// Endpoints that send a prompt (`/v1/messages`, `/complete`, `/responses`)
/// are forbidden everywhere under `Sources/`.
///
/// Spending a banked limit reset is the one deliberate exception, and it is
/// narrowed on purpose rather than lifted: the user spends a reset only from
/// the detail window, on an explicit and confirmed click, through
/// `UsageProvider.useReset`. So the reset paths (`/consume`,
/// `rate-limit-reset-credits`, `reset_rate_limits`) may appear only in each
/// provider's endpoints file and in its adapter, which owns the reset call.
/// Anywhere else, including the scheduler, the app, and the UI, they are a
/// failure: a reset path leaking out of the adapter is how a poll could end
/// up spending one.
final class ForbiddenEndpointTests: XCTestCase {
    private let promptFragments = [
        "/v1/messages",
        "/complete",
        "/responses",
    ]

    private let resetFragments = [
        "/consume",
        "rate-limit-reset-credits",
        "reset_rate_limits",
    ]

    /// The only files a reset path may appear in.
    private let resetAllowedFiles: Set<String> = [
        "Sources/Throttle/Providers/OpenAI/OpenAIEndpoints.swift",
        "Sources/Throttle/Providers/OpenAI/OpenAIProvider.swift",
        "Sources/Throttle/Providers/Anthropic/AnthropicEndpoints.swift",
        "Sources/Throttle/Providers/Anthropic/AnthropicProvider.swift",
    ]

    func testNoPromptEndpointAppearsInSources() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() {
            for fragment in promptFragments where line.contains(fragment) {
                offenders.append("\(line.location): \(fragment) in \(line.trimmed)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report("ISC-56/ISC-77: endpoint that sends a prompt:", offenders)
        )
    }

    func testResetPathsAppearOnlyInTheProviderAdapters() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() where !resetAllowedFiles.contains(line.file) {
            for fragment in resetFragments where line.contains(fragment) {
                offenders.append("\(line.location): \(fragment) in \(line.trimmed)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report("A reset path outside the provider adapters:", offenders)
        )
    }
}
