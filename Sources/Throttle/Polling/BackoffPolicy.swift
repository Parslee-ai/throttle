import Foundation

/// Decides which accounts the scheduler must leave alone this cycle, and for
/// how long, based on what happened on previous attempts.
///
/// Two horizons exist, and a value type keeps both testable without a clock:
///
/// - **Provider-wide rate limit (ISC-99).** A 429 from Anthropic arms a horizon
///   for every Anthropic account, because the limit is on the caller, not the
///   account, and one more request from a sibling account only extends it. The
///   horizon is `Retry-After` when the provider sent one, otherwise 5 min
///   doubling on each consecutive 429 to a 60 min cap. A success from any
///   Anthropic account resets the doubling. OpenAI limits per account, so its
///   429 arms only the offending account's horizon, on the same schedule.
/// - **Per-account error backoff (ISC-100).** A 5xx, a transport failure, a
///   timeout, or an unusable payload arms a horizon for that account only:
///   60 s doubling on each consecutive failure to a 15 min cap, reset by the
///   next success.
///
/// `needsLogin` arms nothing: the account is retried each cycle so that a
/// re-login takes effect on the next pass, and the request is cheap.
struct BackoffPolicy: Hashable, Sendable {
    /// What a fetch attempt produced, in the terms the policy cares about.
    enum Outcome: Hashable, Sendable {
        case success
        /// The provider returned 429. `retryAfter` is its own hint, if any.
        case rateLimited(retryAfter: TimeInterval?)
        /// 5xx, network failure, timeout, or unusable response.
        case failure
        /// Auth rejected. No backoff, no reset.
        case needsLogin
    }

    /// Schedule for 429 without `Retry-After`: 5 min doubling to 60 min.
    static let rateLimitBase: TimeInterval = 300
    static let rateLimitCap: TimeInterval = 3_600
    /// Schedule for errors: 60 s doubling to 15 min.
    static let errorBase: TimeInterval = 60
    static let errorCap: TimeInterval = 900

    private var providerRateLimitUntil: [Provider: Date] = [:]
    private var providerRateLimitStreak: [Provider: Int] = [:]
    private var accountRateLimitUntil: [UUID: Date] = [:]
    private var accountRateLimitStreak: [UUID: Int] = [:]
    private var accountErrorUntil: [UUID: Date] = [:]
    private var accountErrorStreak: [UUID: Int] = [:]

    init() {}

    /// The time until which this account must not be fetched, or `nil` when a
    /// fetch is allowed now. Takes the latest of every horizon that applies.
    func shouldSkip(account: UUID, provider: Provider, now: Date) -> Date? {
        let horizons = [
            providerRateLimitUntil[provider],
            accountRateLimitUntil[account],
            accountErrorUntil[account],
        ].compactMap { $0 }.filter { $0 > now }
        return horizons.max()
    }

    /// The active rate-limit horizon for this account, if the reason it is
    /// skipped is a 429 rather than an error. Lets the cache show the row as
    /// rate limited rather than merely backed off.
    func rateLimitedUntil(account: UUID, provider: Provider, now: Date) -> Date? {
        let horizons = [
            providerRateLimitUntil[provider],
            accountRateLimitUntil[account],
        ].compactMap { $0 }.filter { $0 > now }
        return horizons.max()
    }

    /// Updates the horizons after an attempt. Returns the horizon the outcome
    /// armed, if any, so the caller can show it without a second lookup.
    @discardableResult
    mutating func record(outcome: Outcome, for account: UUID, provider: Provider, now: Date) -> Date? {
        switch outcome {
        case .success:
            providerRateLimitUntil[provider] = nil
            providerRateLimitStreak[provider] = nil
            accountRateLimitUntil[account] = nil
            accountRateLimitStreak[account] = nil
            accountErrorUntil[account] = nil
            accountErrorStreak[account] = nil
            return nil

        case .rateLimited(let retryAfter):
            switch Self.rateLimitScope(for: provider) {
            case .provider:
                let streak = (providerRateLimitStreak[provider] ?? 0) + 1
                providerRateLimitStreak[provider] = streak
                let until = now.addingTimeInterval(Self.rateLimitDelay(retryAfter: retryAfter, streak: streak))
                providerRateLimitUntil[provider] = until
                return until
            case .account:
                let streak = (accountRateLimitStreak[account] ?? 0) + 1
                accountRateLimitStreak[account] = streak
                let until = now.addingTimeInterval(Self.rateLimitDelay(retryAfter: retryAfter, streak: streak))
                accountRateLimitUntil[account] = until
                return until
            }

        case .failure:
            let streak = (accountErrorStreak[account] ?? 0) + 1
            accountErrorStreak[account] = streak
            let until = now.addingTimeInterval(Self.errorDelay(streak: streak))
            accountErrorUntil[account] = until
            return until

        case .needsLogin:
            return nil
        }
    }

    // MARK: Schedules

    private enum RateLimitScope {
        case provider
        case account
    }

    /// Anthropic rate limits the caller, so its 429 is provider-wide. OpenAI
    /// rate limits the account (ISC-99).
    private static func rateLimitScope(for provider: Provider) -> RateLimitScope {
        switch provider {
        case .anthropic: return .provider
        case .openai: return .account
        }
    }

    /// `Retry-After` wins when present (still capped, so a hostile header can
    /// not park an account for a day). Otherwise 5 min doubling per streak.
    static func rateLimitDelay(retryAfter: TimeInterval?, streak: Int) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            return min(retryAfter, rateLimitCap)
        }
        return doubling(base: rateLimitBase, cap: rateLimitCap, streak: streak)
    }

    /// 60 s doubling per streak to 15 min.
    static func errorDelay(streak: Int) -> TimeInterval {
        doubling(base: errorBase, cap: errorCap, streak: streak)
    }

    private static func doubling(base: TimeInterval, cap: TimeInterval, streak: Int) -> TimeInterval {
        let exponent = max(0, min(streak - 1, 16))
        return min(base * pow(2, Double(exponent)), cap)
    }
}
