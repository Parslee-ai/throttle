import Foundation
import XCTest
@testable import Throttle

/// A real `AppModel` over a `PollingFixture`: the fixture's store, cache,
/// scheduler, and mocks, with a status-cache file and a private
/// UserDefaults suite under the fixture's directory. Nothing touches the
/// user's Keychain, defaults, or network.
@MainActor
struct ModelHarness {
    let fixture: PollingFixture
    /// The scheduler the model drives: the fixture's unless one was given.
    let scheduler: PollScheduler
    let model: AppModel
    let persistence: StatusCachePersistence
    let defaultsSuite: String
    /// The success note fades only when the test opens this gate, so no
    /// assertion races a wall-clock lifetime. Its `waits` counts the notes
    /// that asked to fade.
    let successNoteFade: Gate

    /// `scheduler` replaces the fixture's own, for a test that needs other
    /// providers; it must share the fixture's store, cache, and clock.
    init(
        fixture: PollingFixture,
        scheduler: PollScheduler? = nil
    ) {
        self.fixture = fixture
        self.scheduler = scheduler ?? fixture.scheduler
        let paths = AppPaths(applicationSupportDirectory: fixture.directory)
        let suite = "ThrottleTests-\(UUID().uuidString)"
        defaultsSuite = suite
        persistence = StatusCachePersistence(paths: paths, clock: fixture.clock, minimumWriteInterval: 0)
        let diagnostics = Diagnostics(paths: paths)
        let fade = Gate()
        successNoteFade = fade
        model = AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: suite)!),
            store: fixture.store,
            cache: fixture.cache,
            persistence: persistence,
            scheduler: self.scheduler,
            registry: ProviderRegistry(diagnostics: diagnostics),
            diagnostics: diagnostics,
            successNoteExpiry: { await fade.wait() }
        )
    }

    var paths: AppPaths { AppPaths(applicationSupportDirectory: fixture.directory) }

    /// Starts the model (which runs the first poll cycle), runs that cycle
    /// to its end, and waits until every stored account has a status on the
    /// model. Leaves the clock 10 s on, short of the timer.
    func start(file: StaticString = #filePath, line: UInt = #line) async {
        await fixture.runFirstCycle(on: scheduler, file: file, line: line) { model.start() }
        let expected = await fixture.store.accounts().count
        await waitForModel("model shows every account", file: file, line: line) { model in
            model.accounts.count == expected && model.statuses.count == expected
        }
    }

    /// Stops the scheduler's timer so only explicit calls issue requests.
    func stopPolling() async {
        await scheduler.stop()
    }

    /// Waits for the model to publish a cache change that satisfies `check`.
    func waitForStatus(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: @escaping @Sendable @MainActor ([UUID: CachedStatus]) -> Bool
    ) async {
        await waitForModel(description, file: file, line: line) { check($0.statuses) }
    }

    /// Returns once the model satisfies `condition`, re-checked on each
    /// change to an observable property it reads.
    func waitForModel(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @Sendable @MainActor (AppModel) -> Bool
    ) async {
        let model = model
        await awaitEvent(description, file: file, line: line) { @MainActor in
            await observeUntil { condition(model) }
        }
    }

    func cleanUp() async {
        successNoteFade.open()
        await persistence.stop()
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        await scheduler.stop()
        await fixture.cleanUp()
    }
}
