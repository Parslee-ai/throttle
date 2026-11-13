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

    /// Stands in for a removed id.
    static let idReplacement = "[id]"

    /// `raw` with every occurrence of each id replaced in any letter case,
    /// then redacted, then cut to `maxLength` characters. Cutting last means
    /// half an id or half a token can never survive at the cut, where it
    /// would no longer match.
    static func capped(_ raw: String, hiding ids: some Sequence<String> = [String](), maxLength: Int) -> String {
        let shown = ids.filter { !$0.isEmpty }.reduce(raw) { out, id in
            out.replacingOccurrences(of: id, with: idReplacement, options: .caseInsensitive)
        }
        return String(redact(shown).prefix(maxLength))
    }

    /// Redacted first, so a token cut in half by the cap cannot slip past
    /// the redactor; then every control character (newlines included)
    /// becomes a space, runs of spaces collapse, and the result is capped at
    /// `maxLength` characters, the last one an ellipsis when it was cut.
    static func oneLine(_ raw: String, maxLength: Int) -> String {
        let redacted = redact(raw)
        var out = ""
        var lastWasSpace = false
        for scalar in redacted.unicodeScalars {
            let isSpace = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSpace {
                if !lastWasSpace { out.unicodeScalars.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }
}
