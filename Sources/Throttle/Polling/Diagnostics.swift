import Foundation
import os

/// One line of the on-disk diagnostics log: what was asked of a provider and
/// what came back, with the credential removed before anything is encoded.
///
/// The request's `Authorization` header is dropped, never redacted in place,
/// so a diagnostics line can not carry a token even in masked form. The
/// response body is capped at 300 characters and passed through `Redactor`,
/// as is the free-text message.
struct DiagnosticEvent: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case usage, refresh, profile, login, scheduler
        case reset
    }

    /// Characters of the response body kept on the line.
    static let bodyPrefixLength = 300

    var ts: Date
    var provider: String
    /// The Throttle account UUID. `nil` when the event is not about one
    /// account (a token refresh only sees the credential, a provider-wide
    /// override sees the provider).
    var accountID: String?
    var kind: Kind
    var status: Int?
    var retryAfterSeconds: Int?
    var requestHeaders: [String: String]
    var url: String
    var bodyPrefix: String
    var message: String?

    init(
        ts: Date,
        provider: Provider,
        accountID: UUID?,
        kind: Kind,
        status: Int? = nil,
        retryAfterSeconds: Int? = nil,
        requestHeaders: [String: String] = [:],
        url: String = "",
        bodyPrefix: String = "",
        message: String? = nil
    ) {
        self.ts = ts
        self.provider = provider.rawValue
        self.accountID = accountID?.uuidString
        self.kind = kind
        self.status = status
        self.retryAfterSeconds = retryAfterSeconds
        self.requestHeaders = Self.strippedHeaders(requestHeaders)
        self.url = url
        self.bodyPrefix = Redactor.redact(String(bodyPrefix.prefix(Self.bodyPrefixLength)))
        self.message = message.map(Redactor.redact)
    }

    /// Builds the line for one HTTP exchange. `retryAfter` is the provider's
    /// own parse of `Retry-After` when it has one; otherwise the header is
    /// read as plain seconds.
    init(
        ts: Date,
        provider: Provider,
        accountID: UUID?,
        kind: Kind,
        request: URLRequest,
        response: HTTPResponse,
        retryAfter: TimeInterval? = nil,
        message: String? = nil
    ) {
        let retrySeconds: Int?
        if let retryAfter, retryAfter.isFinite {
            retrySeconds = Int(retryAfter.rounded())
        } else if let raw = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces),
                  let seconds = Double(raw), seconds.isFinite {
            retrySeconds = Int(seconds.rounded())
        } else {
            retrySeconds = nil
        }
        self.init(
            ts: ts,
            provider: provider,
            accountID: accountID,
            kind: kind,
            status: response.statusCode,
            retryAfterSeconds: retrySeconds,
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            url: request.url?.absoluteString ?? "",
            bodyPrefix: String(decoding: response.body.prefix(Self.bodyPrefixLength * 4), as: UTF8.self),
            message: message
        )
    }

    /// Every request header except `Authorization`, whatever its case. The
    /// values that remain are still redacted in case a header ever echoes a
    /// credential by another name.
    static func strippedHeaders(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in headers where name.caseInsensitiveCompare("Authorization") != .orderedSame {
            out[name] = Redactor.redact(value)
        }
        return out
    }
}

/// Appends `DiagnosticEvent` lines to `diagnostics.log` under `AppPaths`.
///
/// Unified logging from this app has not been recoverable with `log show`, so
/// the evidence a support conversation needs (which endpoint answered what,
/// with which `Retry-After`) lives in a file the user can reveal from Settings.
/// The file is JSON Lines, mode 0600, opened for append and closed on every
/// write. When it passes 512 KB it is cut back to its last 256 KB on a line
/// boundary, so it never grows without bound and never holds a torn line at
/// the top.
///
/// Nothing here can fail loudly: a diagnostics write that throws would turn a
/// logging problem into a polling problem. Failures go to the unified log and
/// the event is dropped.
actor Diagnostics {
    static let maxBytes = 512 * 1024
    static let keepBytes = 256 * 1024

    private let paths: AppPaths
    private let logger = Logger(subsystem: "ai.parslee.throttle", category: "Diagnostics")

    init(paths: AppPaths) {
        self.paths = paths
    }

    /// Where the log lives. Exposed so the UI can reveal it in Finder.
    nonisolated var fileURL: URL { paths.diagnosticsFile }

    /// Appends one line. Never throws.
    func record(_ event: DiagnosticEvent) {
        do {
            try paths.ensureDirectoryExists()
            var line = try Self.encoder.encode(event)
            line.append(0x0A)
            try append(line)
            try truncateIfNeeded()
        } catch {
            logger.error("Diagnostics write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Creates the file if it is missing so that Finder has something to
    /// select. Never throws.
    func ensureFileExists() {
        let path = fileURL.path
        guard !FileManager.default.fileExists(atPath: path) else { return }
        do {
            try paths.ensureDirectoryExists()
            try append(Data())
        } catch {
            logger.error("Diagnostics file could not be created: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: File plumbing

    private func append(_ data: Data) throws {
        let path = fileURL.path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw DiagnosticsError.posixFailure(operation: "open", errno: errno)
        }
        defer { close(fd) }
        // The create mode is subject to the umask; make the file mode
        // unconditional, and repair a pre-existing file at the same time.
        guard fchmod(fd, 0o600) == 0 else {
            throw DiagnosticsError.posixFailure(operation: "fchmod", errno: errno)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard written >= 0 else {
                    throw DiagnosticsError.posixFailure(operation: "write", errno: errno)
                }
                offset += written
            }
        }
    }

    /// Cuts the file back to its last `keepBytes`, starting at the first whole
    /// line, once it exceeds `maxBytes`.
    private func truncateIfNeeded() throws {
        let url = fileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue, size > Self.maxBytes else { return }
        let data = try Data(contentsOf: url)
        try AccountStore.atomicWrite(Self.tail(of: data, keeping: Self.keepBytes), to: url)
    }

    /// The last `bytes` of `data`, advanced to the byte after the first
    /// newline so the result starts on a whole line.
    static func tail(of data: Data, keeping bytes: Int) -> Data {
        guard data.count > bytes else { return data }
        var start = data.count - bytes
        if let newline = data[start...].firstIndex(of: 0x0A) {
            start = newline + 1
        }
        return Data(data[start...])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

enum DiagnosticsError: Error {
    case posixFailure(operation: String, errno: Int32)
}
