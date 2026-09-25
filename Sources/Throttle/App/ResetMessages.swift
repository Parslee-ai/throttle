import Foundation

/// The words a row shows for each reset result, and the per-account attempt
/// ids that make a retry safe. Provider-neutral: the provider appears only as
/// its product name.
enum ResetMessages {
    static let success = "Reset used — limits refreshed"
    static let nothingToReset = "Nothing to reset right now — your reset was not used"
    static let noResets = "No resets available"
    static let notAvailable = "Resets aren't available for this account right now"
    /// Longest message a row ever shows.
    static let maxLength = 300
    /// How long the success note stays before it fades.
    static let successLifetime: Duration = .seconds(4)

    /// The notice for a finished attempt, or `nil` when the row's own state
    /// already says everything (a needed sign-in) or nothing happened (a
    /// second click during a run).
    static func notice(for result: ResetResult, providerName: String, now: Date) -> ResetNotice? {
        switch result {
        case .outcome(.reset):
            return ResetNotice(success, kind: .success)
        case .outcome(.nothingToReset):
            return failure(nothingToReset)
        case .outcome(.noCredit):
            return failure(noResets)
        case .outcome(.cooldown(let until)):
            guard let until, until > now else { return failure(notAvailable) }
            return failure("Reset on cooldown until \(time(until, now: now))")
        case .outcome(.notAvailable), .unsupported:
            return failure(notAvailable)
        case .outcome(.unexpected), .unexpected:
            return failure("Unexpected answer from \(providerName)")
        case .rateLimited(let until):
            guard let until, until > now else {
                return failure("\(providerName) is limiting requests — try again later")
            }
            return failure("\(providerName) is limiting requests — try again at \(time(until, now: now))")
        case .forbidden(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return failure(trimmed.isEmpty ? "\(providerName) refused the reset" : trimmed)
        case .providerError(let status) where status >= 500:
            // A gateway can answer 5xx after the provider already spent, so
            // this never claims nothing changed; the retry reuses the attempt.
            return failure("\(providerName) had a problem (HTTP \(status)). Try again — a retry never spends a second reset.")
        case .providerError(let status):
            return failure("\(providerName) couldn't use the reset (HTTP \(status)). Nothing was changed.")
        case .unreachable:
            return failure("Couldn't reach \(providerName) — check your connection and try again")
        case .needsLogin, .alreadyRunning:
            return nil
        }
    }

    /// Redacted first, so a token cut in half by the cap cannot slip past
    /// the redactor; then every control character (newlines included)
    /// becomes a space, runs of spaces collapse, and the result is capped.
    static func sanitized(_ raw: String) -> String {
        let redacted = Redactor.redact(raw)
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

    private static func failure(_ text: String) -> ResetNotice {
        ResetNotice(sanitized(text), kind: .failure)
    }

    /// `14:05` within a day, the dated stamp beyond that.
    private static func time(_ date: Date, now: Date) -> String {
        date.timeIntervalSince(now) < 86_400 ? Formatting.clockTime(date) : Formatting.resetStamp(date)
    }
}

/// The attempt id each account's next reset request carries.
///
/// The provider treats a repeated attempt id as the same request, so reusing
/// one can never spend twice, while a fresh id after a reset that did land
/// would. The id is therefore kept, while the app stays open, after every
/// result that leaves it unknown whether the provider spent the reset: no
/// answer (couldn't reach, timed out), a 5xx (a gateway can answer 502 or 504
/// after the provider already spent), and a reply that could not be read.
/// Only a definitive answer (spent, nothing to reset, no credit, cooldown, not
/// available) or a client-side refusal (sign-in needed, forbidden, rate
/// limited, a 3xx or 4xx) ends the attempt, so the next click starts a new
/// one. Once an attempt has been ambiguous, only a definitive answer ends it:
/// a later refusal says the retry was not processed, not that the earlier
/// send was not.
struct ResetAttempts {
    private var pending: [UUID: UUID] = [:]
    /// Accounts whose pending attempt has had an ambiguous result.
    private var ambiguous: Set<UUID> = []

    /// The id for this account's next request: the unfinished attempt's, or
    /// a fresh one.
    mutating func attemptID(for accountID: UUID) -> UUID {
        if let id = pending[accountID] { return id }
        let id = UUID()
        pending[accountID] = id
        return id
    }

    /// Records how the attempt ended.
    mutating func finish(_ accountID: UUID, with result: ResetResult) {
        switch Self.ending(of: result) {
        case .definitive:
            forget(accountID)
        case .refused:
            if !ambiguous.contains(accountID) { forget(accountID) }
        case .ambiguous:
            ambiguous.insert(accountID)
        case .nothingHappened:
            break
        }
    }

    mutating func forget(_ accountID: UUID) {
        pending[accountID] = nil
        ambiguous.remove(accountID)
    }

    enum Ending: Equatable {
        /// The provider said what happened to this attempt.
        case definitive
        /// The request was turned away before it was processed.
        case refused
        /// The reset may or may not have been spent.
        case ambiguous
        /// Nothing was sent (a second click during a run).
        case nothingHappened
    }

    static func ending(of result: ResetResult) -> Ending {
        switch result {
        case .outcome(.reset), .outcome(.nothingToReset), .outcome(.noCredit),
             .outcome(.cooldown), .outcome(.notAvailable), .unsupported:
            return .definitive
        case .needsLogin, .forbidden, .rateLimited:
            return .refused
        case .providerError(let status):
            return (300..<500).contains(status) ? .refused : .ambiguous
        case .outcome(.unexpected), .unexpected, .unreachable:
            return .ambiguous
        case .alreadyRunning:
            return .nothingHappened
        }
    }
}
