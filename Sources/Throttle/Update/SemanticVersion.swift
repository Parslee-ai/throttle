import Foundation

/// A release version, `X.Y.Z` with an optional `-prerelease` suffix, ordered by
/// Semantic Versioning 2.0 precedence.
///
/// The updater compares the running app against the newest published release
/// with this type, and every version that later reaches a file name, a URL, or
/// the administrator shell script is first held to `validationPattern`. Build
/// metadata (`+...`) is not accepted: releases never carry it, and refusing it
/// keeps `+` out of every path the updater builds.
struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// The only shape a version may have before it is used in a path or a
    /// script. Anchored, and matched against the whole string (see
    /// `WholeMatch`), so a trailing newline cannot slip past `$`.
    static let validationPattern = #"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$"#

    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated prerelease identifiers, empty for a release.
    let prerelease: [String]
    /// The validated text with any leading `v` removed, e.g. `0.1.0-rc.9`.
    /// This, never a re-rendering, is what goes into asset names and paths, so
    /// the name Throttle looks for is byte-for-byte the one it was given.
    let text: String

    var description: String { text }

    var isPrerelease: Bool { !prerelease.isEmpty }

    /// Parses `X.Y.Z` or `X.Y.Z-pre`, tolerating one leading `v` (`v0.1.0`).
    /// Returns `nil` for anything else, including empty prerelease identifiers
    /// (`1.0.0-rc..1`) and numbers too large for `Int`.
    init?(_ string: String) {
        let body = string.hasPrefix("v") ? String(string.dropFirst()) : string
        guard Self.isValid(body) else { return nil }

        let core: Substring
        let pre: [String]
        if let dash = body.firstIndex(of: "-") {
            core = body[..<dash]
            pre = body[body.index(after: dash)...]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard !pre.contains(where: \.isEmpty) else { return nil }
        } else {
            core = Substring(body)
            pre = []
        }
        let numbers = core.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }

        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        prerelease = pre
        text = body
    }

    /// Whether `string` (with no `v` prefix) has the exact validated shape.
    static func isValid(_ string: String) -> Bool {
        WholeMatch.matches(validationPattern, string)
    }

    // MARK: Precedence

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        for identifier in prerelease {
            hasher.combine(Self.isNumeric(identifier) ? Self.strippingLeadingZeros(identifier) : identifier)
        }
    }

    /// SemVer 2.0 section 11: core numbers numerically, then a release outranks
    /// any of its prereleases, then prerelease identifiers left to right.
    private static func compare(_ lhs: SemanticVersion, _ rhs: SemanticVersion) -> ComparisonResult {
        for (l, r) in [(lhs.major, rhs.major), (lhs.minor, rhs.minor), (lhs.patch, rhs.patch)] where l != r {
            return l < r ? .orderedAscending : .orderedDescending
        }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) {
            let result = compareIdentifiers(l, r)
            if result != .orderedSame { return result }
        }
        if lhs.prerelease.count == rhs.prerelease.count { return .orderedSame }
        return lhs.prerelease.count < rhs.prerelease.count ? .orderedAscending : .orderedDescending
    }

    /// Numeric identifiers compare numerically and rank below alphanumeric
    /// ones; alphanumeric identifiers compare in ASCII order.
    private static func compareIdentifiers(_ l: String, _ r: String) -> ComparisonResult {
        switch (isNumeric(l), isNumeric(r)) {
        case (true, true):
            // Compared as digit strings so an identifier longer than `Int`
            // can hold still orders correctly.
            let a = strippingLeadingZeros(l)
            let b = strippingLeadingZeros(r)
            if a.count != b.count { return a.count < b.count ? .orderedAscending : .orderedDescending }
            return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case (true, false):
            return .orderedAscending
        case (false, true):
            return .orderedDescending
        case (false, false):
            if l == r { return .orderedSame }
            return Array(l.utf8).lexicographicallyPrecedes(Array(r.utf8)) ? .orderedAscending : .orderedDescending
        }
    }

    private static func isNumeric(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    private static func strippingLeadingZeros(_ digits: String) -> String {
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}

/// Whole-string regular expression matching for the updater's validators.
///
/// ICU's `$` also matches just before a final line terminator, so
/// `"0.2.0\n"` satisfies `^...$` on its own. Requiring the match to cover the
/// entire string closes that gap for every pattern the updater checks.
enum WholeMatch {
    static func matches(_ pattern: String, _ string: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let whole = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: whole) else { return false }
        return match.range == whole
    }
}
