import Foundation
import XCTest
@testable import Throttle

/// Whatever an attempt ends with, the row's message promises a free retry
/// only while the row still holds a retryable attempt, and keeps that
/// promise for as long as it does. Every answer the
/// reset request can get is tried at three points in an attempt's life,
/// through the real Claude adapter, scheduler and model:
///
/// - the first send, which leaves the attempt open only on no definite answer;
/// - a retry inside the ten minutes, which ends it on any definite answer
///   or refusal;
/// - a retry sent at 9:50 and answered at 10:05, which ends it whatever the
///   answer, since its window is over.
@MainActor
final class ResetMessageEndingTests: XCTestCase {
    private enum Answer {
        case http([(Int, String)])
        case transportFailure
        case noAnswer

        var isNoAnswer: Bool {
            if case .noAnswer = self { return true }
            return false
        }

        /// Whether the row's words for this answer offer a free retry: no
        /// definite answer, a 5xx, or no answer at all.
        var offersRetry: Bool {
            switch self {
            case .http(let replies): replies.last.map { $0.0 >= 500 } ?? false
            case .transportFailure, .noAnswer: true
            }
        }
    }

    private static let permission = #"{"type":"error","error":{"type":"permission_error","message":"Not allowed"}}"#

    private static let answers: [(String, Answer)] = [
        ("reset", .http([(200, #"{"result":"reset"}"#)])),
        ("already used", .http([(200, #"{"result":"already_used"}"#)])),
        ("not limited", .http([(200, #"{"result":"not_limited"}"#)])),
        ("cooldown", .http([(200, #"{"result":"cooldown"}"#)])),
        ("ineligible", .http([(200, #"{"result":"ineligible"}"#)])),
        ("no grant", .http([(200, #"{"result":"ineligible","reason":"no_grant"}"#)])),
        ("unknown grant", .http([(200, #"{"result":"ineligible","reason":"unknown_grant"}"#)])),
        ("unavailable", .http([(200, #"{"result":"unavailable"}"#)])),
        ("unconfirmed", .http([(200, #"{"result":"reset_unconfirmed"}"#)])),
        ("unreadable 200", .http([(200, "not json")])),
        ("401 twice", .http([(401, "{}"), (401, "{}")])),
        ("403 permission", .http([(403, permission)])),
        ("403 twice", .http([(403, "{}"), (403, "{}")])),
        ("3xx twice", .http([(302, "{}"), (302, "{}")])),
        ("404", .http([(404, "{}")])),
        ("429", .http([(429, "{}")])),
        ("500", .http([(500, "{}")])),
        ("502", .http([(502, "{}")])),
        ("503", .http([(503, "{}")])),
        ("504", .http([(504, "{}")])),
        ("transport failure", .transportFailure),
        ("no answer", .noAnswer),
    ]

    private enum Point: CaseIterable {
        case firstSend, retryInsideWindow, retryAnsweredLate
    }

    func testAMessagePromisesAFreeRetryExactlyWhileTheAttemptIsOpen() async throws {
        var seen: [Point: (open: Int, closed: Int)] = [:]
        for point in Point.allCases {
            for (name, answer) in Self.answers {
                let row = try await run(answer, at: point)
                let label = "\(name), \(point)"
                // The flag, and either wording that offers the free retry.
                let text = row.notice?.text ?? ""
                let promises = row.notice?.promisesRetry == true
                    || text.contains("never spends a second reset")
                    || text.contains("check your connection and try again")
                if row.open {
                    XCTAssertEqual(promises, answer.offersRetry,
                                   "\(label): the attempt is open, so the row keeps the answer's own words; got \(text)")
                } else {
                    XCTAssertFalse(promises, "\(label): the attempt is closed, so the next click is a new attempt; got \(text)")
                    if answer.offersRetry {
                        XCTAssertEqual(text, "Unexpected answer from Claude", "\(label): ended with no definite answer")
                    }
                }
                var tally = seen[point] ?? (0, 0)
                if row.open { tally.open += 1 } else { tally.closed += 1 }
                seen[point] = tally
            }
        }
        // Every point ends some answers open and some closed, except a late
        // answer, which always closes.
        XCTAssertGreaterThan(seen[.firstSend]?.open ?? 0, 0)
        XCTAssertGreaterThan(seen[.firstSend]?.closed ?? 0, 0)
        XCTAssertGreaterThan(seen[.retryInsideWindow]?.open ?? 0, 0)
        XCTAssertGreaterThan(seen[.retryInsideWindow]?.closed ?? 0, 0)
        XCTAssertEqual(seen[.retryAnsweredLate]?.open, 0)
        XCTAssertEqual(seen[.retryAnsweredLate]?.closed, Self.answers.count)
    }

    /// One attempt that ends with `answer` at `point`: the row's message and
    /// whether its attempt is still open, by the model and the scheduler.
    private func run(_ answer: Answer, at point: Point) async throws -> (notice: ResetNotice?, open: Bool) {
        let kinds = ClaudeKindsFixture()
        let harness = ModelHarness(fixture: kinds.fixture, scheduler: kinds.scheduler)
        let account = try await kinds.fixture.addAccount(.anthropic, email: "fixture-ending")
        try kinds.enqueueReading()
        kinds.enqueueProfile()
        await harness.start()
        await harness.stopPolling()
        let model = harness.model
        let clock = kinds.clock
        let id = account.id

        let retrying = point != .firstSend
        if retrying {
            kinds.http.enqueue(status: 503, body: Data("{}".utf8))
            try kinds.enqueueReading()
            model.useReset(account, choice: .modelRefill)
            try await XCTUnwrap(model.resetTasks[id]).value
            XCTAssertEqual(model.resetGates[id], .retryOnly(kind: .modelRefill, label: "Testmodel reset"))
            await clock.advance(by: point == .retryAnsweredLate ? 590 : 300)
        }

        let postsBefore = kinds.postRequests.count
        let late = point == .retryAnsweredLate
        switch answer {
        case .http(let replies):
            for (status, body) in replies { kinds.http.enqueue(status: status, body: Data(body.utf8)) }
        case .transportFailure:
            kinds.http.enqueue(error: UsageError.transport(URLError(.notConnectedToInternet)))
        case .noAnswer:
            kinds.http.enqueue(status: 200, body: Data(#"{"result":"reset"}"#.utf8))
        }
        try kinds.enqueueReading()
        if late || answer.isNoAnswer { kinds.posts.hold() }
        model.useReset(account, choice: .modelRefill, retrying: retrying)
        let task = try XCTUnwrap(model.resetTasks[id], "the reset started")
        if late || answer.isNoAnswer {
            await waitUntil("the POST went out") { kinds.postRequests.count == postsBefore + 1 }
            if late { await clock.advance(by: 15) }
            if answer.isNoAnswer {
                // The send's own time limit runs out with no answer.
                await clock.advance(by: PollScheduler.resetTimeout)
            }
            kinds.posts.release()
        }
        await task.value
        await clock.settle()

        let state = await kinds.scheduler.resetAttemptState(for: id)
        let open: Bool
        if case .retryable = state { open = true } else { open = false }
        if case .retryOnly = model.resetGates[id] {
            XCTAssertTrue(open, "the row offers a retry only while the scheduler holds one")
        } else {
            XCTAssertFalse(open, "the scheduler holds a retry the row does not offer")
        }
        let notice = model.resetNotices[id]
        await kinds.cleanUp()
        await harness.cleanUp()
        return (notice, open)
    }
}
