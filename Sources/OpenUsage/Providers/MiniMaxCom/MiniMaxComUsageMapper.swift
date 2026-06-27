import Foundation

/// Maps MiniMax (minimax.com) coding-plan responses to the app's metric vocabulary.
///
/// The exact JSON shape isn't publicly documented; issue #222 asserts it's "identical to the existing
/// minimax.io integration", but neither is published. The mapper tries several plausible layouts
/// (`data.remaining` / `data.used` / flat `remainingQuota`, etc.) so the widget either shows real data
/// or renders `quotaUnavailable` — never invented numbers.
enum MiniMaxComUsageMapper {
    static func mapCodingPlanRemains(_ body: [String: Any]) throws -> MiniMaxComMappedUsage {
        // Drill through common envelope shapes:
        //   - { code, data: { ... } }
        //   - { success, data: { ... } }
        //   - flat { remaining, total } (no envelope)
        let inner: [String: Any]
        if let data = body["data"] as? [String: Any] {
            inner = data
        } else if let result = body["result"] as? [String: Any] {
            inner = result
        } else {
            inner = body
        }

        var lines: [MetricLine] = []

        // Coding-plan quota — try `used`/`total` first, then `remaining`/`limit`, then any other pair.
        if let quota = codingPlanQuotaLine(from: inner) {
            lines.append(quota)
        }

        // Optional: residual credits balance (USD-style fields).
        if let balance = creditsBalance(from: inner) {
            lines.append(balance)
        }

        guard !lines.isEmpty else {
            throw MiniMaxComUsageError.quotaUnavailable
        }
        let plan = trimmedString(inner["plan"]) ?? trimmedString(body["plan"])
        return MiniMaxComMappedUsage(plan: plan, lines: lines)
    }

    private static func codingPlanQuotaLine(from inner: [String: Any]) -> MetricLine? {
        // (used, total) pair → progress percent; resetsAt optional.
        let used = number(in: inner, keys: ["used", "usedQuota", "consumed", "consumedQuota"])
        let total = number(in: inner, keys: ["total", "totalQuota", "limit", "quota"])
        let remaining = number(in: inner, keys: ["remaining", "remainingQuota", "left"])
        let resetAt = dateFromAny(
            inner["reset_at"] ?? inner["resetAt"] ?? inner["nextResetTime"] ?? inner["next_reset_time"]
        )

        if let used, let total, total > 0 {
            let percentUsed = ProviderParse.clampPercent(used / total * 100)
            return .progress(
                label: "Coding Plan",
                used: percentUsed,
                limit: 100,
                format: .percent,
                resetsAt: resetAt,
                periodDurationMs: MetricPeriod.dayMs
            )
        }
        if let remaining, let total, total > 0 {
            let used = total - remaining
            let percentUsed = ProviderParse.clampPercent(used / total * 100)
            return .progress(
                label: "Coding Plan",
                used: percentUsed,
                limit: 100,
                format: .percent,
                resetsAt: resetAt,
                periodDurationMs: MetricPeriod.dayMs
            )
        }
        return nil
    }

    private static func creditsBalance(from inner: [String: Any]) -> MetricLine? {
        guard let balance = number(in: inner, keys: ["balance", "creditBalance", "credits", "remainingCredit"])
        else { return nil }
        return .values(
            label: "Credits",
            values: [MetricValue(number: balance, kind: .dollars)]
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

    private static func dateFromAny(_ value: Any?) -> Date? {
        if let interval = ProviderParse.number(value) {
            // Heuristic: >10^12 means milliseconds, else seconds.
            let seconds = interval > 1_000_000_000_000 ? interval / 1000 : interval
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String {
            return OpenUsageISO8601.date(from: string)
        }
        return nil
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum MiniMaxComUsageError: Error, LocalizedError, Equatable {
    case invalidResponse
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .quotaUnavailable:
            return "MiniMax coding plan data unavailable. Try again later."
        }
    }
}