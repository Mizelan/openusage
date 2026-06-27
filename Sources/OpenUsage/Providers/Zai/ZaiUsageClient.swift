import Foundation

/// Live response shape after the mapper's been at it. Kept small — the mapper just hands the
/// provider the lines + plan it wants to show.
struct ZaiMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Talks to `GET https://z.ai/api/monitor/usage/quota/limit`. The endpoint is the same one the Z.ai
/// "Manage API Key" subscription page calls in the browser; reusing it via cookie auth means no API
/// key registration or pasting is needed.
struct ZaiUsageClient: Sendable {
    static let endpoint = URL(string: "https://z.ai/api/monitor/usage/quota/limit")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchQuota(auth: ZaiAuth) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.endpoint,
            headers: [
                "Accept": "application/json",
                "Cookie": auth.cookieHeader,
                // The Origin/Referer/User-Agent headers mimic a logged-in browser so the server's
                // same-origin checks accept the request. Without these, the response has been observed
                // to be 403 even with a valid session cookie.
                "Origin": ZaiAuthStore.origin,
                "Referer": ZaiAuthStore.referer,
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            ],
            timeout: 15
        ))
    }
}