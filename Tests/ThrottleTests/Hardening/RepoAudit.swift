import Foundation
import XCTest

/// Shared machinery for the source-audit tests (ISC-132–137, 56, 67, 77, 87).
///
/// These tests do not exercise Throttle's code. They read the repository's own
/// files as text and assert invariants that no runtime test can prove: that a
/// forbidden endpoint is absent, that a token never reaches a log line, that
/// the only entitlement is network client. The repository root is derived from
/// `#filePath` so the audit works from any derived-data location.
enum RepoAudit {
    /// Reading the checkout from the host app trips a Files-and-Folders
    /// privacy prompt when the repository lives under a protected folder such
    /// as `~/Documents`; a headless run cannot answer it and hangs. The audit
    /// runs when the checkout is outside those folders (CI) or when the runner
    /// opts in with `THROTTLE_REPO_AUDIT=1` (`TEST_RUNNER_THROTTLE_REPO_AUDIT=1`
    /// through xcodebuild) after granting the host app access once.
    static var canReadRepository: Bool {
        if ProcessInfo.processInfo.environment["THROTTLE_REPO_AUDIT"] == "1" { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = root.standardizedFileURL.path
        for folder in ["Documents", "Desktop", "Downloads"] where path.hasPrefix(home + "/" + folder + "/") {
            return false
        }
        return true
    }

    /// Throws `XCTSkip` when the checkout cannot be read without a prompt.
    static func requireRepositoryAccess() throws {
        guard canReadRepository else {
            throw XCTSkip("repository audit skipped: checkout is under a privacy-protected folder; set TEST_RUNNER_THROTTLE_REPO_AUDIT=1 to run it")
        }
    }

    /// `<repo>/Tests/ThrottleTests/Hardening/RepoAudit.swift` -> `<repo>`.
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Hardening
        .deletingLastPathComponent() // ThrottleTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    static var sourcesRoot: URL { root.appendingPathComponent("Sources") }

    static var entitlementsFile: URL { root.appendingPathComponent("Throttle.entitlements") }

    /// One line of one source file, carrying enough to print `file:line`.
    struct SourceLine {
        let file: String
        let number: Int
        let text: String

        /// Clickable `Sources/Throttle/Foo.swift:42`.
        var location: String { "\(file):\(number)" }

        var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

        /// A `//` comment line. Comments are prose, not behavior, so the tests
        /// that look for *calls* skip them; the tests that look for *strings*
        /// do not.
        var isComment: Bool { trimmed.hasPrefix("//") }

        func contains(_ needle: String) -> Bool { text.contains(needle) }

        func containsAny(_ needles: [String]) -> Bool { needles.contains(where: text.contains) }
    }

    /// Every `.swift` file under `Sources/`, sorted for stable failure output.
    static func swiftFiles() throws -> [URL] {
        try requireRepositoryAccess()
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        guard let enumerator else {
            throw AuditError.unreadable(sourcesRoot.path)
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Every line of every Swift file under `Sources/`.
    static func sourceLines() throws -> [SourceLine] {
        var lines: [SourceLine] = []
        for file in try swiftFiles() {
            lines.append(contentsOf: try self.lines(in: file))
        }
        return lines
    }

    static func lines(in file: URL) throws -> [SourceLine] {
        try requireRepositoryAccess()
        let relative = relativePath(of: file)
        let contents = try String(contentsOf: file, encoding: .utf8)
        return contents
            .components(separatedBy: "\n")
            .enumerated()
            .map { SourceLine(file: relative, number: $0.offset + 1, text: $0.element) }
    }

    static func relativePath(of file: URL) -> String {
        let prefix = root.path + "/"
        return file.path.hasPrefix(prefix)
            ? String(file.path.dropFirst(prefix.count))
            : file.path
    }

    /// Renders offenders one per line so a failure names every file:line at once
    /// rather than making the reader re-run the test to find the next one.
    static func report(_ title: String, _ offenders: [String]) -> String {
        ([title] + offenders.map { "  " + $0 }).joined(separator: "\n")
    }

    /// Every host following a `scheme://` occurrence on the line, with the byte
    /// offset so two URLs on one line stay distinguishable. The host runs to the
    /// first character that cannot appear in one, which stops it at `/`, `"`,
    /// `:` before a port, or a `\(` interpolation.
    static func hosts(ofScheme scheme: String, in line: String) -> [(host: String, snippet: String)] {
        let marker = scheme + "://"
        var results: [(String, String)] = []
        var searchRange = line.startIndex..<line.endIndex
        while let found = line.range(of: marker, range: searchRange) {
            var host = ""
            var index = found.upperBound
            while index < line.endIndex, isHostCharacter(line[index]) {
                host.append(line[index])
                index = line.index(after: index)
            }
            results.append((host, marker + host))
            searchRange = found.upperBound..<line.endIndex
        }
        return results
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "-"
    }

    /// Every double-quoted string literal on the line. Good enough for an audit:
    /// Throttle has no multi-line string literals and no escaped quotes inside
    /// the literals these tests care about.
    static func stringLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current: String?
        var escaped = false
        for character in line {
            if escaped {
                current?.append(character)
                escaped = false
                continue
            }
            if character == "\\", current != nil {
                escaped = true
                continue
            }
            if character == "\"" {
                if let literal = current {
                    literals.append(literal)
                    current = nil
                } else {
                    current = ""
                }
                continue
            }
            current?.append(character)
        }
        return literals
    }

    enum AuditError: Error, CustomStringConvertible {
        case unreadable(String)

        var description: String {
            switch self {
            case .unreadable(let path): "Could not enumerate \(path)"
            }
        }
    }
}
