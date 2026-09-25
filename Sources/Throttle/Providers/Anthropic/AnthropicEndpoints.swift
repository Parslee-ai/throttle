import Foundation

/// Every URL and constant the Anthropic adapter talks to, in one place.
///
/// Only OAuth-facing endpoints appear here, and there is deliberately no
/// messages or completions URL. The usage and profile reads never spend
/// quota. The one spending call is `resetRateLimits`, which spends a banked
/// limit reset and is sent only from `AnthropicProvider.useReset`, on an
/// explicit, confirmed user action.
enum AnthropicEndpoints {
    /// Current usage for the signed-in OAuth identity. `skip_spend=1` asks for
    /// the cheap window read without the spend computation; the bare path
    /// answered every request from this app with a one-hour 429 (ISA D-32).
    /// `cedar_ember=1` adds the banked-reset block the resets count is read
    /// from; it changes what the read reports, not what it costs.
    static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1&cedar_ember=1")!
    /// Profile of the signed-in OAuth identity: read after login, and once
    /// per account per launch for the plan and the organization id
    /// (`AnthropicProfileParser`).
    static let profile = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// Primary token endpoint, takes a JSON body.
    static let token = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// Fallback token endpoint, tried form-encoded when the primary answers 400.
    static let tokenFallback = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Spends one banked limit reset for the organization: the only endpoint
    /// here that spends anything. `nil` when the organization id is not a
    /// plain id, so nothing else can ever reach the URL path.
    static func resetRateLimits(orgUUID: String) -> URL? {
        guard isValidOrganizationID(orgUUID) else { return nil }
        return URL(string: "https://api.anthropic.com/api/organizations/\(orgUUID)/reset_rate_limits")
    }

    /// The reset program Throttle spends from, and the only one it ever sends.
    static let resetProgram = "cedar_ember"

    /// The public OAuth client id for Claude subscription access.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let betaHeader = "oauth-2025-04-20"
    static let apiVersion = "2023-06-01"

    /// Largest response body the adapter will read.
    static let maxBodyBytes = 256 * 1024

    /// `throttle/<CFBundleShortVersionString>`, falling back to `dev` when the
    /// running bundle has no marketing version (as under the test runner).
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "throttle/\(version ?? "dev")"
    }

    // MARK: - Id rules

    /// A grant id the reset program accepts: `^[a-z0-9_-]{1,40}$`.
    static func isValidGrantID(_ id: String) -> Bool {
        matches(id, maxLength: 40) { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
    }

    /// A request id the reset program accepts: `^[A-Za-z0-9_-]{1,64}$`.
    static func isValidRequestID(_ id: String) -> Bool {
        matches(id, maxLength: 64) {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// An organization id safe to place in a URL path, by the same rule as a
    /// request id.
    static func isValidOrganizationID(_ id: String) -> Bool {
        isValidRequestID(id)
    }

    private static func matches(_ id: String, maxLength: Int, _ allowed: (Unicode.Scalar) -> Bool) -> Bool {
        let scalars = id.unicodeScalars
        return !scalars.isEmpty && scalars.count <= maxLength && scalars.allSatisfy(allowed)
    }
}
