import Foundation
@testable import Throttle

/// Records every request the OpenAI adapter sends and replays scripted
/// responses in order. Runs out of script → throws, so a test cannot pass by
/// accident on an unexpected extra request.
final class OpenAIMockHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [Result<HTTPResponse, Error>]
    private(set) var requests: [URLRequest] = []
    private(set) var maxBodyBytesSeen: [Int] = []

    init(responses: [HTTPResponse]) {
        self.scripted = responses.map { .success($0) }
    }

    init(results: [Result<HTTPResponse, Error>]) {
        self.scripted = results
    }

    func send(_ request: URLRequest, maxBodyBytes: Int) async throws -> HTTPResponse {
        try record(request, maxBodyBytes: maxBodyBytes).get()
    }

    private func record(_ request: URLRequest, maxBodyBytes: Int) -> Result<HTTPResponse, Error> {
        lock.withLock {
            requests.append(request)
            maxBodyBytesSeen.append(maxBodyBytes)
            guard !scripted.isEmpty else {
                return .failure(UsageError.invalidResponse("mock: no scripted response for \(request.url?.absoluteString ?? "?")"))
            }
            return scripted.removeFirst()
        }
    }

}

extension HTTPResponse {
    static func response(_ status: Int, headers: [String: String] = [:], body: String = "") -> HTTPResponse {
        var lowered: [String: String] = [:]
        for (key, value) in headers { lowered[key.lowercased()] = value }
        return HTTPResponse(statusCode: status, headers: lowered, body: Data(body.utf8))
    }

    static func json(_ body: String) -> HTTPResponse {
        json(200, body)
    }

    static func json(_ status: Int, _ body: String) -> HTTPResponse {
        response(status, headers: ["Content-Type": "application/json"], body: body)
    }
}

enum OpenAIFixtures {
    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenAI/
            .deletingLastPathComponent()   // ThrottleTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static var openAISourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Throttle/Providers/OpenAI", isDirectory: true)
    }

    static func whamUsage() throws -> Data {
        try Data(contentsOf: fixturesDirectory.appendingPathComponent("wham-usage.json"))
    }

    /// A payload with both primary windows populated and no extra lanes.
    static func synthetic(primarySeconds: Int?, secondarySeconds: Int?, additional: String = "[]") -> String {
        func window(_ seconds: Int?, used: Double, resetAt: Int) -> String {
            guard let seconds else { return "null" }
            return """
            {"used_percent": \(used), "limit_window_seconds": \(seconds), "reset_after_seconds": 100, "reset_at": \(resetAt)}
            """
        }
        return """
        {
          "account_id": "acct-1",
          "email": "someone@example.com",
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": \(window(primarySeconds, used: 12.5, resetAt: 1_700_000_000)),
            "secondary_window": \(window(secondarySeconds, used: 80, resetAt: 1_700_500_000))
          },
          "additional_rate_limits": \(additional),
          "credits": {"has_credits": false},
          "rate_limit_reset_credits": {"available_count": 1}
        }
        """
    }

    /// Builds an unsigned compact JWT with the given payload object.
    static func unsignedJWT(payload: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let body = try JSONSerialization.data(withJSONObject: payload)
        return [header, body].map(base64URL).joined(separator: ".") + ".sig"
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static let account = Account(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        provider: .openai,
        email: "stored@example.com",
        sortIndex: 0
    )
}
