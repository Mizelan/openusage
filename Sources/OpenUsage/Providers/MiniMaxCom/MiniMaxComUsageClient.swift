import Foundation

struct MiniMaxComMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

struct MiniMaxComUsageClient: Sendable {
    /// Endpoint per upstream issue #222 (`www.minimaxi.com/.../coding_plan/remains`).
    /// The response shape isn't fully documented — the mapper tries several plausible field
    /// locations and falls back to `quotaUnavailable` if none match.
    static let endpoint = URL(string: "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchCodingPlanRemains(auth: MiniMaxComAuth) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.endpoint,
            headers: [
                "Accept": "application/json",
                "Cookie": auth.cookieHeader,
                "Origin": MiniMaxComAuthStore.origin,
                "Referer": MiniMaxComAuthStore.referer,
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            ],
            timeout: 15
        ))
    }
}