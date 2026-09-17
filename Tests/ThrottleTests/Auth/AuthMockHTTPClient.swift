import Foundation
import Network
import XCTest
@testable import Throttle

/// Records every request the login flows send and replays scripted responses
/// in order. Running out of script throws, so a test cannot pass by accident
/// on an unexpected extra request.
final class AuthMockHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [Result<HTTPResponse, Error>]
    private(set) var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        scripted = responses.map { .success($0) }
    }

    init(results: [Result<HTTPResponse, Error>]) {
        scripted = results
    }

    func send(_ request: URLRequest, maxBodyBytes: Int) async throws -> HTTPResponse {
        try lock.withLock { () -> Result<HTTPResponse, Error> in
            requests.append(request)
            guard !scripted.isEmpty else {
                return .failure(UsageError.invalidResponse("mock: no scripted response for \(request.url?.absoluteString ?? "?")"))
            }
            return scripted.removeFirst()
        }.get()
    }

    /// The body of request `index` decoded as a form: pairs in wire order.
    func formFields(ofRequest index: Int) -> [(String, String)] {
        guard requests.indices.contains(index), let body = requests[index].httpBody else { return [] }
        return AuthTestSupport.parseForm(String(decoding: body, as: UTF8.self))
    }
}

enum AuthTestSupport {
    static func json(_ body: String) -> HTTPResponse {
        json(200, body)
    }

    static func json(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["content-type": "application/json"], body: Data(body.utf8))
    }

    /// Splits `a=b&c=d` into decoded pairs, preserving order.
    static func parseForm(_ body: String) -> [(String, String)] {
        body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            return (name, value)
        }
    }

    /// The query items of a URL as an ordered list of pairs.
    static func query(_ url: URL) -> [(String, String)] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }
    }

    static func queryValue(_ url: URL, _ name: String) -> String? {
        query(url).first(where: { $0.0 == name })?.1
    }

    /// Builds an unsigned compact JWT with the given payload.
    static func unsignedJWT(_ payload: [String: Any]) -> String {
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return [header, body].map(PKCE.base64URL).joined(separator: ".") + ".sig"
    }

    /// Whether a TCP port on 127.0.0.1 can be bound right now.
    static func isPortFree(_ port: UInt16) -> Bool {
        guard let held = HeldPort(port) else { return false }
        held.close()
        return true
    }

    /// Performs a plain GET against the loopback server the way a browser
    /// redirect would, and returns the status code and body.
    static func get(_ url: URL) async throws -> (status: Int, body: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, String(decoding: data, as: UTF8.self))
    }

    /// Waits up to `timeout` for `condition` to become true.
    static func eventually(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }
}

/// A BSD socket bound and listening on `127.0.0.1:<port>`, standing in for a
/// Codex CLI or another login that holds the port. `nil` when the port is
/// already taken by something else.
final class HeldPort: @unchecked Sendable {
    let port: UInt16
    private var fd: Int32

    init?(_ port: UInt16) {
        self.port = port
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // Like any real server socket: rebinding over a TIME_WAIT connection is
        // fine, but a second listener on the same port is not.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            return nil
        }
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

/// A `UsageProvider` whose `refresh` counts calls, optionally waits, and
/// returns a scripted result. `fetchStatus` is never expected to run.
final class AuthCountingProvider: UsageProvider, @unchecked Sendable {
    let provider: Provider
    private let lock = NSLock()
    private var count = 0
    var refreshDelay: Duration = .zero
    var refreshResult: Result<AccountCredential, Error>

    init(provider: Provider = .anthropic, refreshResult: Result<AccountCredential, Error>) {
        self.provider = provider
        self.refreshResult = refreshResult
    }

    var refreshCount: Int { lock.withLock { count } }

    func fetchStatus(account: Account, credential: AccountCredential) async throws -> AccountStatus {
        XCTFail("fetchStatus is not part of the refresh path")
        throw UsageError.invalidResponse("unexpected fetchStatus")
    }

    func refresh(credential: AccountCredential) async throws -> AccountCredential {
        lock.withLock { count += 1 }
        if refreshDelay > .zero {
            // A real refresh never observes cancellation; neither does this one.
            try? await Task.sleep(for: refreshDelay)
        }
        return try refreshResult.get()
    }
}
