import Foundation
@testable import Throttle

/// Scripted `HTTPClient` for the Anthropic adapter tests. Records every request
/// it receives and answers from a queue of canned results, in order.
final class AnthropicMockHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<HTTPResponse, Error>]
    private var recorded: [URLRequest] = []
    private var recordedLimits: [Int] = []

    init(_ results: [Result<HTTPResponse, Error>] = []) {
        self.queue = results
    }

    convenience init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.init([.success(HTTPResponse(statusCode: status, headers: Self.lowercased(headers), body: body))])
    }

    convenience init(throwing error: Error) {
        self.init([.failure(error)])
    }

    func enqueue(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        queue.append(.success(HTTPResponse(statusCode: status, headers: Self.lowercased(headers), body: body)))
    }

    func enqueue(error: Error) {
        lock.lock(); defer { lock.unlock() }
        queue.append(.failure(error))
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var maxBodyLimits: [Int] {
        lock.lock(); defer { lock.unlock() }
        return recordedLimits
    }

    func send(_ request: URLRequest, maxBodyBytes: Int) async throws -> HTTPResponse {
        guard let next = dequeue(recording: request, maxBodyBytes: maxBodyBytes) else {
            throw UsageError.invalidResponse("mock had no scripted response")
        }
        return try next.get()
    }

    private func dequeue(recording request: URLRequest, maxBodyBytes: Int) -> Result<HTTPResponse, Error>? {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        recordedLimits.append(maxBodyBytes)
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    private static func lowercased(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in headers { out[key.lowercased()] = value }
        return out
    }
}

/// Loads a captured payload from the test bundle. `Tests/Fixtures` is a
/// synchronized group on the test target, so every JSON file in it ships as a
/// resource. Reading the repository path instead would go through the host
/// app and trip a Files-and-Folders privacy prompt under `~/Documents`, which a
/// headless test run can never answer (the suite hung on exactly that).
enum AnthropicFixtures {
    static func data(_ name: String) throws -> Data {
        try TestFixtures.data(name)
    }
}

/// Token-shaped values are assembled at runtime so the repository's secret
/// scan does not trip on its own tests.
enum AnthropicSampleSecret {
    static let accessToken = "sk" + "-ant-oat01-TESTACCESSTOKEN0001"
    static let refreshToken = "sk" + "-ant-ort01-TESTREFRESHTOKEN0001"
    static let rotatedAccess = "sk" + "-ant-oat01-ROTATEDACCESS0002"
    static let rotatedRefresh = "sk" + "-ant-ort01-ROTATEDREFRESH0002"
}

extension Date {
    static func iso(_ text: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)!
    }
}
