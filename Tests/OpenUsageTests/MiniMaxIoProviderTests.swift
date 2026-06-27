import XCTest
@testable import OpenUsage

final class MiniMaxIoUsageMapperTests: XCTestCase {
    func testMapsWeeklyUsedTotal() throws {
        let body: [String: Any] = [
            "data": ["weeklyUsed": 40, "weeklyTotal": 100, "weekResetAt": 1_774_091_383]
        ]
        let mapped = try MiniMaxIoUsageMapper.mapUsage(body)

        XCTAssertEqual(mapped.lines.count, 1)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 40)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.periodDurationMs, MiniMaxIoUsageMapper == MiniMaxIoUsageMapper.self ? MetricPeriod.weekMs : 0)
        XCTAssertNotNil(progress(mapped.lines, "Weekly")?.resetsAt)
    }

    func testMapsWeeklyRemainingTotal() throws {
        let body: [String: Any] = [
            "data": ["weekRemaining": 60, "weekTotal": 100]
        ]
        let mapped = try MiniMaxIoUsageMapper.mapUsage(body)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 40)
    }

    func testMapsDailyWhenPresent() throws {
        let body: [String: Any] = [
            "data": [
                "weeklyUsed": 40, "weeklyTotal": 100,
                "dailyUsed": 10, "dailyTotal": 100
            ]
        ]
        let mapped = try MiniMaxIoUsageMapper.mapUsage(body)
        XCTAssertEqual(mapped.lines.count, 2)
        XCTAssertNotNil(progress(mapped.lines, "Weekly"))
        XCTAssertNotNil(progress(mapped.lines, "Daily"))
    }

    func testRendersOnlyDailyWhenWeeklyAbsent() throws {
        let body: [String: Any] = [
            "data": ["dailyUsed": 10, "dailyTotal": 100]
        ]
        let mapped = try MiniMaxIoUsageMapper.mapUsage(body)
        XCTAssertEqual(mapped.lines.count, 1)
        XCTAssertNil(progress(mapped.lines, "Weekly"))
        XCTAssertNotNil(progress(mapped.lines, "Daily"))
    }

    func testThrowsOnEmptyResponse() {
        XCTAssertThrowsError(try MiniMaxIoUsageMapper.mapUsage(["data": [:]])) { error in
            XCTAssertEqual(error as? MiniMaxIoUsageError, .quotaUnavailable)
        }
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }
}

@MainActor
final class MiniMaxIoProviderTests: XCTestCase {
    func testRefreshOn404ReturnsQuotaUnavailable() async {
        // 404 means our best-guess endpoint path was wrong; degrade to unavailable rather than crash.
        let cookies = FakeBrowserCookieStore(["minimax.io": ["session_id": "valid"]])
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 404, headers: [:], body: Data())
        ])
        let provider = MiniMaxIoProvider(
            authStore: MiniMaxIoAuthStore(cookies: cookies),
            usageClient: MiniMaxIoUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), MiniMaxIoUsageError.quotaUnavailable.localizedDescription)
    }

    func testRefreshWithoutCookiesReturnsNotLoggedIn() async {
        let provider = MiniMaxIoProvider(
            authStore: MiniMaxIoAuthStore(cookies: FakeBrowserCookieStore()),
            usageClient: MiniMaxIoUsageClient(http: QueueHTTPClient())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), MiniMaxIoAuthError.notLoggedIn.localizedDescription)
    }

    private func errorText(_ lines: [MetricLine]) -> String? {
        guard case .badge(_, let text, _, _) = lines.first else {
            return nil
        }
        return text
    }
}