import Foundation

/// Maps MiniMax Platform (model API) billing responses to the app's metric vocabulary.
///
/// Anthropic-compatible billing endpoints typically return one of:
///   - `{ "credit_balance": <dollars-as-decimal> }`
///   - `{ "balance_cents": <int>, "currency": "USD" }`
///   - `{ "data": { "balance": <dollars> } }`
///
/// The mapper tolerates any of these layouts. When the exact shape is confirmed, drop the fallbacks.
enum MiniMaxPlatformUsageMapper {
    static func mapBalance(_ body: [String: Any]) throws -> MiniMaxPlatformMappedUsage {
        let inner: [String: Any]
        if let data = body["data"] as? [String: Any] {
            inner = data
        } else {
            inner = body
        }

        var lines: [MetricLine] = []

        if let balance = balance(from: inner) {
            lines.append(.values(
                label: "Balance",
                values: [MetricValue(number: balance, kind: .dollars)]
            ))
        }

        // Optional: monthly spend / usage window if the platform exposes one.
        if let used = monthlySpend(from: inner) {
            lines.append(.values(
                label: "This Month",
                values: [MetricValue(number: used, kind: .dollars)]
            ))
        }

        guard !lines.isEmpty else {
            throw MiniMaxPlatformUsageError.quotaUnavailable
        }

        let plan = trimmedString(inner["plan"]) ?? trimmedString(body["plan"]) ?? trimmedString(inner["tier"])
        return MiniMaxPlatformMappedUsage(plan: plan, lines: lines)
    }

    private static func balance(from inner: [String: Any]) -> Double? {
        if let dollars = ProviderParse.number(inner["credit_balance"]) ?? ProviderParse.number(inner["balance"]) {
            return dollars
        }
        if let cents = ProviderParse.number(inner["balance_cents"]) {
            return ProviderParse.centsToDollars(cents)
        }
        return nil
    }

    private static func monthlySpend(from inner: [String: Any]) -> Double? {
        if let dollars = ProviderParse.number(inner["monthlySpend"]) ?? ProviderParse.number(inner["current_month_spend"]) {
            return dollars
        }
        if let cents = ProviderParse.number(inner["monthly_spend_cents"]) {
            return ProviderParse.centsToDollars(cents)
        }
        return nil
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum MiniMaxPlatformUsageError: Error, LocalizedError, Equatable {
    case invalidResponse
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .quotaUnavailable:
            return "MiniMax Platform balance unavailable. Try again later."
        }
    }
}