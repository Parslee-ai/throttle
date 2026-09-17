import Foundation

/// A plain HTTP response with the body already read into memory.
struct HTTPResponse: Sendable {
    let statusCode: Int
    /// Header names lower-cased so lookups are case-insensitive.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// The one network seam. Adapters and OAuth flows depend on this protocol so
/// tests can drive them with canned responses and count requests.
protocol HTTPClient: Sendable {
    /// Sends `request` without following redirects and returns the response.
    ///
    /// Implementations throw `UsageError.tooLarge` when the body exceeds
    /// `maxBodyBytes` and `UsageError.transport` for any URL loading failure.
    func send(_ request: URLRequest, maxBodyBytes: Int) async throws -> HTTPResponse
}

extension HTTPClient {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await send(request, maxBodyBytes: 256 * 1024)
    }
}

/// Production client. Redirects are never followed: a 3xx from a usage
/// endpoint means the request was bounced to a login page, and the caller
/// wants to see that, not the login page's HTML.
final class URLSessionHTTPClient: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    func send(_ request: URLRequest, maxBodyBytes: Int) async throws -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: self)
        } catch {
            throw UsageError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse("non-HTTP response")
        }
        if data.count > maxBodyBytes {
            throw UsageError.tooLarge
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String {
                headers[name.lowercased()] = text
            }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    /// Refuse every redirect so the caller sees the 3xx itself.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
