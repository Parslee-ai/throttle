import XCTest
@testable import Throttle

/// The reset-kind shape that crosses from an adapter to the UI (ISC-467 to
/// ISC-470): only plain values, a label cleaned where every adapter's label
/// passes, a fixed order, and a total that is always the kinds' sum.
final class ResetKindTests: XCTestCase {
    private let readAt = Date(timeIntervalSince1970: 1_793_000_000)

    private func status(
        provider: Provider = .anthropic,
        credits: Int? = nil,
        kinds: [ResetKind]?,
        at date: Date? = nil
    ) -> AccountStatus {
        AccountStatus(
            accountID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            provider: provider,
            email: "fixture-kinds",
            windows: [UsageWindow(key: "7d", label: "Weekly", usedPercent: 30, resetsAt: nil, durationSeconds: 604_800)],
            fetchedAt: date ?? readAt,
            state: .ok,
            resetCreditsAvailable: credits,
            resetKinds: kinds
        )
    }

    // MARK: Shape (ISC-467)

    func testShapeHoldsOnlyKeyLabelCountAndReason() {
        let kind = ResetKind(key: .full, label: "Full reset", count: 2)
        XCTAssertEqual(Mirror(reflecting: kind).children.compactMap(\.label), ["key", "label", "count", "reason"])
        XCTAssertTrue(kind.isSpendable)
        XCTAssertFalse(ResetKind(key: .full, label: "Full reset", count: 2, reason: .paused).isSpendable)
    }

    func testShapeEncodesOnlyPlainValues() throws {
        let kind = ResetKind(key: .modelRefill, label: "Testmodel reset", count: 1, reason: .cooldown(until: readAt))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(kind)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["key", "label", "count", "reason"])
        XCTAssertEqual(object["key"] as? String, "model_refill")
    }

    func testShapeCodexStatusHasNoKindsAndEncodesNoKindsKey() throws {
        let codex = status(provider: .openai, credits: 2, kinds: nil)
        XCTAssertNil(codex.resetKinds)
        XCTAssertEqual(codex.resetCreditsAvailable, 2)
        let text = String(decoding: try JSONEncoder().encode(codex), as: UTF8.self)
        XCTAssertFalse(text.contains("resetKinds"), text)
        let decoded = try JSONDecoder().decode(AccountStatus.self, from: try JSONEncoder().encode(codex))
        XCTAssertNil(decoded.resetKinds)
        XCTAssertEqual(decoded, codex)
    }

    func testKeyOrderIsTheFixedDisplayOrder() {
        XCTAssertEqual(ResetKind.Key.allCases, [.full, .weekly, .session, .modelRefill, .other])
        XCTAssertEqual(ResetKind.Key.allCases.shuffled().sorted(), ResetKind.Key.allCases)
    }

    func testStatusListsKindsInTheFixedOrder() {
        let kinds = [
            ResetKind(key: .other, label: "", count: 1),
            ResetKind(key: .modelRefill, label: "Testmodel reset", count: 1),
            ResetKind(key: .session, label: "5-hour reset", count: 1),
            ResetKind(key: .full, label: "Full reset", count: 1),
            ResetKind(key: .weekly, label: "7-day reset", count: 1),
        ]
        XCTAssertEqual(status(kinds: kinds).resetKinds?.map(\.key), [.full, .weekly, .session, .modelRefill, .other])
    }

    // MARK: Total (ISC-468)

    func testTotalIsTheSumOfTheKindsWhateverCountIsPassed() {
        let kinds = [
            ResetKind(key: .full, label: "Full reset", count: 3),
            ResetKind(key: .modelRefill, label: "Testmodel reset", count: 1, reason: .usableOnlyAtLimit),
        ]
        XCTAssertEqual(status(credits: nil, kinds: kinds).resetCreditsAvailable, 4)
        XCTAssertEqual(status(credits: 9, kinds: kinds).resetCreditsAvailable, 4, "a stray count never disagrees with the kinds")
        XCTAssertEqual(status(credits: 5, kinds: []).resetCreditsAvailable, 0)
        XCTAssertEqual(status(credits: 5, kinds: nil).resetCreditsAvailable, 5)
        XCTAssertNil(status(credits: nil, kinds: nil).resetCreditsAvailable)
    }

    func testCountIsNeverNegativeAndNoneLeftIsNeverSpendable() {
        let negative = ResetKind(key: .full, label: "Full reset", count: -3)
        XCTAssertEqual(negative.count, 0)
        XCTAssertEqual(negative.reason, .noneLeft)
        XCTAssertEqual(ResetKind(key: .full, label: "Full reset", count: 0).reason, .noneLeft)
        XCTAssertEqual(ResetKind(key: .full, label: "Full reset", count: 0, reason: .cooldown(until: nil)).reason,
                       .cooldown(until: nil), "an earlier reason in the order is kept")
    }

    // MARK: Equality (ISC-469)

    func testUnchangedKindsGiveEqualStatusesApartFromTheReadTime() {
        let first = [
            ResetKind(key: .modelRefill, label: "Testmodel reset", count: 1),
            ResetKind(key: .full, label: "Full reset", count: 2),
        ]
        let a = status(kinds: first, at: readAt)
        let b = status(kinds: first.reversed(), at: readAt)
        XCTAssertEqual(a, b, "the same kinds in another order are the same status")
        XCTAssertEqual(a.hashValue, b.hashValue)
        let later = status(kinds: first, at: readAt.addingTimeInterval(300))
        XCTAssertEqual(later.resetKinds, a.resetKinds)
        XCTAssertEqual(later.resetCreditsAvailable, a.resetCreditsAvailable)
    }

    // MARK: Label cleaning (ISC-470)

    func testLabelSanitizedAtInit() {
        let token = "Bearer " + FakeToken.anthropicSecret
        let raw = "Test\nmodel\u{0007}\t\u{202E}reset " + token + " " + String(repeating: "x\n", count: 1_000)
        XCTAssertGreaterThanOrEqual(raw.count, 2_000)
        let label = ResetKind(key: .modelRefill, label: raw, count: 1).label
        XCTAssertLessThanOrEqual(label.count, ResetKind.maxLabelLength)
        XCTAssertEqual(ResetKind.maxLabelLength, 40)
        XCTAssertFalse(label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, label)
        XCTAssertFalse(label.contains("\n") || label.contains("\r"), label)
        XCTAssertFalse(label.contains(FakeToken.anthropicSecret), label)
        XCTAssertFalse(label.contains("sk-"), label)
        XCTAssertTrue(label.hasPrefix("Test model"), label)

        let longToken = ResetKind(key: .other, label: String(repeating: "a", count: 30) + " " + FakeToken.anthropicSecret, count: 1).label
        XCTAssertFalse(longToken.contains("sk-"), "redacted before the cap, so a cut token cannot slip through: \(longToken)")
    }

    func testLabelEmptyAfterCleaningReadsReset() {
        for raw in ["", "   ", "\n\t\r", "\u{0000}\u{0007}"] {
            XCTAssertEqual(ResetKind(key: .other, label: raw, count: 1).label, "Reset", raw.debugDescription)
        }
    }

    func testDecodingPassesThroughTheSameCleaning() throws {
        let json = #"{"key":"full","label":"Full\nreset","count":-2}"#
        let kind = try JSONDecoder().decode(ResetKind.self, from: Data(json.utf8))
        XCTAssertEqual(kind.label, "Full reset")
        XCTAssertEqual(kind.count, 0)
        XCTAssertEqual(kind.reason, .noneLeft)
    }

    func testEveryReasonRoundTrips() throws {
        let reasons: [ResetKind.Reason] = [
            .cooldown(until: readAt), .cooldown(until: nil), .noneLeft, .notStarted(startsAt: readAt),
            .paused, .notUsableNow, .usableOnlyAtLimit, .nothingToGiveBack,
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for reason in reasons {
            let kind = ResetKind(key: .weekly, label: "7-day reset", count: 1, reason: reason)
            XCTAssertEqual(try decoder.decode(ResetKind.self, from: try encoder.encode(kind)), kind)
        }
    }
}
