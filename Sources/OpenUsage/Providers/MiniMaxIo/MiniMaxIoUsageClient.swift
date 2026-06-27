import Foundation

struct MiniMaxIoMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

struct MiniMaxIoUsageClient: Sendable {
    /// Best-guess endpoint — the actual path is undocumented upstream (closed issue #666 had no
    /// probe details). If the path returns 404, the mapper degrades to `quotaUnavailable` and the
    /// user sees a "no data" badge rather than fabricated numbers.
    static let endpoint = URL(string: "https://chat.minimax.io/api/user/usage")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(auth: MiniMaxIoAuth) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.endpoint,
            headers: [
                "Accept": "application/json",
                "Cookie": auth.cookieHeader,
                "Origin": MiniMaxIoAuthStore.origin,
                "Referer": MiniMaxIoAuthStore.referer,
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            ],
            timeout: 15
        ))
    }
}