import Foundation

/// One kind of banked limit reset an account holds, as its row shows it: a
/// full reset, a model refill, and so on.
///
/// Provider-neutral. An adapter sums its grants per kind and hands over only
/// what a row draws; no grant id, grant label or provider reason crosses the
/// seam. `key` is also how the owner's pick travels back: it names a kind,
/// never a grant, so it is safe to keep in the status cache, and the adapter
/// resolves it to a grant at the click.
struct ResetKind: Codable, Hashable, Sendable {
    /// Which kind this is. Case order is the fixed display order the row,
    /// the confirmation and VoiceOver all use.
    enum Key: String, Codable, CaseIterable, Comparable, Sendable {
        /// Clears every limit.
        case full
        /// Clears the 7-day limit.
        case weekly
        /// Clears the 5-hour limit.
        case session
        /// Refills one model's weekly limit.
        case modelRefill = "model_refill"
        /// A kind this build does not recognize. Still counted and spendable.
        case other

        static func < (lhs: Key, rhs: Key) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Why a kind cannot be spent right now. A closed set of plain reasons,
    /// so no provider reason code ever reaches the screen or the cache.
    enum Reason: Codable, Hashable, Sendable {
        /// Resets are cooling down. `until` is `nil` when no usable time is known.
        case cooldown(until: Date?)
        /// The provider lists the kind with none left.
        case noneLeft
        /// The kind's resets become usable at `startsAt`.
        case notStarted(startsAt: Date)
        case paused
        case notUsableNow
        /// Usable only while the account is at a limit.
        case usableOnlyAtLimit
        /// A model refill with no usage of that model to give back.
        case nothingToGiveBack
    }

    /// Longest label a kind carries.
    static let maxLabelLength = 40
    /// The label of a kind whose name is empty after cleaning.
    static let fallbackLabel = "Reset"

    let key: Key
    /// One line, redacted, at most `maxLabelLength` characters, never empty.
    let label: String
    /// Resets of this kind left, spendable now or not. Never negative.
    let count: Int
    /// `nil` when the kind can be spent right now.
    let reason: Reason?

    var isSpendable: Bool { reason == nil }

    /// Every label passes through here, from every adapter and from the
    /// status cache, so a hostile name is cleaned once for all of them. A
    /// kind with nothing left is never spendable: with no other reason
    /// given, it reads as none left.
    init(key: Key, label: String, count: Int, reason: Reason? = nil) {
        let cleaned = Redactor.oneLine(label, maxLength: Self.maxLabelLength)
        let count = max(0, count)
        self.key = key
        self.label = cleaned.isEmpty ? Self.fallbackLabel : cleaned
        self.count = count
        self.reason = reason ?? (count == 0 ? .noneLeft : nil)
    }

    private enum CodingKeys: String, CodingKey {
        case key, label, count, reason
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(Key.self, forKey: .key),
            label: try container.decode(String.self, forKey: .label),
            count: try container.decode(Int.self, forKey: .count),
            reason: try container.decodeIfPresent(Reason.self, forKey: .reason)
        )
    }
}
