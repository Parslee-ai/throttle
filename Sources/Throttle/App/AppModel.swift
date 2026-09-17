import AppKit
import Foundation
import Observation
import ServiceManagement

/// `TokenRefresher` is the production credential resolver. The conformance
/// lives here, at the composition root, so `Auth/` stays independent of the
/// scheduler's protocol.
extension TokenRefresher: CredentialResolving {}

/// One login in progress, driven by `AppModel` and drawn by `LoginSheet`.
@MainActor
@Observable
final class LoginFlow: Identifiable {
    enum Phase: Equatable {
        /// Preparing the session (binding the loopback port).
        case starting
        /// The browser is open; waiting for the redirect.
        case waitingForBrowser
        /// Manual mode: waiting for the user to paste the code.
        case awaitingCode
        /// Exchanging the code for tokens.
        case exchanging
        /// Finished with a user-facing, redacted message.
        case failed(String)
    }

    let id = UUID()
    let provider: Provider
    let mode: LoginMode
    /// When set, the login refreshes this account's credential in place.
    let replacing: Account?
    var phase: Phase = .starting
    var pastedCode = ""
    var authorizeURL: URL?

    @ObservationIgnored fileprivate var codeContinuation: CheckedContinuation<String, any Error>?
    @ObservationIgnored fileprivate var task: Task<Void, Never>?

    init(provider: Provider, mode: LoginMode, replacing: Account?) {
        self.provider = provider
        self.mode = mode
        self.replacing = replacing
    }

    /// Hands the pasted code to the waiting flow.
    func submitCode() {
        guard let continuation = codeContinuation else { return }
        codeContinuation = nil
        phase = .exchanging
        continuation.resume(returning: pastedCode)
    }

    /// Abandons the login. Cancelling the task tears the loopback listener down.
    func cancel() {
        if let continuation = codeContinuation {
            codeContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        task?.cancel()
    }
}

/// The composition root: owns the store, the cache, the scheduler, and the
/// settings, and publishes the two things every view reads: `accounts` in
/// display order and `statuses` by account id.
///
/// Views never touch the store or the scheduler directly. Every mutation goes
/// through a method here, and every error it produces is redacted before it
/// becomes `lastError`.
@MainActor
@Observable
final class AppModel {
    private(set) var accounts: [Account] = []
    private(set) var statuses: [UUID: CachedStatus] = [:]
    /// The newest successful fetch across all accounts, for the footer.
    private(set) var lastUpdated: Date?
    /// A redacted, user-facing description of the last failure. Views show it
    /// once and the user can dismiss it.
    var lastError: String?
    /// The login the sheet is showing, if any.
    var activeLogin: LoginFlow?
    /// Whether macOS will launch Throttle at login (ISC-127).
    private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered

    let settings: AppSettings
    let rotation: RotationController

    @ObservationIgnored private let store: AccountStore
    @ObservationIgnored private let cache: StatusCache
    @ObservationIgnored private let persistence: StatusCachePersistence
    @ObservationIgnored private let scheduler: PollScheduler
    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored private let diagnostics: Diagnostics
    @ObservationIgnored private let httpClient = URLSessionHTTPClient()
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let paths = AppPaths.standard
        let store = AccountStore(credentials: KeychainStore(), paths: paths)
        let clock = SystemClock()
        let pollSettings = settings.pollSettings
        let cache = StatusCache(clock: clock, staleAfter: pollSettings.staleAfter)
        let diagnostics = Diagnostics(paths: paths)
        let registry = ProviderRegistry(client: httpClient, diagnostics: diagnostics)
        self.store = store
        self.cache = cache
        self.registry = registry
        self.diagnostics = diagnostics
        self.persistence = StatusCachePersistence(paths: paths, clock: clock)
        self.scheduler = PollScheduler(
            store: store,
            providers: registry.usageProviders,
            resolver: TokenRefresher(),
            cache: cache,
            settings: pollSettings,
            clock: clock,
            backoffPersistence: BackoffPersistence(paths: paths),
            diagnostics: diagnostics
        )
        self.rotation = RotationController(interval: settings.rotationInterval)
    }

    // MARK: Lifecycle

    /// Loads the accounts, starts polling, and starts publishing cache
    /// updates. Safe to call once; later calls are ignored.
    func start() {
        guard !started else { return }
        started = true
        refreshLaunchAtLoginStatus()
        rotation.start()
        let scheduler = scheduler
        let cache = cache
        let persistence = persistence
        Task {
            await self.loadAccounts()
            await self.seedCache()
            await persistence.observe(cache)
            await scheduler.observeSleepWake()
            await scheduler.start()
        }
        updatesTask = Task { [weak self] in
            for await snapshot in await cache.updates() {
                guard let self else { return }
                self.apply(snapshot: snapshot)
            }
        }
    }

    private func loadAccounts() async {
        do {
            try await store.load()
            await publishAccounts()
        } catch {
            report(error, context: "Could not read the account list")
        }
    }

    /// Restores the previous run's last known status for every account that
    /// still exists (ISC-90). Entries for removed accounts are dropped.
    private func seedCache() async {
        let known = Set(accounts.map(\.id))
        let persisted = await persistence.load().filter { known.contains($0.key) }
        guard !persisted.isEmpty else { return }
        await cache.seed(from: persisted)
    }

    private func publishAccounts() async {
        let list = await store.accounts()
        accounts = list
        rotation.setAccounts(list)
    }

    private func apply(snapshot: [UUID: CachedStatus]) {
        statuses = snapshot
        rotation.statuses = snapshot
        lastUpdated = snapshot.values
            .filter { $0.lastGoodWindows != nil }
            .map(\.status.fetchedAt)
            .max()
        adoptProviderEmails(from: snapshot)
        adoptPlanLabels(from: snapshot)
    }

    /// The plan badge follows what the usage payload reports (ISC-74), so a
    /// plan change shows up without a re-login.
    private func adoptPlanLabels(from snapshot: [UUID: CachedStatus]) {
        for account in accounts {
            guard let plan = snapshot[account.id]?.status.planLabel, !plan.isEmpty,
                  plan != settings.planLabel(for: account.id) else { continue }
            settings.setPlanLabel(plan, for: account.id)
        }
    }

    /// An imported account starts life labelled by its source tool; once a
    /// fetch returns the real email the row adopts it.
    private func adoptProviderEmails(from snapshot: [UUID: CachedStatus]) {
        for account in accounts {
            guard let entry = snapshot[account.id], entry.status.state == .ok else { continue }
            let email = entry.status.email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty, email != account.email, email.contains("@") else { continue }
            Task {
                try? await store.updateEmail(id: account.id, email: email)
                await publishAccounts()
            }
        }
    }

    // MARK: Settings

    /// Pushes the current settings into the scheduler and the rotation.
    func applySettings() {
        rotation.interval = settings.rotationInterval
        let pollSettings = settings.pollSettings
        Task { await scheduler.update(settings: pollSettings) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
        } catch {
            report(error, context: enabled ? "Could not enable launch at login" : "Could not disable launch at login")
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    // MARK: Accounts

    func refreshAll() {
        Task { await scheduler.refreshNow() }
    }

    /// The scheduler refreshes in whole cycles; a per-row refresh runs one now,
    /// which still honours single-flight and any active backoff (ISC-101).
    func refresh(_ account: Account) {
        refreshAll()
    }

    /// The user's override for a provider throttle: clears the rate-limit
    /// horizon for the account's provider and fetches now.
    func retryProvider(for account: Account) {
        Task { await scheduler.retryProvider(account.provider) }
    }

    /// Shows `diagnostics.log` in Finder, creating an empty file first if no
    /// event has been written yet.
    func revealDiagnosticsLog() {
        let diagnostics = diagnostics
        Task {
            await diagnostics.ensureFileExists()
            NSWorkspace.shared.activateFileViewerSelecting([diagnostics.fileURL])
        }
    }

    func remove(_ account: Account) {
        Task {
            do {
                try await store.remove(id: account.id)
                settings.removeMeta(for: account.id)
                await publishAccounts()
                await cache.retain(accountIDs: Set(accounts.map(\.id)))
            } catch {
                report(error, context: "Could not remove the account")
            }
        }
    }

    func moveUp(_ account: Account) {
        Task {
            do {
                try await store.moveUp(id: account.id)
                await publishAccounts()
            } catch {
                report(error, context: "Could not reorder the accounts")
            }
        }
    }

    func moveDown(_ account: Account) {
        Task {
            do {
                try await store.moveDown(id: account.id)
                await publishAccounts()
            } catch {
                report(error, context: "Could not reorder the accounts")
            }
        }
    }

    /// Moves an account to a position in display order and persists the new
    /// order (ISC-92).
    func move(id: UUID, to index: Int) {
        Task {
            do {
                try await store.move(id: id, to: index)
                await publishAccounts()
            } catch {
                report(error, context: "Could not reorder the accounts")
            }
        }
    }

    /// A list drag: `source` and `destination` in SwiftUI's `onMove` terms,
    /// where the destination is an insertion point in the pre-move list.
    func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first, accounts.indices.contains(from) else { return }
        let target = from < destination ? destination - 1 : destination
        guard target != from else { return }
        move(id: accounts[from].id, to: target)
    }

    func planLabel(for account: Account) -> String? {
        settings.planLabel(for: account.id)
    }

    // MARK: Login

    /// Starts a new-account login and shows the sheet.
    func addAccount(provider: Provider, mode: LoginMode) {
        startLogin(provider: provider, mode: mode, replacing: nil)
    }

    /// Re-runs the provider's login for an existing account (ISC-121). The
    /// account keeps its id and position whatever email the provider reports.
    func reLogin(_ account: Account, mode: LoginMode = .loopback) {
        startLogin(provider: account.provider, mode: mode, replacing: account)
    }

    private func startLogin(provider: Provider, mode: LoginMode, replacing: Account?) {
        activeLogin?.cancel()
        let flow = LoginFlow(provider: provider, mode: mode, replacing: replacing)
        activeLogin = flow
        flow.task = Task { [weak self] in
            await self?.run(flow)
        }
    }

    private func run(_ flow: LoginFlow) async {
        do {
            let session = try await login(for: flow.provider).begin(mode: flow.mode)
            try Task.checkCancellation()
            flow.authorizeURL = session.authorizeURL
            NSWorkspace.shared.open(session.authorizeURL)

            let result: LoginResult
            if session.expectsManualCode {
                flow.phase = .awaitingCode
                let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                    flow.codeContinuation = continuation
                }
                flow.phase = .exchanging
                result = try await session.completion(code)
            } else {
                flow.phase = .waitingForBrowser
                result = try await session.completion(nil)
            }
            try Task.checkCancellation()
            try await store(result, for: flow)
            if activeLogin === flow { activeLogin = nil }
        } catch is CancellationError {
            if activeLogin === flow { activeLogin = nil }
        } catch {
            flow.phase = .failed(Self.message(for: error))
        }
    }

    private func login(for provider: Provider) -> any OAuthLogin {
        registry.login(for: provider, client: httpClient)
    }

    /// Persists a finished login. A new login dedupes by provider + email
    /// (ISC-93). A re-login keeps the same account even when the provider now
    /// reports a different email.
    private func store(_ result: LoginResult, for flow: LoginFlow) async throws {
        let account: Account
        if let existing = flow.replacing,
           existing.email.caseInsensitiveCompare(result.email) != .orderedSame {
            try await store.updateCredential(result.credential, for: existing.id)
            try await store.updateEmail(id: existing.id, email: result.email)
            account = existing
        } else {
            account = try await store.add(provider: flow.provider, email: result.email, credential: result.credential)
        }
        if let plan = result.planLabel, !plan.isEmpty {
            settings.setPlanLabel(plan, for: account.id)
        }
        await publishAccounts()
        await scheduler.refreshNow()
    }

    // MARK: Import

    /// Reads the other tool's login now. Called only from the import action,
    /// never at launch (ISC-137).
    func importCandidates(for provider: Provider) -> [ImportCandidate] {
        registry.importCandidates(for: provider)
    }

    /// Whether the provider's import source could exist on this Mac. At most a
    /// file-existence check; nothing is read until the user imports.
    func importSourceExists(for provider: Provider) -> Bool {
        registry.importSourceExists(for: provider)
    }

    func importAccount(_ candidate: ImportCandidate) {
        Task {
            do {
                let account = try await store.add(
                    provider: candidate.provider,
                    email: candidate.label,
                    credential: candidate.credential
                )
                _ = account
                await publishAccounts()
                await scheduler.refreshNow()
            } catch {
                report(error, context: "Could not import the account")
            }
        }
    }

    // MARK: Errors

    private func report(_ error: any Error, context: String) {
        lastError = Redactor.redact("\(context): \(Self.message(for: error))")
    }

    /// A short, redacted, user-facing message for any error.
    static func message(for error: any Error) -> String {
        let raw: String
        switch error {
        case let login as LoginError:
            raw = login.errorDescription ?? "The sign-in failed."
        case let described as any CustomStringConvertible:
            raw = described.description
        case let localized as any LocalizedError:
            raw = localized.errorDescription ?? localized.localizedDescription
        default:
            raw = error.localizedDescription
        }
        return Redactor.redact(raw)
    }
}
