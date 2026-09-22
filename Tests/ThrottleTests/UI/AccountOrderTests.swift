import XCTest
@testable import Throttle

/// One order for the detail window, the bar's number, and the rotation:
/// grouped by provider in `Provider.allCases` order, then by `sortIndex`.
@MainActor
final class AccountOrderTests: XCTestCase {
    /// anthropic 0, openai 1, anthropic 2, openai 3, as an older store would
    /// hold them after accounts were added in alternation.
    private func interleaved() -> [Account] {
        [
            UIFixtures.account("a0@example.com", provider: .anthropic, sortIndex: 0),
            UIFixtures.account("o1@example.com", provider: .openai, sortIndex: 1),
            UIFixtures.account("a2@example.com", provider: .anthropic, sortIndex: 2),
            UIFixtures.account("o3@example.com", provider: .openai, sortIndex: 3),
        ]
    }

    func testGroupsByProviderThenSortIndex() {
        let ordered = AccountOrder.grouped(interleaved())
        XCTAssertEqual(ordered.map(\.email), ["a0@example.com", "a2@example.com", "o1@example.com", "o3@example.com"])

        // Input order does not matter.
        let shuffled = AccountOrder.grouped(interleaved().reversed())
        XCTAssertEqual(shuffled.map(\.email), ordered.map(\.email))
    }

    func testTiesBreakByAddedAt() {
        let early = Account(provider: .openai, email: "early@example.com", sortIndex: 0, addedAt: Date(timeIntervalSince1970: 1))
        let late = Account(provider: .openai, email: "late@example.com", sortIndex: 0, addedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(AccountOrder.grouped([late, early]).map(\.email), ["early@example.com", "late@example.com"])
    }

    func testSectionsNumberAccountsAcrossTheWholeList() {
        let sections = AccountOrder.sections(interleaved())
        XCTAssertEqual(sections.map(\.provider), [.anthropic, .openai])
        XCTAssertEqual(sections[0].entries.map(\.number), [1, 2])
        XCTAssertEqual(sections[1].entries.map(\.number), [3, 4])
        XCTAssertEqual(sections[1].entries.map(\.account.email), ["o1@example.com", "o3@example.com"])

        let onlyCodex = AccountOrder.sections(interleaved().filter { $0.provider == .openai })
        XCTAssertEqual(onlyCodex.map(\.provider), [.openai], "an empty section is left out")
    }

    /// The number the popup prints beside an account is the number the bar
    /// prints while it shows that account, and the rotation walks 1…N.
    func testBarNumberMatchesPopupNumberThroughARotation() throws {
        let accounts = AccountOrder.grouped(interleaved())
        let popupNumbers = Dictionary(uniqueKeysWithValues: AccountOrder.sections(accounts)
            .flatMap(\.entries)
            .map { ($0.account.id, $0.number) })

        var statuses: [UUID: CachedStatus] = [:]
        for account in accounts {
            statuses[account.id] = UIFixtures.cached(for: account, windows: [UIFixtures.window("5h", label: "5h", used: 10)])
        }
        let rotation = RotationController(accounts: accounts, statuses: statuses)

        var seen: [Int] = []
        for _ in 0..<(accounts.count * 2) {
            let account = try XCTUnwrap(rotation.current)
            let number = try XCTUnwrap(rotation.currentNumber)
            let label = Formatting.barLabel(account: account, index: number, cached: rotation.statuses[account.id], now: UIFixtures.now)
            XCTAssertEqual(label.index, popupNumbers[account.id])
            XCTAssertTrue(label.plainText.hasPrefix("\(popupNumbers[account.id]!): "), label.plainText)
            XCTAssertEqual(AccountOrder.number(of: account.id, in: accounts), number)
            seen.append(number)
            rotation.tick()
        }
        XCTAssertEqual(seen, [1, 2, 3, 4, 1, 2, 3, 4], "rotation goes 1, 2, … N and wraps")
        XCTAssertEqual(
            accounts.map(\.email),
            ["a0@example.com", "a2@example.com", "o1@example.com", "o3@example.com"],
            "both Claude accounts come first"
        )
    }

    // MARK: Moves within a section

    /// Applies what `AccountStore.move(id:to:)` does, then renumbers.
    private func applyStoreMove(_ accounts: [Account], id: UUID, to index: Int) -> [Account] {
        var storage = accounts.sorted { $0.sortIndex < $1.sortIndex }
        let from = storage.firstIndex { $0.id == id }!
        let moved = storage.remove(at: from)
        storage.insert(moved, at: min(max(index, 0), storage.count))
        for position in storage.indices { storage[position].sortIndex = position }
        return storage
    }

    private func displayEmails(_ accounts: [Account]) -> [String] {
        AccountOrder.grouped(accounts).map(\.email)
    }

    func testMovingTheFirstCodexAccountUpStaysInItsSection() {
        let store = interleaved()
        let firstCodex = store[1]
        XCTAssertNil(
            AccountOrder.storeIndex(moving: firstCodex.id, toSectionPosition: -1, storeOrder: store),
            "already first in its section: nothing to do"
        )
        XCTAssertNil(AccountOrder.storeIndex(moving: firstCodex.id, toSectionPosition: 0, storeOrder: store))
    }

    func testMovingTheSecondCodexAccountUpSwapsWithinCodexOnly() throws {
        let store = interleaved()
        let secondCodex = store[3]
        let index = try XCTUnwrap(AccountOrder.storeIndex(moving: secondCodex.id, toSectionPosition: 0, storeOrder: store))
        let after = applyStoreMove(store, id: secondCodex.id, to: index)
        XCTAssertEqual(displayEmails(after), ["a0@example.com", "a2@example.com", "o3@example.com", "o1@example.com"])
    }

    func testMovingAClaudeAccountDownSwapsWithinClaudeOnly() throws {
        let store = interleaved()
        let firstClaude = store[0]
        let index = try XCTUnwrap(AccountOrder.storeIndex(moving: firstClaude.id, toSectionPosition: 1, storeOrder: store))
        let after = applyStoreMove(store, id: firstClaude.id, to: index)
        XCTAssertEqual(displayEmails(after), ["a2@example.com", "a0@example.com", "o1@example.com", "o3@example.com"])
        XCTAssertNil(
            AccountOrder.storeIndex(moving: store[2].id, toSectionPosition: 2, storeOrder: store),
            "moving the last Claude account down past the end is a no-op, not a jump into Codex"
        )
    }

    func testDragWithinALongerSection() throws {
        let store = [
            UIFixtures.account("a0@example.com", provider: .anthropic, sortIndex: 0),
            UIFixtures.account("o1@example.com", provider: .openai, sortIndex: 1),
            UIFixtures.account("a2@example.com", provider: .anthropic, sortIndex: 2),
            UIFixtures.account("o3@example.com", provider: .openai, sortIndex: 3),
            UIFixtures.account("a4@example.com", provider: .anthropic, sortIndex: 4),
        ]
        // a4 to the top of Claude.
        var index = try XCTUnwrap(AccountOrder.storeIndex(moving: store[4].id, toSectionPosition: 0, storeOrder: store))
        var after = applyStoreMove(store, id: store[4].id, to: index)
        XCTAssertEqual(displayEmails(after), ["a4@example.com", "a0@example.com", "a2@example.com", "o1@example.com", "o3@example.com"])

        // Then a4 to the bottom of Claude again.
        index = try XCTUnwrap(AccountOrder.storeIndex(moving: store[4].id, toSectionPosition: 2, storeOrder: after))
        after = applyStoreMove(after, id: store[4].id, to: index)
        XCTAssertEqual(displayEmails(after), ["a0@example.com", "a2@example.com", "a4@example.com", "o1@example.com", "o3@example.com"])
    }
}
