import Foundation

/// The words a row shows for each reset result, and the per-account attempt
/// ids that make a retry safe. Provider-neutral: the provider appears only as
/// its product name.
enum ResetMessages {
    static let success = "Reset used — limits refreshed"
    static let nothingToReset = "Nothing to reset right now — your reset was not used"
    static let noResets = "No resets available"
    static let notAvailable = "Resets aren't available for this account right now"
    static let needsFreshReading = "Getting the latest reset counts — try again in a moment"
    /// A kind line's reason when the provider lists the kind with none left.
    static let noneLeft = "None left"
    /// The Use reset button's reason when several kinds are all blocked.
    static let noKindSpendable = "No reset can be used right now"
    /// Every kind's reason while an earlier attempt waits for its retry.
    static let finishEarlierReset = "Finish the earlier reset first"
    /// Every kind's reason after an unsettled attempt closed, until the
    /// account's next successful reading.
    static let waitingForFreshReading = "Waiting for a fresh reading"
    /// Longest message a row ever shows.
    static let maxLength = 300
    /// How long the success note stays before it fades.
    static let successLifetime: Duration = .seconds(4)

    /// The notice for a finished attempt, or `nil` when the row's own state
    /// already says everything (a needed sign-in) or nothing happened (a
    /// second click during a run). `kindLabel` is the label of the kind the
    /// owner picked, when there was one; `otherKindSpendable` says another
    /// kind on the row can still be spent (`otherKindSpendable(_:besides:)`).
    static func notice(for result: ResetResult, providerName: String, now: Date, kindLabel: String? = nil,
                       otherKindSpendable: Bool = false) -> ResetNotice? {
        switch result {
        case .outcome(.reset):
            return ResetNotice(successText(kindLabel: kindLabel), kind: .success)
        case .outcome(.nothingToReset):
            return failure(nothingToReset)
        case .outcome(.noCredit):
            return failure(noResets)
        case .outcome(.cooldown(let until)):
            guard let until, until > now else { return failure(notAvailable) }
            return failure("Reset on cooldown until \(time(until, now: now))")
        case .outcome(.notAvailable), .unsupported:
            return failure(notAvailable)
        case .outcome(.blocked(let reason)):
            return failure(text(for: reason, kindLabel: kindLabel, now: now, otherKindSpendable: otherKindSpendable))
        case .outcome(.needsFreshReading):
            return failure(needsFreshReading)
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
            return failure("\(providerName) had a problem (HTTP \(status)). Try again — a retry never spends a second reset.",
                           promisesRetry: true)
        case .providerError(let status):
            return failure("\(providerName) couldn't use the reset (HTTP \(status)). Nothing was changed.")
        case .unreachable:
            return failure("Couldn't reach \(providerName) — check your connection and try again", promisesRetry: true)
        case .needsLogin, .alreadyRunning:
            return nil
        }
    }

    /// `Full reset used — limits refreshed`, or the plain success note when
    /// no kind was picked.
    static func successText(kindLabel: String?) -> String {
        guard let kindLabel else { return success }
        return sanitized("\(kindLabel) used — limits refreshed")
    }

    /// The reason a kind line gives on hover. It differs from `text(for:)`
    /// only for a kind with none left, whose line already reads 0: the line
    /// says "None left", while a refused click says "No resets available".
    static func lineReason(for reason: ResetKind.Reason, kindLabel: String?, now: Date) -> String {
        if case .noneLeft = reason { return noneLeft }
        return text(for: reason, kindLabel: kindLabel, now: now)
    }

    /// What VoiceOver announces for a result: the notice, led by the kind's
    /// label when the notice does not already name it, so a refusal is heard
    /// with the kind it was for.
    static func announcement(for notice: ResetNotice, kindLabel: String?) -> String {
        guard let kindLabel, !notice.text.hasPrefix(kindLabel) else { return notice.text }
        return "\(kindLabel): \(notice.text)"
    }

    /// The plain reason a kind cannot be spent right now. A model refill's
    /// reason names the model, which is its kind label without the trailing
    /// "reset". With none left, the kind is named when another kind can
    /// still be spent, so the row never says no resets beside one that works.
    static func text(for reason: ResetKind.Reason, kindLabel: String?, now: Date, otherKindSpendable: Bool = false) -> String {
        switch reason {
        case .cooldown(let until):
            guard let until, until > now else { return "On cooldown" }
            return "On cooldown until \(time(until, now: now))"
        case .noneLeft:
            guard otherKindSpendable, let kindLabel else { return noResets }
            return "No \(kindLabel) left"
        case .notStarted(let startsAt):
            return "Starts \(time(startsAt, now: now))"
        case .paused:
            return "Paused"
        case .notUsableNow:
            return "Not usable right now"
        case .usableOnlyAtLimit:
            return "Usable once you reach a limit"
        case .nothingToGiveBack:
            let model = modelName(fromKindLabel: kindLabel)
            return model.isEmpty ? "No usage to give back" : "No \(model) usage to give back"
        }
    }

    /// Whether the row lists a kind other than `key` that can be spent now.
    static func otherKindSpendable(_ kinds: [ResetKind]?, besides key: ResetKind.Key?) -> Bool {
        (kinds ?? []).contains { $0.key != key && $0.isSpendable }
    }

    /// A model refill's model name: its kind label without the trailing
    /// "reset". Empty when there is no label.
    static func modelName(fromKindLabel label: String?) -> String {
        guard let label else { return "" }
        let suffix = " reset"
        let trimmed = label.lowercased().hasSuffix(suffix) ? String(label.dropLast(suffix.count)) : label
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    /// One line, redacted, capped at `maxLength`.
    static func sanitized(_ raw: String) -> String {
        Redactor.oneLine(raw, maxLength: maxLength)
    }

    private static func failure(_ text: String, promisesRetry: Bool = false) -> ResetNotice {
        ResetNotice(sanitized(text), kind: .failure, promisesRetry: promisesRetry)
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
///
/// An attempt also keeps the kind it was started for. Its id is an
/// idempotency key only for that kind, so a click on another kind while it
/// is unfinished gets no id and sends nothing.
struct ResetAttempts {
    private struct Pending {
        let id: UUID
        let choice: ResetKind.Key?
    }

    private var pending: [UUID: Pending] = [:]
    /// Accounts whose pending attempt has had an ambiguous result.
    private var ambiguous: Set<UUID> = []

    /// The id for this account's next request: the unfinished attempt's, or
    /// a fresh one.
    mutating func attemptID(for accountID: UUID) -> UUID {
        if let attempt = pending[accountID] { return attempt.id }
        return start(accountID, choice: nil)
    }

    /// The id for a request spending `choice`: the unfinished attempt's when
    /// it was started for the same kind, a fresh one when nothing is
    /// unfinished, and `nil`, meaning send nothing, while an attempt for
    /// another kind is unfinished.
    mutating func attemptID(for accountID: UUID, choice: ResetKind.Key?) -> UUID? {
        guard let attempt = pending[accountID] else { return start(accountID, choice: choice) }
        return attempt.choice == choice ? attempt.id : nil
    }

    private mutating func start(_ accountID: UUID, choice: ResetKind.Key?) -> UUID {
        let id = UUID()
        pending[accountID] = Pending(id: id, choice: choice)
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

    typealias Ending = ResetAttemptEnding

    static func ending(of result: ResetResult) -> Ending {
        result.attemptEnding
    }

    /// The unfinished attempt's id when it was started for `choice`, without
    /// starting one: a retry never becomes a new attempt.
    func pendingID(for accountID: UUID, choice: ResetKind.Key?) -> UUID? {
        guard let attempt = pending[accountID], attempt.choice == choice else { return nil }
        return attempt.id
    }

    /// Takes the scheduler's word for an account with a retry window: its
    /// retryable attempt is the pending one, and anything else ends it.
    mutating func adopt(_ accountID: UUID, state: ResetAttemptState?) {
        guard case .retryable(let id, let choice, _) = state else {
            forget(accountID)
            return
        }
        if pending[accountID]?.id != id {
            pending[accountID] = Pending(id: id, choice: choice)
        }
        ambiguous.insert(accountID)
    }
}
