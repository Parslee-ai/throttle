import Foundation

/// Strips credential-shaped substrings out of any text before it reaches a log,
/// an error message, or the screen.
///
/// Error strings from a provider can echo the request, and a request carries a
/// bearer token. Everything user-visible passes through here.
enum Redactor {
    private static let replacement = "[redacted]"

    /// Ordered on purpose: the `Bearer` pattern runs first so a bearer header
    /// carrying a JWT collapses to a single marker instead of two.
    private static let patterns: [String] = [
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
        #"\bsk-[A-Za-z0-9._-]{4,}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]+){0,2}"#,
    ]

    /// Returns `s` with any bearer token, `sk-` key, or JWT-looking run replaced.
    static func redact(_ s: String) -> String {
        var out = s
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(
                in: out,
                options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: replacement
            )
        }
        return out
    }
}
