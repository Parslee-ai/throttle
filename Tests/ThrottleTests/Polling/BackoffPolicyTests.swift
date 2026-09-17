import XCTest
@testable import Throttle

final class BackoffPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let a = UUID()
    private let b = UUID()

    private func horizon(_ policy: BackoffPolicy, _ account: UUID, _ provider: Provider, at: TimeInterval = 0) -> TimeInterval? {
        policy.shouldSkip(account: account, provider: provider, now: t0.addingTimeInterval(at))?.timeIntervalSince(t0)
    }

    // MARK: Anthropic 429 is provider-wide (ISC-99)

    func testAnthropic429HonoursRetryAfterForEveryAnthropicAccount() {
        var policy = BackoffPolicy()
        policy.record(outcome: .rateLimited(retryAfter: 600), for: a, provider: .anthropic, now: t0)
        XCTAssertEqual(horizon(policy, a, .anthropic), 600)
        XCTAssertEqual(horizon(policy, b, .anthropic), 600, "sibling Anthropic account shares the horizon")
        XCTAssertNil(horizon(policy, b, .openai), "OpenAI accounts are untouched")
        XCTAssertNil(horizon(policy, a, .anthropic, at: 600), "horizon is exclusive at its end")
    }

    func testAnthropic429WithoutRetryAfterDoublesFromFiveMinutesToOneHour() {
        var policy = BackoffPolicy()
        var expected: [TimeInterval] = []
        for streak in 1...6 {
            let now = t0.addingTimeInterval(Double(streak) * 10_000)
            let until = policy.record(outcome: .rateLimited(retryAfter: nil), for: a, provider: .anthropic, now: now)
            expected.append(until!.timeIntervalSince(now))
        }
        XCTAssertEqual(expected, [300, 600, 1_200, 2_400, 3_600, 3_600])
    }

    func testRetryAfterIsCappedAtOneHour() {
        var policy = BackoffPolicy()
        let until = policy.record(outcome: .rateLimited(retryAfter: 86_400), for: a, provider: .anthropic, now: t0)
        XCTAssertEqual(until?.timeIntervalSince(t0), 3_600)
    }

    func testSuccessResetsRateLimitDoubling() {
        var policy = BackoffPolicy()
        policy.record(outcome: .rateLimited(retryAfter: nil), for: a, provider: .anthropic, now: t0)
        policy.record(outcome: .rateLimited(retryAfter: nil), for: a, provider: .anthropic, now: t0)
        policy.record(outcome: .success, for: b, provider: .anthropic, now: t0)
        XCTAssertNil(horizon(policy, a, .anthropic), "a success from any Anthropic account clears the provider horizon")
        let until = policy.record(outcome: .rateLimited(retryAfter: nil), for: a, provider: .anthropic, now: t0)
        XCTAssertEqual(until?.timeIntervalSince(t0), 300, "doubling restarts from the base")
    }

    // MARK: OpenAI 429 is per account

    func testOpenAI429AffectsOnlyThatAccount() {
        var policy = BackoffPolicy()
        policy.record(outcome: .rateLimited(retryAfter: nil), for: a, provider: .openai, now: t0)
        XCTAssertEqual(horizon(policy, a, .openai), 300)
        XCTAssertNil(horizon(policy, b, .openai))
        XCTAssertNil(horizon(policy, b, .anthropic))
        XCTAssertNotNil(policy.rateLimitedUntil(account: a, provider: .openai, now: t0))
    }

    // MARK: 5xx and transport back off per account (ISC-100)

    func testErrorBackoffDoublesFromSixtySecondsToFifteenMinutes() {
        var policy = BackoffPolicy()
        var delays: [TimeInterval] = []
        for streak in 1...6 {
            let now = t0.addingTimeInterval(Double(streak) * 10_000)
            delays.append(policy.record(outcome: .failure, for: a, provider: .openai, now: now)!.timeIntervalSince(now))
        }
        XCTAssertEqual(delays, [60, 120, 240, 480, 900, 900])
        XCTAssertNil(horizon(policy, b, .openai), "error backoff never leaks to a sibling")
        XCTAssertNil(policy.rateLimitedUntil(account: a, provider: .openai, now: t0), "an error horizon is not a rate limit")
    }

    func testSuccessResetsErrorBackoff() {
        var policy = BackoffPolicy()
        policy.record(outcome: .failure, for: a, provider: .anthropic, now: t0)
        policy.record(outcome: .failure, for: a, provider: .anthropic, now: t0)
        policy.record(outcome: .success, for: a, provider: .anthropic, now: t0)
        XCTAssertNil(horizon(policy, a, .anthropic))
        let until = policy.record(outcome: .failure, for: a, provider: .anthropic, now: t0)
        XCTAssertEqual(until?.timeIntervalSince(t0), 60)
    }

    func testNeedsLoginArmsNothing() {
        var policy = BackoffPolicy()
        XCTAssertNil(policy.record(outcome: .needsLogin, for: a, provider: .anthropic, now: t0))
        XCTAssertNil(horizon(policy, a, .anthropic))
    }

    func testShouldSkipReturnsTheLatestApplicableHorizon() {
        var policy = BackoffPolicy()
        policy.record(outcome: .failure, for: a, provider: .anthropic, now: t0)                    // +60
        policy.record(outcome: .rateLimited(retryAfter: 900), for: b, provider: .anthropic, now: t0) // +900 provider-wide
        XCTAssertEqual(horizon(policy, a, .anthropic), 900)
    }

    // MARK: Provider horizons survive a relaunch (ISC-99)

    func testProviderHorizonsReportOnlyActiveProviderWideLimits() {
        var policy = BackoffPolicy()
        policy.record(outcome: .rateLimited(retryAfter: 900), for: a, provider: .anthropic, now: t0)
        policy.record(outcome: .rateLimited(retryAfter: 900), for: b, provider: .openai, now: t0)
        policy.record(outcome: .failure, for: b, provider: .anthropic, now: t0)

        XCTAssertEqual(policy.providerHorizons(now: t0), [.anthropic: t0.addingTimeInterval(900)],
                       "OpenAI limits per account and errors are per account; neither is provider-wide")
        XCTAssertEqual(policy.providerHorizons(now: t0.addingTimeInterval(900)), [:], "an elapsed horizon is not reported")
    }

    func testSeedRestoresFutureHorizonsAndIgnoresExpiredOnes() {
        var policy = BackoffPolicy()
        policy.seed(providerHorizons: [.anthropic: t0.addingTimeInterval(600), .openai: t0.addingTimeInterval(-1)], now: t0)

        XCTAssertEqual(horizon(policy, a, .anthropic), 600)
        XCTAssertEqual(horizon(policy, b, .anthropic), 600, "seeded horizon is provider-wide")
        XCTAssertEqual(policy.rateLimitedUntil(account: a, provider: .anthropic, now: t0), t0.addingTimeInterval(600),
                       "a seeded horizon shows as rate limited, not as an error")
        XCTAssertNil(horizon(policy, a, .openai), "the expired horizon was dropped")
        XCTAssertEqual(policy.providerHorizons(now: t0), [.anthropic: t0.addingTimeInterval(600)])
    }

    func testSeedNeverShortensAHorizonAlreadyKnown() {
        var policy = BackoffPolicy()
        policy.record(outcome: .rateLimited(retryAfter: 900), for: a, provider: .anthropic, now: t0)
        policy.seed(providerHorizons: [.anthropic: t0.addingTimeInterval(300)], now: t0)
        XCTAssertEqual(horizon(policy, a, .anthropic), 900)

        policy.seed(providerHorizons: [.anthropic: t0.addingTimeInterval(1_200)], now: t0)
        XCTAssertEqual(horizon(policy, a, .anthropic), 1_200, "a later horizon extends")
    }
}
