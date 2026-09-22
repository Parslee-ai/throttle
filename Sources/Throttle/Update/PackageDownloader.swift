import Foundation

/// Fetches a release package to disk. A protocol so the controller's tests can
/// hand back a file without touching the network.
protocol PackageDownloading: Sendable {
    /// Downloads `asset` into `directory` as `asset.name` and returns the file.
    /// The file on return holds exactly `asset.size` bytes.
    func download(_ asset: ReleaseAsset, into directory: URL) async throws -> URL
}

/// Production downloader.
///
/// A release package URL answers with a redirect to GitHub's asset storage, so
/// unlike `URLSessionHTTPClient` this session follows redirects, but only over
/// HTTPS and only to the hosts in `allowedHosts`. The session is ephemeral and
/// sends no cookies and no credentials.
final class PackageDownloader: NSObject, PackageDownloading, URLSessionTaskDelegate, @unchecked Sendable {
    /// The release download host and the two hosts it redirects package
    /// downloads to. Bare host names: the scheme is checked separately.
    static let allowedHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    private let session: URLSession
    private let maxBytes: Int

    /// `configuration` is injectable so tests can install a stub
    /// `URLProtocol`; production uses the ephemeral default.
    init(configuration: URLSessionConfiguration = .ephemeral, maxBytes: Int = ReleaseFeed.maxPackageBytes) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        self.maxBytes = maxBytes
        super.init()
    }

    /// Whether a URL is somewhere a package download may go.
    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    func download(_ asset: ReleaseAsset, into directory: URL) async throws -> URL {
        guard Self.isAllowed(asset.downloadURL) else {
            throw UpdateError.download("the package address is not an approved download host")
        }
        guard asset.size > 0, asset.size <= maxBytes else {
            throw UpdateError.download("the package is larger than Throttle accepts")
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(asset.name, isDirectory: false)
        let partial = directory.appendingPathComponent(asset.name + ".partial", isDirectory: false)
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateError.download("Throttle couldn't create a file in its updates folder")
        }

        var request = URLRequest(url: asset.downloadURL)
        request.httpShouldHandleCookies = false
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        do {
            let written = try await stream(request, to: partial, limit: asset.size)
            guard written == asset.size else {
                throw UpdateError.download("received \(written) bytes but the release lists \(asset.size)")
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: partial, to: destination)
            return destination
        } catch let error as UpdateError {
            try? fm.removeItem(at: partial)
            throw error
        } catch {
            try? fm.removeItem(at: partial)
            throw UpdateError.download(error.localizedDescription)
        }
    }

    /// Streams the response body into `file`, refusing to write more than
    /// `limit` bytes. Returns the number of bytes written.
    private func stream(_ request: URLRequest, to file: URL, limit: Int) async throws -> Int {
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.download("the server's answer was not an HTTP response")
        }
        guard Self.isAllowed(http.url) else {
            throw UpdateError.download("the package was served from an unapproved host")
        }
        guard http.statusCode == 200 else {
            throw UpdateError.download("the server answered with HTTP \(http.statusCode)")
        }
        if http.expectedContentLength >= 0, http.expectedContentLength != Int64(limit) {
            throw UpdateError.download("the server announced \(http.expectedContentLength) bytes but the release lists \(limit)")
        }

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var total = 0
        for try await byte in bytes {
            total += 1
            if total > limit {
                throw UpdateError.download("the package is larger than the release lists")
            }
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        return total
    }

    /// Follows a redirect only when it stays on HTTPS and on an approved host.
    /// Anything else cancels the redirect, so the caller sees the 3xx and fails.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.isAllowed(request.url) ? request : nil)
    }
}
