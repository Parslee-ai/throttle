import Foundation

/// The fixed addresses and client identity the Codex adapter talks to.
///
/// The usage endpoint is the only one the adapter ever reads from. There is no
/// constant here for anything that spends quota or credits, on purpose.
enum OpenAIEndpoints {
    /// OAuth authorization page, opened in the browser during "Add Codex account".
    static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    /// OAuth token endpoint, used for the code exchange and for refresh.
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Read-only usage summary for the signed-in ChatGPT account.
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// The public client id the Codex CLI registers with; OpenAI issues no
    /// third-party client ids for subscription usage reads.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Scopes requested at login and carried through every refresh.
    static let scopes = ["openid", "profile", "email", "offline_access"]

    /// The usage endpoint answers only to Codex-shaped clients; the suffix
    /// identifies Throttle to anyone reading server logs.
    static let userAgent = "codex_cli_rs/0.145.0 (throttle)"
}
