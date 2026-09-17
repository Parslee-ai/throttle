import Foundation
import Observation

/// Decides which account the menu bar shows right now (ISC-108, 109, 113).
///
/// It advances through `accounts` in the order it was given (the store's
/// `sortIndex` order) every `interval` seconds and wraps. It reads `statuses`
/// only: it holds no reference to the scheduler, the store, or a provider, so
/// no number of ticks can cause a network request (ISC-103). Hovering the bar
/// pauses it; when the hover ends the next tick advances as normal.
@MainActor
@Observable
final class RotationController {
    private(set) var accounts: [Account]
    var statuses: [UUID: CachedStatus]
    private(set) var index = 0
    /// True while the pointer is over the bar item. Ticks are ignored.
    var isPaused = false
    var interval: TimeInterval {
        didSet { if timer != nil { restartTimer() } }
    }

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        accounts: [Account] = [],
        statuses: [UUID: CachedStatus] = [:],
        interval: TimeInterval = AppSettings.defaultRotationInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.accounts = accounts
        self.statuses = statuses
        self.interval = interval
        self.sleep = sleep
    }

    /// The account on display, or `nil` with no accounts (ISC-112).
    var current: Account? {
        guard !accounts.isEmpty else { return nil }
        return accounts[min(index, accounts.count - 1)]
    }

    var currentStatus: CachedStatus? {
        current.flatMap { statuses[$0.id] }
    }

    /// Replaces the account list. The current account keeps its place when it
    /// still exists, so a removal elsewhere does not jump the display.
    func setAccounts(_ newAccounts: [Account]) {
        let currentID = current?.id
        accounts = newAccounts
        if let currentID, let position = newAccounts.firstIndex(where: { $0.id == currentID }) {
            index = position
        } else if index >= newAccounts.count {
            index = 0
        }
    }

    /// One rotation step. Ignored while paused.
    func tick() {
        guard !isPaused, accounts.count > 1 else { return }
        index = (index + 1) % accounts.count
    }

    func start() {
        guard timer == nil else { return }
        restartTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func restartTimer() {
        timer?.cancel()
        let interval = interval
        let sleep = sleep
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self else { return }
                self.tick()
            }
        }
    }
}
