import Foundation

/// What the adapter reads from `api/oauth/profile`: the account's email and
/// its subscription plan.
struct AnthropicProfile: Hashable, Sendable {
    var email: String?
    /// A plan such as `max 20x` or `pro`, or `nil` when the profile names no
    /// organization type. Never the organization's name.
    var planLabel: String?
}

/// Turns the profile payload into an `AnthropicProfile`.
///
/// The plan comes from `organization.organization_type` (`claude_max`,
/// `claude_pro`, …) with the leading `claude_` removed, so a type added later
/// passes through the same way instead of being looked up in a list. A
/// trailing multiplier on `organization.rate_limit_tier`
/// (`default_claude_max_20x`) is appended: `max 20x`.
enum AnthropicProfileParser {
    static let typePrefix = "claude_"
    /// A plan label longer than this is not a plan label; it is cut.
    static let maxPlanLength = 40

    /// The profile, or `nil` when the body is not a JSON object.
    static func parse(_ data: Data) -> AnthropicProfile? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any] else {
            return nil
        }
        var email = nonEmpty((root["account"] as? [String: Any])?["email"] as? String)
        if email == nil {
            email = nonEmpty(root["email"] as? String)
        }
        let organization = root["organization"] as? [String: Any]
        return AnthropicProfile(
            email: email,
            planLabel: planLabel(
                organizationType: organization?["organization_type"] as? String,
                rateLimitTier: organization?["rate_limit_tier"] as? String
            )
        )
    }

    /// `claude_max` + `default_claude_max_20x` → `max 20x`; `claude_pro` → `pro`;
    /// no type → `nil`, whatever the tier says.
    static func planLabel(organizationType: String?, rateLimitTier: String?) -> String? {
        guard var plan = nonEmpty(organizationType)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if plan.lowercased().hasPrefix(typePrefix) {
            plan = String(plan.dropFirst(typePrefix.count))
        }
        guard !plan.isEmpty else { return nil }
        if let tier = rateLimitTier,
           let range = tier.range(of: #"_[0-9]+x$"#, options: .regularExpression) {
            let multiplier = String(tier[range].dropFirst())
            if !plan.hasSuffix(multiplier) {
                plan += " " + multiplier
            }
        }
        return String(plan.prefix(maxPlanLength))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
