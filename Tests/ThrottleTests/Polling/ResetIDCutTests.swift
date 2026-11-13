import Foundation
import XCTest
@testable import Throttle

/// A provider's error text is cut to length on its way to the row and to
/// the diagnostics log. The attempt's ids must be gone before any cut: an id
/// that straddles a cut point no longer matches once half of it is gone, and
/// the half that stays would reach the screen or the disk.
final class ResetIDCutTests: XCTestCase {
    /// Ids with no long run of one character, so no stand-in on a written
    /// line (the URL's all-zero organization) can look like a piece of one.
    private static let organization = "c3a91f5e-7b2d-4e86-9f14-a2d6b8e0c537"
    private static let attempt = UUID(uuidString: "D84E2B17-6C9A-4F35-B1E8-5A7C3F92D06B")!
    private static let fragment = 8

    private struct Case {
        let status: Int
        let type: String
    }

    private static let cases = [
        Case(status: 403, type: "permission_error"),
        Case(status: 429, type: "rate_limit_error"),
        Case(status: 500, type: "api_error"),
    ]

    /// Each of the three ids at every offset where it straddles one of the
    /// cuts: the 300-character cap on the provider's message, the cap on the
    /// row's message (which adds its own words in front), and the
    /// 300-character cap on the logged body (which starts with the JSON
    /// around the message).
    func testNoPartOfAnIdSurvivesAnyCut() async throws {
        let ids = [Self.organization, ClaudeKindsFixture.refillGrant, Self.attempt.uuidString.lowercased()]
        var leaks: [String] = []
        var checked = 0
        for errorCase in Self.cases {
            let lead = #"{"type":"error","error":{"type":"\#(errorCase.type)","message":""#.count
            let rowLead = try await Self.rowLead(errorCase)
            for id in ids {
                var offsets = Set<Int>()
                for cut in [ResetMessages.maxLength, ResetMessages.maxLength - rowLead,
                            DiagnosticEvent.bodyPrefixLength - lead] where cut > 0 {
                    offsets.formUnion(max(0, cut - id.count)...cut)
                }
                for offset in offsets.sorted() {
                    leaks += try await check(errorCase, id: id, at: offset, every: ids)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 300)
        XCTAssertEqual(leaks, [], "\(leaks.count) leaks")
    }

    /// How many characters the row's message puts before the provider's.
    private static func rowLead(_ errorCase: Case) async throws -> Int {
        guard errorCase.status == 403 else { return 0 }
        let marker = "MARKER"
        let text = ResetMessages.notice(for: .forbidden(reason: marker), providerName: "Claude", now: ClaudeKindsFixture.start)?.text ?? ""
        let range = try XCTUnwrap(text.range(of: marker), "the row shows the provider's words")
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// Each place that holds a piece of an id, for one placement.
    private func check(_ errorCase: Case, id: String, at offset: Int, every ids: [String]) async throws -> [String] {
        let kinds = ClaudeKindsFixture(withDiagnostics: true)
        let account = try await kinds.fixture.addAccount(.anthropic, email: "fixture-cut")
        try kinds.enqueueReading()
        kinds.http.enqueue(status: 200, body: Data(#"{"organization":{"uuid":"\#(Self.organization)","organization_type":"claude_max"}}"#.utf8))
        await kinds.fixture.runFirstCycle(on: kinds.scheduler) { await kinds.scheduler.start() }
        await kinds.scheduler.stop()

        let pad = String(repeating: "w", count: offset)
        let others = ids.filter { $0 != id }.joined(separator: " ")
        let message = pad + id + " " + String(repeating: "t", count: 400) + " " + others
        let body = #"{"type":"error","error":{"type":"\#(errorCase.type)","message":"\#(message)"}}"#
        kinds.http.enqueue(status: errorCase.status, body: Data(body.utf8))
        try kinds.enqueueReading()
        let result = await kinds.scheduler.useReset(accountID: account.id, attemptID: Self.attempt, choice: .modelRefill)
        XCTAssertEqual(kinds.postRequests.count, 1, "HTTP \(errorCase.status): the reset was sent")

        let now = kinds.clock.now()
        let rows = [nil, "Testmodel reset"].compactMap {
            ResetMessages.notice(for: result, providerName: "Claude", now: now, kindLabel: $0)?.text
        }
        XCTAssertFalse(rows.isEmpty, "HTTP \(errorCase.status): the row has a message")
        let log = AppPaths(applicationSupportDirectory: kinds.fixture.directory).diagnosticsFile.lastPathComponent
        let logged = try XCTUnwrap(try kinds.writtenFiles().first { $0.name == log }?.text,
                                   "HTTP \(errorCase.status): the failure was logged")
        var leaks: [String] = []
        for (place, text) in rows.map({ ("the row", $0) }) + [("diagnostics.log", logged)] {
            for every in ids {
                let pieces = (0...(every.count - Self.fragment)).map { start in
                    let from = every.index(every.startIndex, offsetBy: start)
                    return String(every[from..<every.index(from, offsetBy: Self.fragment)])
                }
                if let piece = pieces.first(where: { text.localizedCaseInsensitiveContains($0) }) {
                    leaks.append("HTTP \(errorCase.status), \(id) at \(offset): \(place) holds \(piece)")
                }
            }
        }
        await kinds.cleanUp()
        return leaks
    }
}
