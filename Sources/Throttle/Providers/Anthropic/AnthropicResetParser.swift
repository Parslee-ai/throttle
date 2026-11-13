import Foundation

/// What the usage payload's banked-reset block says about one account.
///
/// Time-free: it records what the payload said. Which grants have expired,
/// which can be spent, and the kinds a row shows are judged later against a
/// clock (`kinds(at:modelName:)`, `resolve(_:at:)`), so a spend is judged at
/// the click and not at the read.
struct AnthropicResetGrants: Equatable, Sendable {
    /// Resets left across every valid grant, expired or not, or `nil` when
    /// the account is not in the reset program or the block could not be read.
    var count: Int?
    /// The grant the provider recommends across every kind, by the rules of
    /// `AnthropicResetParser.select`. A spend never uses it: it resolves the
    /// owner's kind with `resolve(_:at:)` instead.
    var selectedGrantID: String?
    /// The valid grants, in payload order, with every duplicated id dropped.
    var grants: [AnthropicResetParser.Grant] = []
    /// `next_grant_id`, when it passes the id rule and names a valid grant.
    var nextGrantID: String?
    /// Whether the account is at a limit: `false` when the block does not say,
    /// `nil` when it says something that is not a boolean.
    var atLimit: Bool? = false
    /// The account's cooldown. `.absent` when there is none.
    var cooldown: AnthropicUsageParser.ResetValue = .absent
    /// Why the provider says the account is not eligible, from the fixed list
    /// in `AnthropicResetParser.ineligibleReasons` or `unknown`. Only for the
    /// diagnostics log; it never reaches a status.
    var ineligibleReason: String?
    /// For an eligible block that yields no count, the rule that failed. Only
    /// for the diagnostics log; it names no grant.
    var noCountRule: String?

    static let absent = AnthropicResetGrants(count: nil, selectedGrantID: nil)
}

/// Reads the banked-reset block (`cedar_ember`) of the usage payload, and
/// answers of the reset request.
///
/// Separate from `AnthropicUsageParser` on purpose: nothing in this block can
/// break the window reading. Every failure here means "no count", or one
/// grant fewer.
enum AnthropicResetParser {
    /// The block's key in the usage payload.
    static let blockKey = AnthropicEndpoints.resetProgram

    /// The not-eligible reasons the diagnostics log names. Anything else is
    /// written as `unknown`, so provider text never reaches the log.
    static let ineligibleReasons: Set<String> = [
        "config_off", "tier", "seat", "mobile", "surface", "cli_version", "no_grant", "tenure", "other_experiment", "unavailable",
    ]

    /// The block in a usage body. Never throws: a missing, ineligible, or
    /// malformed block is `.absent`, apart from the diagnostics fields.
    ///
    /// - No block, or `eligible` not `true`: no count.
    /// - Eligible with no grants: 0.
    /// - Otherwise the sum of `resets_left` over the valid grants. A grant is
    ///   valid when it passes every rule in `Grant.init`; the rest are
    ///   skipped, one at a time, so a bad grant can only under-count. An id
    ///   that appears more than once drops every copy, because the copies may
    ///   disagree. Grants present but none valid: no count.
    static func parse(_ data: Data) -> AnthropicResetGrants {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let block = root[blockKey] as? [String: Any],
              let eligible = block["eligible"] as? NSNumber, isBoolean(eligible) else {
            return .absent
        }
        guard eligible.boolValue else {
            var out = AnthropicResetGrants.absent
            let reason = block["ineligible_reason"] as? String
            out.ineligibleReason = reason.map { ineligibleReasons.contains($0) ? $0 : "unknown" } ?? "unknown"
            return out
        }

        let rawGrants: [Any]
        switch block["grants"] {
        case nil, is NSNull:
            rawGrants = []
        case let list as [Any]:
            rawGrants = list
        default:
            var out = AnthropicResetGrants.absent
            out.noCountRule = "grants is not a list"
            return out
        }

        var parsed: [Grant] = []
        var firstRejection: String?
        for raw in rawGrants {
            switch Grant.read(raw) {
            case .success(let grant): parsed.append(grant)
            case .failure(let rule): firstRejection = firstRejection ?? rule.rawValue
            }
        }
        var idCounts: [String: Int] = [:]
        for grant in parsed { idCounts[grant.id, default: 0] += 1 }
        let grants = parsed.filter { idCounts[$0.id] == 1 }
        if grants.count < parsed.count {
            firstRejection = firstRejection ?? Grant.Rule.duplicateID.rawValue
        }

        var out = AnthropicResetGrants(count: nil, selectedGrantID: nil)
        out.atLimit = optionalBoolean(block["at_limit"], absent: false)
        out.cooldown = AnthropicUsageParser.parseReset(block["cooldown_until"], present: block.keys.contains("cooldown_until"))
        if grants.isEmpty {
            if rawGrants.isEmpty {
                out.count = 0
            } else {
                out.noCountRule = firstRejection
            }
            return out
        }
        out.grants = grants
        out.count = grants.reduce(0) { $0 + $1.resetsLeft }
        out.selectedGrantID = select(grants, next: block["next_grant_id"])
        if let next = block["next_grant_id"] as? String, grants.contains(where: { $0.id == next }) {
            out.nextGrantID = next
        }
        return out
    }

    /// One valid grant.
    struct Grant: Equatable, Sendable {
        let id: String
        let kind: ResetKind.Key
        let resetsLeft: Int
        /// `nil` when the grant does not say.
        let resetsTotal: Int?
        let startsAt: Date?
        let endsAt: Date?
        let paused: Bool
        /// Absent reads as not usable: an unstated permission is not one.
        let usableNow: Bool
        /// Absent reads as needing a limit, for the same reason.
        let requiresLimit: Bool
        /// A model refill whose every usage figure is exactly 0, so spending
        /// it would give nothing back. An empty, missing or partly unreadable
        /// usage map is unknown and never sets this.
        let nothingToGiveBack: Bool

        /// Why a grant is skipped. Names a rule, never a grant.
        enum Rule: String, Sendable {
            case notAnObject = "a grant is not an object"
            case id = "a grant id fails the id rule"
            case resetsLeft = "resets_left is not a whole number of 0 or more"
            case resetsTotal = "resets_total is not a whole number at least resets_left"
            case flag = "a grant flag is not a boolean"
            case date = "a grant date is unreadable"
            case duplicateID = "a grant id appears more than once"
        }

        init?(_ value: Any) {
            guard case .success(let grant) = Self.read(value) else { return nil }
            self = grant
        }

        private init(
            id: String, kind: ResetKind.Key, resetsLeft: Int, resetsTotal: Int?, startsAt: Date?, endsAt: Date?,
            paused: Bool, usableNow: Bool, requiresLimit: Bool, nothingToGiveBack: Bool
        ) {
            self.id = id
            self.kind = kind
            self.resetsLeft = resetsLeft
            self.resetsTotal = resetsTotal
            self.startsAt = startsAt
            self.endsAt = endsAt
            self.paused = paused
            self.usableNow = usableNow
            self.requiresLimit = requiresLimit
            self.nothingToGiveBack = nothingToGiveBack
        }

        /// The grant, or the first rule it breaks. Its label and its list of
        /// windows cleared are never read, so nothing in them can matter.
        static func read(_ value: Any) -> Result<Grant, RuleFailure> {
            guard let object = value as? [String: Any] else { return .failure(.init(.notAnObject)) }
            guard let id = object["id"] as? String, AnthropicEndpoints.isValidGrantID(id) else {
                return .failure(.init(.id))
            }
            guard let left = AnthropicResetParser.wholeNumber(object["resets_left"]), left >= 0 else {
                return .failure(.init(.resetsLeft))
            }
            var total: Int?
            if let raw = object["resets_total"], !(raw is NSNull) {
                guard let whole = AnthropicResetParser.wholeNumber(raw), whole >= left else {
                    return .failure(.init(.resetsTotal))
                }
                total = whole
            }
            guard let paused = optionalBoolean(object["paused"], absent: false),
                  let usable = optionalBoolean(object["usable_now"], absent: false),
                  let requiresLimit = optionalBoolean(object["use_requires_limit"], absent: true),
                  let givesBackWeekly = optionalBoolean(object["gives_back_weekly"], absent: false) else {
                return .failure(.init(.flag))
            }
            let starts = AnthropicUsageParser.parseReset(object["starts_at"], present: object.keys.contains("starts_at"))
            let ends = AnthropicUsageParser.parseReset(object["ends_at"], present: object.keys.contains("ends_at"))
            guard starts != .malformed, ends != .malformed else { return .failure(.init(.date)) }

            let kind = AnthropicResetParser.kind(type: object["type"], givesBackWeekly: givesBackWeekly)
            return .success(Grant(
                id: id,
                kind: kind,
                resetsLeft: left,
                resetsTotal: total,
                startsAt: starts.date,
                endsAt: ends.date,
                paused: paused,
                usableNow: usable,
                requiresLimit: requiresLimit,
                nothingToGiveBack: kind == .modelRefill && AnthropicResetParser.allUsageIsZero(object["percent_used"])
            ))
        }

        /// The failing rule, wrapped so it can ride in a `Result`.
        struct RuleFailure: Error, Sendable {
            let rule: Rule
            var rawValue: String { rule.rawValue }
            init(_ rule: Rule) { self.rule = rule }
        }
    }

    /// The kind rule: `gives_back_weekly` true is a model refill whatever
    /// `type` says; otherwise `type` names it, and any other, missing or
    /// non-text `type` is the unknown kind, still counted and spendable.
    static func kind(type: Any?, givesBackWeekly: Bool) -> ResetKind.Key {
        if givesBackWeekly { return .modelRefill }
        switch type as? String {
        case "full": return .full
        case "weekly": return .weekly
        case "session": return .session
        default: return .other
        }
    }

    /// True only when the usage map is an object with at least one figure and
    /// every figure is a number equal to 0. Anything unreadable is unknown.
    static func allUsageIsZero(_ value: Any?) -> Bool {
        guard let map = value as? [String: Any], !map.isEmpty else { return false }
        return map.values.allSatisfy { figure in
            guard let n = figure as? NSNumber, !isBoolean(n) else { return false }
            return n.doubleValue == 0
        }
    }

    /// The grant the provider recommends across every kind. A spend never
    /// uses it: it resolves the owner's kind with `resolve(_:at:)`.
    ///
    /// 1. `next_grant_id`, when it passes the id rule and names a valid grant.
    /// 2. Else the usable grant (`usable_now`, resets left) that ends soonest.
    /// 3. Else any grant with resets left that ends soonest.
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
        return soonestEnding(usable.isEmpty ? withResets : usable)?.id
    }

    /// The grant that ends soonest; no end sorts last, and payload order
    /// breaks ties.
    fileprivate static func soonestEnding(_ grants: [(offset: Int, element: Grant)]) -> Grant? {
        grants.min { a, b in
            switch (a.element.endsAt, b.element.endsAt) {
            case let (x?, y?): return x != y ? x < y : a.offset < b.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }?.element
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

    /// A JSON boolean; `absent` for a missing or null value; `nil` for
    /// anything else, which makes the field unreadable.
    static func optionalBoolean(_ value: Any?, absent: Bool) -> Bool? {
        guard let value, !(value is NSNull) else { return absent }
        guard let n = value as? NSNumber, isBoolean(n) else { return nil }
        return n.boolValue
    }
}

extension AnthropicUsageParser.ResetValue {
    var date: Date? {
        if case .date(let date) = self { return date }
        return nil
    }
}

// MARK: - Judging kinds against a clock

/// The grant a chosen kind resolves to at the click, or why it does not.
enum AnthropicResetResolution: Equatable, Sendable {
    case grant(String)
    case blocked(ResetKind.Reason)
    /// The kind has no unexpired grant at all: it vanished.
    case absent
}

extension AnthropicResetGrants {
    /// The label of each kind. A model refill's carries the payload's own
    /// model name, never one written here.
    static func label(for key: ResetKind.Key, modelName: String?) -> String {
        switch key {
        case .full: return "Full reset"
        case .weekly: return "7-day reset"
        case .session: return "5-hour reset"
        case .other: return ResetKind.fallbackLabel
        case .modelRefill:
            guard let modelName else { return "Model reset" }
            let suffix = " reset"
            let name = Redactor.oneLine(modelName, maxLength: ResetKind.maxLabelLength - suffix.count)
            return name.isEmpty ? "Model reset" : name + suffix
        }
    }

    /// The model name a model refill is labelled with: the display name of
    /// the account's one model-scoped weekly window, or `nil` when there is
    /// none or more than one.
    static func modelName(from windows: [UsageWindow]) -> String? {
        let scoped = windows.filter { $0.isModelScoped && $0.durationSeconds == AnthropicUsageParser.weeklySeconds }
        return scoped.count == 1 ? scoped[0].label : nil
    }

    /// The account's kinds as a row shows them at `now`: one entry per kind
    /// with an unexpired grant, its count summed over those grants, spendable
    /// when one of them passes every condition. `nil` when the account holds
    /// no unexpired grant (or no readable block), so the row shows the plain
    /// count.
    func kinds(at now: Date, modelName: String?) -> [ResetKind]? {
        let live = unexpired(at: now)
        guard count != nil, !live.isEmpty else { return nil }
        var order: [ResetKind.Key] = []
        for grant in live where !order.contains(grant.kind) { order.append(grant.kind) }
        return order.map { key in
            let ofKind = live.filter { $0.kind == key }
            return ResetKind(
                key: key,
                label: Self.label(for: key, modelName: modelName),
                count: ofKind.reduce(0) { $0 + $1.resetsLeft },
                reason: reason(for: ofKind, at: now)
            )
        }
    }

    /// The grant a new attempt for `key` spends at `now`: `next_grant_id`
    /// when it is of that kind and spendable, else the spendable grant of
    /// that kind ending soonest. Never a grant of another kind, and never one
    /// that cannot be spent.
    func resolve(_ key: ResetKind.Key, at now: Date) -> AnthropicResetResolution {
        let ofKind = unexpired(at: now).filter { $0.kind == key }
        guard !ofKind.isEmpty else { return .absent }
        if let reason = reason(for: ofKind, at: now) { return .blocked(reason) }
        let spendable = ofKind.enumerated().filter { blocker($0.element, at: now) == nil }
        if let next = nextGrantID, spendable.contains(where: { $0.element.id == next }) {
            return .grant(next)
        }
        return AnthropicResetParser.soonestEnding(spendable).map { .grant($0.id) } ?? .absent
    }

    /// Grants whose end is after `now`: one that ends at or before the clock
    /// is out of both the count and the choice.
    private func unexpired(at now: Date) -> [AnthropicResetParser.Grant] {
        grants.filter { grant in grant.endsAt.map { $0 > now } ?? true }
    }

    /// `nil` when at least one grant of the kind can be spent. Otherwise the
    /// first reason that applies, in the fixed order: cooldown, none left,
    /// not started, paused or not usable now, usable only at a limit, nothing
    /// to give back.
    private func reason(for ofKind: [AnthropicResetParser.Grant], at now: Date) -> ResetKind.Reason? {
        if let cooldown = cooldownReason(at: now) { return cooldown }
        let holding = ofKind.filter { $0.resetsLeft > 0 }
        guard !holding.isEmpty else { return .noneLeft }
        let blockers = holding.map { blocker($0, at: now) }
        if blockers.contains(where: { $0 == nil }) { return nil }
        return blockers.compactMap { $0 }.min(by: Self.comesBefore)
    }

    /// Why one grant cannot be spent at `now`, in the fixed order.
    private func blocker(_ grant: AnthropicResetParser.Grant, at now: Date) -> ResetKind.Reason? {
        if let cooldown = cooldownReason(at: now) { return cooldown }
        if grant.resetsLeft == 0 { return .noneLeft }
        if let starts = grant.startsAt, starts > now { return .notStarted(startsAt: starts) }
        if grant.paused { return .paused }
        if !grant.usableNow { return .notUsableNow }
        // An unreadable `at_limit` leaves the counts and fails every spend.
        guard let atLimit else { return .notUsableNow }
        if grant.requiresLimit && !atLimit { return .usableOnlyAtLimit }
        if grant.nothingToGiveBack { return .nothingToGiveBack }
        return nil
    }

    /// A cooldown in force at `now`. An unreadable one fails every spend
    /// with no time to show.
    private func cooldownReason(at now: Date) -> ResetKind.Reason? {
        switch cooldown {
        case .absent: return nil
        case .malformed: return .cooldown(until: nil)
        case .date(let until): return until > now ? .cooldown(until: until) : nil
        }
    }

    /// The fixed reason order. Between two not-started grants the earlier
    /// start comes first, so the row names the soonest one.
    private static func comesBefore(_ a: ResetKind.Reason, _ b: ResetKind.Reason) -> Bool {
        if case .notStarted(let x) = a, case .notStarted(let y) = b { return x < y }
        return rank(a) < rank(b)
    }

    private static func rank(_ reason: ResetKind.Reason) -> Int {
        switch reason {
        case .cooldown: return 0
        case .noneLeft: return 1
        case .notStarted: return 2
        case .paused, .notUsableNow: return 3
        case .usableOnlyAtLimit: return 4
        case .nothingToGiveBack: return 5
        }
    }
}
