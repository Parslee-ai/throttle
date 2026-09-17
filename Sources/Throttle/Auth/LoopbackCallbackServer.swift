import Foundation
import Network

/// The listener could not bind any of its preferred ports.
enum LoopbackError: Error, Equatable, Sendable {
    case portsBusy([UInt16])
}

/// The query parameters a provider sent to the redirect URI.
struct LoopbackCallback: Equatable, Sendable {
    let code: String
    let state: String?
}

/// A one-shot HTTP listener on `127.0.0.1` that receives an OAuth redirect.
///
/// It exists only for the duration of one login: `start()` binds the first
/// free port from `preferredPorts`, `waitForCode` returns the first callback
/// that carries a `code`, and the listener is torn down as soon as that
/// response has been sent (and never later than a few seconds after any
/// outcome, ISC-79). It binds the IPv4 loopback address only, never a
/// wildcard address (ISC-135), so nothing off the machine can reach it.
///
/// The HTTP handling is the minimum a browser redirect needs: read one request
/// head, answer with a small HTML page, close. Anything that is not a GET to
/// `path` with a `code` or `error` parameter gets a 400 and the listener keeps
/// waiting, so a stray `/favicon.ico` request cannot end the login.
actor LoopbackCallbackServer {
    /// How long after an outcome the listener may stay up at most, so that
    /// the browser can read its response before the socket closes.
    static let shutdownGrace: TimeInterval = 3

    private static let maximumRequestHeadBytes = 16 * 1024

    let preferredPorts: [UInt16]
    let path: String

    private let queue = DispatchQueue(label: "ai.parslee.throttle.loopback")
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var outcome: Result<LoopbackCallback, Error>?
    private var waiter: CheckedContinuation<LoopbackCallback, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    init(preferredPorts: [UInt16], path: String) {
        self.preferredPorts = preferredPorts
        self.path = path
    }

    /// The port the listener is bound to, once `start()` has succeeded.
    var port: UInt16? { boundPort }

    /// The local endpoint the listener was required to bind. Tests assert this
    /// is the IPv4 loopback address.
    var requiredLocalEndpoint: NWEndpoint? {
        listener?.parameters.requiredLocalEndpoint
    }

    // MARK: Lifecycle

    /// Binds the first free port in `preferredPorts` and returns it. Throws
    /// `LoopbackError.portsBusy` naming every port when none can be bound.
    @discardableResult
    func start() async throws -> UInt16 {
        if let boundPort { return boundPort }
        for port in preferredPorts {
            if let listener = try await bind(port: port) {
                self.listener = listener
                self.boundPort = port
                return port
            }
        }
        throw LoopbackError.portsBusy(preferredPorts)
    }

    /// Waits for the first callback carrying a `code`. Throws
    /// `LoginError.timeout` after `timeout`, `LoginError.providerDenied` when
    /// the provider redirected with an `error`, and `CancellationError` when
    /// the caller is cancelled or the server is stopped first. In every case
    /// the listener is stopped before this returns or shortly after.
    func waitForCode(timeout: TimeInterval) async throws -> LoopbackCallback {
        if let outcome {
            return try outcome.get()
        }
        precondition(waiter == nil, "LoopbackCallbackServer supports a single waiter")
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.finish(.failure(LoginError.timeout))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let outcome {
                    continuation.resume(with: outcome)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.finish(.failure(CancellationError())) }
        }
    }

    /// Tears the listener and every open connection down and returns once the
    /// port is released. Idempotent. A waiter still pending is resumed with
    /// `CancellationError`.
    func stop() async {
        if let waiter {
            self.waiter = nil
            outcome = outcome ?? .failure(CancellationError())
            waiter.resume(throwing: CancellationError())
        }
        await shutdown()
    }

    /// Closes the listener and waits (bounded) for Network.framework to report
    /// it cancelled, which is when the port is free again. Concurrent callers
    /// share one shutdown.
    private func shutdown() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        graceTask?.cancel()
        graceTask = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        if let listener {
            self.listener = nil
            listener.newConnectionHandler = nil
            shutdownTask = Task { await Self.cancelAndWait(listener) }
        }
        await shutdownTask?.value
    }

    private static func cancelAndWait(_ listener: NWListener) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                if case .cancelled = state, resumed.trySet() {
                    continuation.resume()
                }
            }
            listener.cancel()
            // Backstop so a missing state callback can never hang a login.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if resumed.trySet() { continuation.resume() }
            }
        }
    }

    // MARK: Binding

    /// Returns a ready listener on `port`, or `nil` when the port is in use.
    /// Any other failure is thrown.
    private func bind(port: UInt16) async throws -> NWListener? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters = NWParameters.tcp
        // SO_REUSEADDR: a connection from the previous login still in
        // TIME_WAIT must not make the port look busy. A socket another process
        // is listening on still does.
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)

        let ready: Bool = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.trySet() { continuation.resume(returning: true) }
                case .failed(let error):
                    listener.cancel()
                    if resumed.trySet() {
                        if Self.isAddressInUse(error) {
                            continuation.resume(returning: false)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                case .cancelled:
                    if resumed.trySet() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.start(queue: queue)
        }
        guard ready else { return nil }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.finish(.failure(LoginError.timeout)) }
            }
        }
        return listener
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .EADDRINUSE || code == .EACCES
        }
        return false
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.forget(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHead(on: connection, buffered: Data())
    }

    private func forget(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    private func receiveHead(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { await self?.didReceive(data, isComplete: isComplete, error: error, buffered: buffered, on: connection) }
        }
    }

    private func didReceive(_ data: Data?, isComplete: Bool, error: NWError?, buffered: Data, on connection: NWConnection) {
        guard error == nil else {
            connection.cancel()
            return
        }
        var head = buffered
        if let data { head.append(data) }

        if let terminator = head.range(of: Data("\r\n\r\n".utf8)) {
            handleRequest(head: head.subdata(in: head.startIndex..<terminator.lowerBound), on: connection)
        } else if head.count > Self.maximumRequestHeadBytes || isComplete {
            respond(on: connection, status: 400, body: Self.badRequestPage, thenFinish: nil)
        } else {
            receiveHead(on: connection, buffered: head)
        }
    }

    /// Parses the request line and answers it. Only a GET to `path` with a
    /// `code` (success) or `error` (denial) completes the wait.
    private func handleRequest(head: Data, on connection: NWConnection) {
        let text = String(decoding: head, as: UTF8.self)
        let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + String(parts[1])),
              components.path == path else {
            respond(on: connection, status: 400, body: Self.badRequestPage, thenFinish: nil)
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let code = value("code") {
            respond(on: connection, status: 200, body: Self.successPage,
                    thenFinish: .success(LoopbackCallback(code: code, state: value("state"))))
        } else if let error = value("error") {
            let description = value("error_description") ?? error
            respond(on: connection, status: 400, body: Self.deniedPage,
                    thenFinish: .failure(LoginError.providerDenied(Redactor.redact(description))))
        } else {
            respond(on: connection, status: 400, body: Self.badRequestPage, thenFinish: nil)
        }
    }

    /// Writes one HTTP/1.1 response and closes the connection. When `result`
    /// is given, the waiter is resumed right away (so the token exchange can
    /// start) and the listener is stopped once the response has been flushed.
    ///
    /// The connection leaves the `connections` map here: from this point it
    /// belongs to the send, so a `shutdown()` racing with it (a state mismatch
    /// found the instant the waiter resumes, say) cannot cut the response off
    /// and make the browser retry against a closed port.
    private func respond(on connection: NWConnection, status: Int, body: String, thenFinish result: Result<LoopbackCallback, Error>?) {
        let reason = status == 200 ? "OK" : "Bad Request"
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(payload)

        connections[ObjectIdentifier(connection)] = nil
        connection.stateUpdateHandler = nil
        if let result {
            deliver(result)
        }
        let queue = self.queue
        connection.send(content: response, isComplete: true, completion: .contentProcessed { [weak self] _ in
            // Let the browser read the page and close first; never wait longer
            // than the grace period.
            let closed = LockedFlag()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                if closed.trySet() { connection.cancel() }
            }
            queue.asyncAfter(deadline: .now() + Self.shutdownGrace) {
                if closed.trySet() { connection.cancel() }
            }
            if result != nil {
                Task { await self?.shutdown() }
            }
        })
    }

    /// Records the outcome and resumes the waiter. The listener is stopped by
    /// the response flush, or by the grace timer if that never happens.
    private func deliver(_ result: Result<LoopbackCallback, Error>) {
        guard outcome == nil else { return }
        outcome = result
        timeoutTask?.cancel()
        timeoutTask = nil
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        }
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.shutdownGrace))
            guard !Task.isCancelled else { return }
            await self?.shutdown()
        }
    }

    /// Ends the wait with `result` after the listener is down. Used for
    /// timeouts, cancellation, and listener failure, where there is no
    /// response to flush, so the caller can rebind the port immediately.
    private func finish(_ result: Result<LoopbackCallback, Error>) async {
        let pending = waiter
        waiter = nil
        if outcome == nil {
            outcome = result
        }
        await shutdown()
        pending?.resume(with: result)
    }

    // MARK: Pages

    private static let successPage = page(
        title: "Signed in to Throttle",
        message: "Signed in to Throttle. You can close this tab."
    )

    private static let deniedPage = page(
        title: "Sign-in not completed",
        message: "The sign-in was not completed. You can close this tab and try again from Throttle."
    )

    private static let badRequestPage = page(
        title: "Throttle",
        message: "Throttle did not receive a sign-in code. You can close this tab."
    )

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>\
        <style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;\
        justify-content:center;height:100vh;margin:0;color:#222;background:#fafafa}\
        @media(prefers-color-scheme:dark){body{color:#eee;background:#1c1c1e}}</style></head>\
        <body><p>\(message)</p></body></html>
        """
    }
}

/// A once-only flag for resuming a continuation from a callback that
/// Network.framework may invoke more than once.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns `true` the first time only.
    func trySet() -> Bool {
        lock.withLock {
            if isSet { return false }
            isSet = true
            return true
        }
    }
}
