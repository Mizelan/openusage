import XCTest
@testable import OpenUsage

final class MiniMaxComUsageMapperTests: XCTestCase {
    func testMapsUsedTotalToCodingPlanPercent() throws {
        let body: [String: Any] = [
            "code": 200,
            "data": ["used": 30, "total": 100, "reset_at": 1_774_091_383]
        ]
        let mapped = try MiniMaxComUsageMapper.mapCodingPlanRemains(body)

        XCTAssertEqual(mapped.lines.count, 1)
        let line = try XCTUnwrap(progress(mapped.lines, "Coding Plan"))
        XCTAssertEqual(line.used, 30)
        XCTAssertEqual(line.limit, 100)
        XCTAssertNotNil(line.resetsAt)
    }

    func testMapsRemainingTotalToCodingPlanPercent() throws {
        // When the API gives `remaining` instead of `used`, the mapper flips it.
        let body: [String: Any] = [
            "data": ["remaining": 70, "total": 100]
        ]
        let mapped = try MiniMaxComUsageMapper.mapCodingPlanRemains(body)

        XCTAssertEqual(progress(mapped.lines, "Coding Plan")?.used, 30)
    }

    func testMapsNestedFieldNames() throws {
        // Some MiniMax responses use camelCase or different field names; the fallback chain covers them.
        let body: [String: Any] = [
            "data": ["consumed": 50, "consumedQuota": 50, "quota": 200, "balance": 12.5]
        ]
        let mapped = try MiniMaxComUsageMapper.mapCodingPlanRemains(body)

        XCTAssertEqual(progress(mapped.lines, "Coding Plan")?.used, 25)
        XCTAssertEqual(dollars(mapped.lines, "Credits"), 12.5)
    }

    func testThrowsWhenNothingDisplayable() {
        let body: [String: Any] = ["data": ["unrelated": "value"]]
        XCTAssertThrowsError(try MiniMaxComUsageMapper.mapCodingPlanRemains(body)) { error in
            XCTAssertEqual(error as? MiniMaxComUsageError, .quotaUnavailable)
        }
    }

    func testClampsPercentRange() throws {
        let body: [String: Any] = [
            "data": ["used": 200, "total": 100]  // 200% — clamp to 100
        ]
        let mapped = try MiniMaxComUsageMapper.mapCodingPlanRemains(body)
        XCTAssertEqual(progress(mapped.lines, "Coding Plan")?.used, 100)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }
}

@MainActor
final class MiniMaxComProviderTests: XCTestCase {
    func testRefreshWithoutCookiesReturnsNotLoggedIn() async {
        let provider = MiniMaxComProvider(
            authStore: MiniMaxComAuthStore(cookies: FakeBrowserCookieStore()),
            usageClient: MiniMaxComUsageClient(http: QueueHTTPClient())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), MiniMaxComAuthError.notLoggedIn.localizedDescription)
    }

    func testRefreshOn404ReturnsQuotaUnavailable() async {
        let cookies = FakeBrowserCookieStore(["minimax.com": ["session_id": "valid"]])
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 404, headers: [:], body: Data("{}".utf8))
        ])
        let provider = MiniMaxComProvider(
            authStore: MiniMaxComAuthStore(cookies: cookies),
            usageClient: MiniMaxComUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), MiniMaxComUsageError.quotaUnavailable.localizedDescription)
    }

    func testRefreshRendersQuotaFromResponse() async throws {
        let cookies = FakeBrowserCookieStore(["minimax.com": ["session_id": "valid"]])
        let body: [String: Any] = ["code": 200, "data": ["used": 50, "total": 100]]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: bodyData)
        ])
        let provider = MiniMaxComProvider(
            authStore: MiniMaxComAuthStore(cookies: cookies),
            usageClient: MiniMaxComUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertEqual(snapshot.lines.first?.label, "Coding Plan")
        XCTAssertEqual(httpClient.requests.first?.headers["Cookie"], "session_id=valid")
    }

    private func errorText(_ lines: [MetricLine]) -> String? {
        guard case .badge(_, let text, _, _) = lines.first else {
            return nil
        }
        return text
    }
}