import Foundation

/// Everything the adapter extracts from one usage payload.
///
/// `AccountStatus` carries the primary windows; the plan type and the extra
/// per-model lanes ride alongside so the detail window can show a plan badge
/// and a collapsed "additional limits" section without widening the shared
/// status type.
struct OpenAIUsageSnapshot: Hashable, Sendable {
    /// `rate_limit.primary_window` / `secondary_window`, shortest first.
    var windows: [UsageWindow]
    /// One window per `additional_rate_limits[]` entry and per non-null
    /// sub-window, in payload order.
    var additionalWindows: [UsageWindow]
    var email: String?
    var planType: String?
    var accountID: String?
}

/// Maps the `wham/usage` JSON onto `UsageWindow`s.
///
/// Lane keys and labels come from `limit_window_seconds`. OpenAI has switched
/// the 5-hour lane off for weeks at a time, so nothing here assumes which
/// windows exist or in which slot they arrive.
enum OpenAIUsageParser {
    static func parse(_ data: Data, now: Date? = nil) throws -> OpenAIUsageSnapshot {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UsageError.invalidResponse("unparseable usage payload")
        }

        let windows: [UsageWindow] = payload.rateLimit.map { makeWindows(from: $0, keyPrefix: nil, labelPrefix: nil, now: now) } ?? []

        var additional: [UsageWindow] = []
        for lane in payload.additionalRateLimits ?? [] {
            guard let rateLimit = lane.rateLimit, let name = lane.limitName, !name.isEmpty else { continue }
            additional += makeWindows(from: rateLimit, keyPrefix: "lane:\(name):", labelPrefix: "\(name) ", now: now)
        }

        if windows.isEmpty, additional.isEmpty {
            throw UsageError.invalidResponse("no usable windows")
        }

        return OpenAIUsageSnapshot(
            windows: windows,
            additionalWindows: additional,
            email: payload.email,
            planType: payload.planType,
            accountID: payload.accountID
        )
    }

    /// Stable identity for a window of the given length: `5h`, `7d`, or the
    /// generic `<n>h` / `<n>d` that `UsageWindow.label` would produce.
    static func key(forDurationSeconds seconds: Int) -> String {
        if seconds == 604_800 { return "7d" }
        return UsageWindow.label(forDurationSeconds: seconds).lowercased()
    }

    // MARK: - Private

    private static func makeWindows(
        from rateLimit: RateLimit,
        keyPrefix: String?,
        labelPrefix: String?,
        now: Date?
    ) -> [UsageWindow] {
        let raw = [rateLimit.primaryWindow, rateLimit.secondaryWindow].compactMap { $0 }
        let built = raw.compactMap { window -> UsageWindow? in
            guard let duration = window.limitWindowSeconds, duration > 0 else { return nil }
            let used = min(100, max(0, window.usedPercent ?? 0))
            var resetsAt: Date?
            if let epoch = window.resetAt {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let after = window.resetAfterSeconds, let now {
                resetsAt = now.addingTimeInterval(after)
            }
            return UsageWindow(
                key: (keyPrefix ?? "") + key(forDurationSeconds: duration),
                label: (labelPrefix ?? "") + UsageWindow.label(forDurationSeconds: duration),
                usedPercent: used,
                resetsAt: resetsAt,
                durationSeconds: duration
            )
        }
        return built.sorted { $0.durationSeconds < $1.durationSeconds }
    }

    private struct Payload: Decodable {
        var email: String?
        var planType: String?
        var accountID: String?
        var rateLimit: RateLimit?
        var additionalRateLimits: [AdditionalLane]?

        enum CodingKeys: String, CodingKey {
            case email
            case planType = "plan_type"
            case accountID = "account_id"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
    }

    private struct RateLimit: Decodable {
        var primaryWindow: Window?
        var secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    private struct Window: Decodable {
        var usedPercent: Double?
        var limitWindowSeconds: Int?
        var resetAfterSeconds: Double?
        var resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    private struct AdditionalLane: Decodable {
        var limitName: String?
        var rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case rateLimit = "rate_limit"
        }
    }
}
