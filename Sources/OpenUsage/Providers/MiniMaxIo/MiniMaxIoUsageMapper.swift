import Foundation

/// Maps MiniMax chat-platform (chat.minimax.io) responses to the app's metric vocabulary.
///
/// The exact JSON shape isn't publicly documented; the mapper tolerates several plausible layouts so
/// the widget either shows real data or renders `quotaUnavailable`. When a fresh sample arrives from
/// a logged-in user, update the field fallbacks here in one place.
enum MiniMaxIoUsageMapper {
    static func mapUsage(_ body: [String: Any]) throws -> MiniMaxIoMappedUsage {
        let inner: [String: Any]
        if let data = body["data"] as? [String: Any] {
            inner = data
        } else if let result = body["result"] as? [String: Any] {
            inner = result
        } else {
            inner = body
        }

        var lines: [MetricLine] = []

        // Weekly quota (the primary metric per upstream issue #666).
        if let weekly = weeklyQuotaLine(from: inner) {
            lines.append(weekly)
        }

        // Daily quota (if surfaced).
        if let daily = dailyQuotaLine(from: inner) {
            lines.append(daily)
        }

        guard !lines.isEmpty else {
            throw MiniMaxIoUsageError.quotaUnavailable
        }
        let plan = trimmedString(inner["plan"]) ?? trimmedString(body["plan"]) ?? trimmedString(inner["level"])
        return MiniMaxIoMappedUsage(plan: plan, lines: lines)
    }

    private static func weeklyQuotaLine(from inner: [String: Any]) -> MetricLine? {
        let used = number(in: inner, keys: ["weeklyUsed", "weekUsed", "usedWeekly", "week_used"])
        let total = number(in: inner, keys: ["weeklyTotal", "weekTotal", "totalWeekly", "week_total"])
        let remaining = number(in: inner, keys: ["weeklyRemaining", "weekRemaining", "remainingWeekly"])
        let resetAt = resetDate(in: inner, keyHints: ["weekResetAt", "weeklyResetAt", "weekReset", "reset_at"])

        if let used, let total, total > 0 {
            return progressLine(label: "Weekly", used: used, total: total, reset: resetAt)
        }
        if let remaining, let total, total > 0 {
            return progressLine(label: "Weekly", used: total - remaining, total: total, reset: resetAt)
        }
        return nil
    }

    private static func dailyQuotaLine(from inner: [String: Any]) -> MetricLine? {
        let used = number(in: inner, keys: ["dailyUsed", "dayUsed", "usedDaily"])
        let total = number(in: inner, keys: ["dailyTotal", "dayTotal", "totalDaily"])
        let remaining = number(in: inner, keys: ["dailyRemaining", "dayRemaining"])
        let resetAt = resetDate(in: inner, keyHints: ["dayResetAt", "dailyResetAt", "reset_at"])

        if let used, let total, total > 0 {
            return progressLine(label: "Daily", used: used, total: total, reset: resetAt, periodMs: MetricPeriod.dayMs)
        }
        if let remaining, let total, total > 0 {
            return progressLine(label: "Daily", used: total - remaining, total: total, reset: resetAt, periodMs: MetricPeriod.dayMs)
        }
        return nil
    }

    private static func progressLine(label: String, used: Double, total: Double, reset: Date?, periodMs: Int = MetricPeriod.weekMs) -> MetricLine {
        .progress(
            label: label,
            used: ProviderParse.clampPercent(used / total * 100),
            limit: 100,
            format: .percent,
            resetsAt: reset,
            periodDurationMs: periodMs
        )
    }

    private static func number(in dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = ProviderParse.number(dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func resetDate(in dict: [String: Any], keyHints: [String]) -> Date? {
        for key in keyHints {
            guard let value = dict[key] else { continue }
            if let interval = ProviderParse.number(value) {
                let seconds = interval > 1_000_000_000_000 ? interval / 1000 : interval
                return Date(timeIntervalSince1970: seconds)
            }
            if let string = value as? String, let date = OpenUsageISO8601.date(from: string) {
                return date
            }
        }
        return nil
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum MiniMaxIoUsageError: Error, LocalizedError, Equatable {
    case invalidResponse
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .quotaUnavailable:
            return "MiniMax chat usage data unavailable. The provider endpoint may have changed — try again later."
        }
    }
}