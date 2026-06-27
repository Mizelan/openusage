import Foundation

/// Maps a Z.ai `/api/monitor/usage/quota/limit` response body to the app's metric vocabulary.
///
/// The response carries a `data.limits[]` array; each entry has a `type` ("TIME_LIMIT" / "TOKENS_LIMIT")
/// and a numeric `unit` discriminator that picks out the period (5=daily, 6=weekly, 3=monthly). Entries
/// the user doesn't have on their plan are simply absent — the mapper skips them rather than rendering
/// an empty tile.
enum ZaiUsageMapper {
    static let dayPeriodMs = MetricPeriod.dayMs
    static let weekPeriodMs = MetricPeriod.weekMs
    static let monthPeriodMs = MetricPeriod.monthMs

    static func mapQuotaLimit(_ body: [String: Any]) throws -> ZaiMappedUsage {
        guard let data = body["data"] as? [String: Any] else {
            throw ZaiUsageError.invalidResponse
        }
        let plan = trimmedString(data["level"])
        let limits = (data["limits"] as? [Any]) ?? []
        var lines: [MetricLine] = []
        for raw in limits {
            guard let entry = raw as? [String: Any] else { continue }
            if let line = mapLimit(entry) {
                lines.append(line)
            }
        }
        guard !lines.isEmpty else {
            throw ZaiUsageError.quotaUnavailable
        }
        return ZaiMappedUsage(plan: plan, lines: lines)
    }

    /// One limit entry → one `MetricLine`, or nil if the entry is malformed / not displayable.
    /// The unit→period mapping is the Z.ai convention documented in upstream issue #242.
    private static func mapLimit(_ entry: [String: Any]) -> MetricLine? {
        let type = entry["type"] as? String
        let unit = ProviderParse.number(entry["unit"]).map { Int($0) }
        let percentage = ProviderParse.number(entry["percentage"]).map(ProviderParse.clampPercent)
        let nextReset = unixMillisToDate(entry["nextResetTime"])

        switch (type, unit) {
        case ("TIME_LIMIT", 5):
            guard let percentage else { return nil }
            return .progress(
                label: "Daily",
                used: percentage,
                limit: 100,
                format: .percent,
                resetsAt: nextReset,
                periodDurationMs: dayPeriodMs
            )
        case ("TOKENS_LIMIT", 6):
            guard let percentage else { return nil }
            return .progress(
                label: "Weekly",
                used: percentage,
                limit: 100,
                format: .percent,
                resetsAt: nextReset,
                periodDurationMs: weekPeriodMs
            )
        case ("TOKENS_LIMIT", 3):
            guard let percentage else { return nil }
            return .progress(
                label: "Monthly",
                used: percentage,
                limit: 100,
                format: .percent,
                resetsAt: nextReset,
                periodDurationMs: monthPeriodMs
            )
        default:
            // Unknown type or unit — skip. Z.ai may add new categories over time; the widget grid
            // doesn't need them, and silently dropping the entry keeps the existing rows meaningful.
            return nil
        }
    }

    private static func unixMillisToDate(_ value: Any?) -> Date? {
        guard let millis = ProviderParse.number(value) else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ZaiUsageError: Error, LocalizedError, Equatable {
    case invalidResponse
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .quotaUnavailable:
            return "Z.ai quota data unavailable. Try again later."
        }
    }
}