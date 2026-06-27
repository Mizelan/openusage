import Foundation

struct MiniMaxPlatformMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

struct MiniMaxPlatformUsageClient: Sendable {
    /// Best-guess Anthropic-compatible billing endpoint. The platform's API documentation isn't
    /// publicly published; this is the same shape the Claude provider uses for its own billing
    /// probe. Update when a confirmed endpoint is captured from a logged-in browser session.
    static let endpoint = URL(string: "https://platform.minimax.io/v1/dashboard/billing/credit_balance")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchBalance(auth: MiniMaxPlatformAuth) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.endpoint,
            headers: [
                "Accept": "application/json",
                "Cookie": auth.cookieHeader,
                "Origin": MiniMaxPlatformAuthStore.origin,
                "Referer": MiniMaxPlatformAuthStore.referer,
                "anthropic-version": "2023-06-01",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            ],
            timeout: 15
        ))
    }
}