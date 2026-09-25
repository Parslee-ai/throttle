import Foundation

/// What the usage payload's banked-reset block says about one account.
struct AnthropicResetGrants: Equatable, Sendable {
    /// Resets left across every valid grant, or `nil` when the account is not
    /// in the reset program or the block could not be read.
    var count: Int?
    /// The grant a reset would spend, or `nil` when no grant has a reset left.
    var selectedGrantID: String?

    static let absent = AnthropicResetGrants(count: nil, selectedGrantID: nil)
}

/// Reads the banked-reset block (`cedar_ember`) of the usage payload, and
/// answers of the reset request.
///
/// Separate from `AnthropicUsageParser` on purpose: nothing in this block can
/// break the window reading. Every failure here means "no count".
enum AnthropicResetParser {
    /// The block's key in the usage payload.
    static let blockKey = AnthropicEndpoints.resetProgram

    /// The block in a usage body. Never throws: a missing, ineligible, or
    /// malformed block is `.absent`.
    ///
    /// - No block, or `eligible` not `true`: no count.
    /// - Eligible with no grants: 0.
    /// - Otherwise the sum of `resets_left` over the valid grants. A grant is
    ///   valid when it is an object whose `id` passes the grant-id rule and
    ///   whose `resets_left` is a non-negative whole number; the rest are
    ///   skipped. Grants present but none valid: no count.
    static func parse(_ data: Data) -> AnthropicResetGrants {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let block = root[blockKey] as? [String: Any],
              let eligible = block["eligible"] as? NSNumber, isBoolean(eligible), eligible.boolValue else {
            return .absent
        }

        let rawGrants: [Any]
        switch block["grants"] {
        case nil, is NSNull:
            rawGrants = []
        case let list as [Any]:
            rawGrants = list
        default:
            return .absent
        }

        let grants = rawGrants.compactMap(Grant.init)
        if grants.isEmpty {
            return AnthropicResetGrants(count: rawGrants.isEmpty ? 0 : nil, selectedGrantID: nil)
        }
        let count = grants.reduce(0) { $0 + $1.resetsLeft }
        return AnthropicResetGrants(count: count, selectedGrantID: select(grants, next: block["next_grant_id"]))
    }

    /// One valid grant, reduced to the fields selection needs.
    struct Grant: Equatable {
        let id: String
        let resetsLeft: Int
        let usableNow: Bool
        let endsAt: Date?

        init?(_ value: Any) {
            guard let object = value as? [String: Any],
                  let id = object["id"] as? String, AnthropicEndpoints.isValidGrantID(id),
                  let left = AnthropicResetParser.wholeNumber(object["resets_left"]), left >= 0 else {
                return nil
            }
            self.id = id
            self.resetsLeft = left
            if let usable = object["usable_now"] as? NSNumber, AnthropicResetParser.isBoolean(usable) {
                self.usableNow = usable.boolValue
            } else {
                self.usableNow = false
            }
            if case .date(let date) = AnthropicUsageParser.parseReset(object["ends_at"], present: object.keys.contains("ends_at")) {
                self.endsAt = date
            } else {
                self.endsAt = nil
            }
        }
    }

    /// The grant a reset would spend, chosen so the button never disagrees
    /// with the count, which sums every valid grant:
    ///
    /// 1. `next_grant_id`, when it passes the id rule and names a valid grant.
    /// 2. Else the usable grant (`usable_now`, resets left) that ends soonest.
    /// 3. Else any grant with resets left that ends soonest. The provider
    ///    then answers for itself (`not_limited`, say), which is honest and
    ///    costs no extra read.
    ///
    /// A grant with no end sorts last and payload order breaks ties. `nil`
    /// only when no grant has a reset left.
    static func select(_ grants: [Grant], next: Any?) -> String? {
        if let next = next as? String,
           AnthropicEndpoints.isValidGrantID(next),
           grants.contains(where: { $0.id == next }) {
            return next
        }
        let withResets = grants.enumerated().filter { $0.element.resetsLeft > 0 }
        let usable = withResets.filter { $0.element.usableNow }
        let soonest = (usable.isEmpty ? withResets : usable).min { a, b in
            switch (a.element.endsAt, b.element.endsAt) {
            case let (x?, y?): return x != y ? x < y : a.offset < b.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }
        return soonest?.element.id
    }

    // MARK: - Reset answer

    /// Maps a 2xx body of the reset request onto a `ResetOutcome`. A body
    /// that is not an object, or names no result this build knows, is
    /// `.unexpected` and never success. A cooldown time is kept only when it
    /// is in the future.
    ///
    /// `result` decides. `ineligible` is `.notAvailable` and `unavailable` is
    /// `.unexpected` (possibly spent) unless `reason` refines it, and a reason
    /// sent in `result`'s place reads the same:
    /// - `unknown_grant`, `not_next_grant`, `paused`, `expired`: the grant went
    ///   stale. `.notAvailable`; the scheduler's re-read corrects the count.
    /// - `no_grant`: nothing to spend. `.noCredit`.
    /// - `stamp_indeterminate`, `reset_unconfirmed`: it is unknown whether a
    ///   reset was spent. `.unexpected`, so the scheduler keeps the attempt id
    ///   and re-reads.
    /// - `grant_id_required`: the request lacked a grant this build should
    ///   have sent. `.unexpected`.
    static func outcome(_ data: Data, now: Date) -> ResetOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let result = root["result"] as? String else {
            return .unexpected
        }
        switch result {
        case "reset", "already_used":
            return .reset
        case "not_limited":
            return .nothingToReset
        case "cooldown":
            var until: Date?
            if case .date(let date) = AnthropicUsageParser.parseReset(root["cooldown_until"], present: root.keys.contains("cooldown_until")),
               date > now {
                until = date
            }
            return .cooldown(until: until)
        case "ineligible":
            return refusal(reason: root["reason"] as? String) ?? .notAvailable
        case "unavailable":
            // Claude's own client treats this as unconfirmed: the reset may
            // have been spent. Unless the reason names a stale grant or no
            // grant, keep the attempt id and re-read.
            return refusal(reason: root["reason"] as? String) ?? .unexpected
        default:
            return refusal(reason: result) ?? .unexpected
        }
    }

    /// What a refusal's reason adds, or `nil` when it adds nothing to the
    /// result (absent, or an eligibility reason such as `tier`).
    private static func refusal(reason: String?) -> ResetOutcome? {
        switch reason {
        case "unknown_grant", "not_next_grant", "paused", "expired":
            return .notAvailable
        case "no_grant":
            return .noCredit
        case "stamp_indeterminate", "reset_unconfirmed", "grant_id_required":
            return .unexpected
        default:
            return nil
        }
    }

    // MARK: - Helpers

    /// A JSON integer (not a boolean, not a fraction), or `nil`.
    static func wholeNumber(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}
