import Foundation

/// Every URL and constant the Anthropic adapter talks to, in one place.
///
/// Only OAuth-facing read endpoints appear here. There is deliberately no
/// messages or completions URL: Throttle reads usage, it never spends it.
enum AnthropicEndpoints {
    /// Current usage for the signed-in OAuth identity. `skip_spend=1` asks for
    /// the cheap window read without the spend computation; the bare path
    /// answered every request from this app with a one-hour 429 (ISA D-32).
    static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1")!
    /// Profile of the signed-in OAuth identity, read once after login.
    static let profile = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// Primary token endpoint, takes a JSON body.
    static let token = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// Fallback token endpoint, tried form-encoded when the primary answers 400.
    static let tokenFallback = URL(string: "https://platform.claude.com/v1/oauth/token")!

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
}
