import Foundation

/// Turns the `/api/oauth/usage` payload into display-ordered windows.
///
/// Two payload shapes are understood:
///
/// - Current: `{"limits": [{"kind": "session" | "weekly_all" | "weekly_scoped",
///   "percent": ..., "resets_at": ..., "scope": {"model": {"display_name": ...}}}]}`
/// - Legacy: top-level `five_hour`, `seven_day`, and `seven_day_<model>`
///   objects carrying `utilization`.
///
/// Model-scoped windows take their label from the payload, never from a
/// hardcoded model name, so a renamed or added model shows up on its own.
enum AnthropicUsageParser {
    static let sessionSeconds = 18_000
    static let weeklySeconds = 604_800
    static let maxWindows = 12
    static let maxLabelLength = 80
    static let defaultScopedLabel = "Scoped"

    static func parse(_ data: Data) throws -> [UsageWindow] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError.invalidResponse("malformed JSON")
        }
        guard let root = json as? [String: Any] else {
            throw UsageError.invalidResponse("root is not an object")
        }

        let windows: [UsageWindow]
        if let limits = root["limits"] as? [Any] {
            windows = parseCurrent(limits)
        } else {
            windows = parseLegacy(root, rawData: data)
        }

        guard !windows.isEmpty else {
            throw UsageError.invalidResponse("no usable windows")
        }
        return windows
    }

    // MARK: - Current shape

    private static func parseCurrent(_ limits: [Any]) -> [UsageWindow] {
        var session: UsageWindow?
        var weekly: UsageWindow?
        var scoped: [UsageWindow] = []
        var seenKeys = Set<String>()

        for entry in limits {
            guard let object = entry as? [String: Any],
                  let kind = object["kind"] as? String else { continue }

            let candidate: UsageWindow?
            switch kind {
            case "session":
                candidate = makeWindow(
                    key: "5h",
                    label: UsageWindow.label(forDurationSeconds: sessionSeconds),
                    duration: sessionSeconds,
                    percentValue: object["percent"],
                    resetValue: object["resets_at"],
                    resetPresent: object.keys.contains("resets_at")
                )
            case "weekly_all":
                candidate = makeWindow(
                    key: "7d",
                    label: UsageWindow.label(forDurationSeconds: weeklySeconds),
                    duration: weeklySeconds,
                    percentValue: object["percent"],
                    resetValue: object["resets_at"],
                    resetPresent: object.keys.contains("resets_at")
                )
            case "weekly_scoped":
                let label = boundedLabel(scopeDisplayName(object))
                candidate = makeWindow(
                    key: UsageWindow.scopedPrefix + label,
                    label: label,
                    duration: weeklySeconds,
                    percentValue: object["percent"],
                    resetValue: object["resets_at"],
                    resetPresent: object.keys.contains("resets_at")
                )
            default:
                candidate = nil
            }

            guard let window = candidate, !seenKeys.contains(window.key) else { continue }
            seenKeys.insert(window.key)
            switch kind {
            case "session": session = window
            case "weekly_all": weekly = window
            default: scoped.append(window)
            }
        }

        return assemble(session: session, weekly: weekly, scoped: scoped)
    }

    private static func scopeDisplayName(_ object: [String: Any]) -> String? {
        guard let scope = object["scope"] as? [String: Any],
              let model = scope["model"] as? [String: Any] else { return nil }
        return model["display_name"] as? String
    }

    // MARK: - Legacy shape

    private static func parseLegacy(_ root: [String: Any], rawData: Data) -> [UsageWindow] {
        var session: UsageWindow?
        var weekly: UsageWindow?

        if let object = root["five_hour"] as? [String: Any] {
            session = makeWindow(
                key: "5h",
                label: UsageWindow.label(forDurationSeconds: sessionSeconds),
                duration: sessionSeconds,
                percentValue: object["utilization"] ?? object["percent"],
                resetValue: object["resets_at"],
                resetPresent: object.keys.contains("resets_at")
            )
        }
        if let object = root["seven_day"] as? [String: Any] {
            weekly = makeWindow(
                key: "7d",
                label: UsageWindow.label(forDurationSeconds: weeklySeconds),
                duration: weeklySeconds,
                percentValue: object["utilization"] ?? object["percent"],
                resetValue: object["resets_at"],
                resetPresent: object.keys.contains("resets_at")
            )
        }

        // `seven_day_<model>` keys, kept in the order they appear in the payload.
        // A deserialised dictionary loses that order, so it is recovered from the
        // key's first byte offset in the raw text.
        let prefix = "seven_day_"
        let scopedKeys = root.keys
            .filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
            .sorted { keyOffset($0, in: rawData) < keyOffset($1, in: rawData) }

        var scoped: [UsageWindow] = []
        var seenKeys = Set<String>()
        for key in scopedKeys {
            guard let object = root[key] as? [String: Any] else { continue }
            let suffix = String(key.dropFirst(prefix.count))
            let label = boundedLabel(capitalizeFirst(suffix))
            let windowKey = UsageWindow.scopedPrefix + label
            guard !seenKeys.contains(windowKey) else { continue }
            if let window = makeWindow(
                key: windowKey,
                label: label,
                duration: weeklySeconds,
                percentValue: object["utilization"] ?? object["percent"],
                resetValue: object["resets_at"],
                resetPresent: object.keys.contains("resets_at")
            ) {
                seenKeys.insert(windowKey)
                scoped.append(window)
            }
        }

        return assemble(session: session, weekly: weekly, scoped: scoped)
    }

    private static func keyOffset(_ key: String, in data: Data) -> Int {
        let needle = Data("\"\(key)\"".utf8)
        guard let range = data.range(of: needle) else { return Int.max }
        return range.lowerBound
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: - Shared

    private static func assemble(session: UsageWindow?, weekly: UsageWindow?, scoped: [UsageWindow]) -> [UsageWindow] {
        var out: [UsageWindow] = []
        if let session { out.append(session) }
        if let weekly { out.append(weekly) }
        out.append(contentsOf: scoped)
        return Array(out.prefix(maxWindows))
    }

    /// Builds one window, or `nil` when the percent or a non-null reset is unusable.
    private static func makeWindow(
        key: String,
        label: String,
        duration: Int,
        percentValue: Any?,
        resetValue: Any?,
        resetPresent: Bool
    ) -> UsageWindow? {
        guard let percent = parsePercent(percentValue) else { return nil }
        let resetsAt: Date?
        switch parseReset(resetValue, present: resetPresent) {
        case .absent: resetsAt = nil
        case .date(let date): resetsAt = date
        case .malformed: return nil
        }
        return UsageWindow(
            key: key,
            label: label,
            usedPercent: percent,
            resetsAt: resetsAt,
            durationSeconds: duration
        )
    }

    private static func boundedLabel(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultScopedLabel }
        return String(trimmed.prefix(maxLabelLength))
    }

    /// Accepts a JSON number or a numeric string. Anything outside 0...100 after
    /// clamping tiny float noise, NaN, infinity, booleans, or non-numeric text
    /// returns `nil` so the window is dropped rather than drawn wrong.
    static func parsePercent(_ value: Any?) -> Double? {
        let number: Double
        if let n = value as? NSNumber, !isBoolean(n) {
            number = n.doubleValue
        } else if let s = value as? String {
            var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("%") { text.removeLast() }
            guard let parsed = Double(text) else { return nil }
            number = parsed
        } else {
            return nil
        }
        guard number.isFinite, number >= 0, number <= 100 else { return nil }
        return min(max(number, 0), 100)
    }

    enum ResetValue: Equatable {
        case absent
        case date(Date)
        case malformed
    }

    /// `null` or a missing key is a legitimate "no reset scheduled". A present
    /// value that fails to parse is treated as corruption and drops the window.
    static func parseReset(_ value: Any?, present: Bool) -> ResetValue {
        guard present, let value, !(value is NSNull) else { return .absent }

        if let n = value as? NSNumber, !isBoolean(n) {
            let raw = n.doubleValue
            guard raw.isFinite, raw > 0 else { return .malformed }
            let seconds = raw > 1e12 ? raw / 1000 : raw
            return .date(Date(timeIntervalSince1970: seconds))
        }
        if let s = value as? String {
            let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return .date(date) }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return .date(date) }
            return .malformed
        }
        return .malformed
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}
