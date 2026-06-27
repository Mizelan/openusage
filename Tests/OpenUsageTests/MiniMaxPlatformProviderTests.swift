import XCTest
@testable import OpenUsage

final class MiniMaxPlatformUsageMapperTests: XCTestCase {
    func testMapsCreditBalance() throws {
        let body: [String: Any] = ["credit_balance": 25.5]
        let mapped = try MiniMaxPlatformUsageMapper.mapBalance(body)
        XCTAssertEqual(dollars(mapped.lines, "Balance"), 25.5)
    }

    func testMapsBalanceCentsToDollars() throws {
        let body: [String: Any] = ["balance_cents": 1234, "currency": "USD"]
        let mapped = try MiniMaxPlatformUsageMapper.mapBalance(body)
        XCTAssertEqual(dollars(mapped.lines, "Balance"), 12.34)
    }

    func testMapsMonthlySpend() throws {
        let body: [String: Any] = [
            "credit_balance": 100,
            "monthlySpend": 42.5
        ]
        let mapped = try MiniMaxPlatformUsageMapper.mapBalance(body)
        XCTAssertEqual(dollars(mapped.lines, "Balance"), 100)
        XCTAssertEqual(dollars(mapped.lines, "This Month"), 42.5)
    }

    func testThrowsOnEmptyResponse() {
        XCTAssertThrowsError(try MiniMaxPlatformUsageMapper.mapBalance([:])) { error in
            XCTAssertEqual(error as? MiniMaxPlatformUsageError, .quotaUnavailable)
        }
    }

    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }
}

@MainActor
final class MiniMaxPlatformProviderTests: XCTestCase {
    func testRefreshWithoutCookiesReturnsNotLoggedIn() async {
        let provider = MiniMaxPlatformProvider(
            authStore: MiniMaxPlatformAuthStore(cookies: FakeBrowserCookieStore()),
            usageClient: MiniMaxPlatformUsageClient(http: QueueHTTPClient())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), MiniMaxPlatformAuthError.notLoggedIn.localizedDescription)
    }

    func testRefreshOn404ReturnsQuotaUnavailable() async {
        let cookies = FakeBrowserCookieStore(["platform.minimax.io": ["session_id": "valid"]])
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 404, headers: [:], body: Data())
        ])
        let provider = MiniMaxPlatformProvider(
            authStore: MiniMaxPlatformAuthStore(cookies: cookies),
            usageClient: MiniMaxPlatformUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), MiniMaxPlatformUsageError.quotaUnavailable.localizedDescription)
    }

    func testRefreshRendersBalanceFromResponse() async throws {
        let cookies = FakeBrowserCookieStore(["platform.minimax.io": ["session_id": "valid"]])
        let body: [String: Any] = ["credit_balance": 50.25]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: bodyData)
        ])
        let provider = MiniMaxPlatformProvider(
            authStore: MiniMaxPlatformAuthStore(cookies: cookies),
            usageClient: MiniMaxPlatformUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertEqual(snapshot.lines.first?.label, "Balance")
    }

    private func errorText(_ lines: [MetricLine]) -> String? {
        guard case .badge(_, let text, _, _) = lines.first else {
            return nil
        }
        return text
    }
}