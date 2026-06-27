import XCTest
@testable import OpenUsage

final class ZaiUsageMapperTests: XCTestCase {
    func testMapsAllThreePeriods() throws {
        let body = makeBody(limits: [
            makeTimeLimit(unit: 5, usage: 100, currentValue: 2, percentage: 2, resetMillis: 1_774_091_383_998),
            makeTokensLimit(unit: 6, number: 1, percentage: 77, resetMillis: 1_772_276_983_998),
            makeTokensLimit(unit: 3, number: 5, percentage: 36, resetMillis: nil)
        ], level: "lite")

        let mapped = try ZaiUsageMapper.mapQuotaLimit(body)

        XCTAssertEqual(mapped.plan, "lite")
        XCTAssertEqual(mapped.lines.count, 3)

        let daily = try XCTUnwrap(progress(mapped.lines, "Daily"))
        XCTAssertEqual(daily.used, 2)
        XCTAssertEqual(daily.limit, 100)
        XCTAssertEqual(daily.periodDurationMs, ZaiUsageMapper.dayPeriodMs)
        XCTAssertNotNil(daily.resetsAt)

        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 77)
        XCTAssertEqual(weekly.periodDurationMs, ZaiUsageMapper.weekPeriodMs)
        XCTAssertNotNil(weekly.resetsAt)

        let monthly = try XCTUnwrap(progress(mapped.lines, "Monthly"))
        XCTAssertEqual(monthly.used, 36)
        XCTAssertEqual(monthly.periodDurationMs, ZaiUsageMapper.monthPeriodMs)
        XCTAssertNil(monthly.resetsAt, "monthly entry has no nextResetTime in fixture")
    }

    func testSkipsUnknownUnit() throws {
        // A future unit number Z.ai introduces shouldn't crash or render an empty row — just drop it.
        let body = makeBody(limits: [
            makeTokensLimit(unit: 99, number: 1, percentage: 50, resetMillis: nil)
        ], level: "lite")

        let mapped = try ZaiUsageMapper.mapQuotaLimit(body)

        XCTAssertEqual(mapped.lines.count, 0)
    }

    func testRendersPartialPlan() throws {
        // User has only weekly quota enabled — daily/monthly entries are absent, not zero.
        let body = makeBody(limits: [
            makeTokensLimit(unit: 6, number: 1, percentage: 50, resetMillis: 1_772_276_983_998)
        ], level: "lite")

        let mapped = try ZaiUsageMapper.mapQuotaLimit(body)

        XCTAssertEqual(mapped.lines.count, 1)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 50)
        XCTAssertNil(progress(mapped.lines, "Daily"))
    }

    func testThrowsWhenNoDisplayableLimits() {
        let body = makeBody(limits: [], level: "lite")
        XCTAssertThrowsError(try ZaiUsageMapper.mapQuotaLimit(body)) { error in
            XCTAssertEqual(error as? ZaiUsageError, .quotaUnavailable)
        }
    }

    func testThrowsOnMissingDataEnvelope() {
        XCTAssertThrowsError(try ZaiUsageMapper.mapQuotaLimit(["code": 200])) { error in
            XCTAssertEqual(error as? ZaiUsageError, .invalidResponse)
        }
    }

    func testClampsOutOfRangePercentages() throws {
        // Z.ai has been observed to return negative or >100 percentages during clock drift; clamp
        // to the displayable range rather than render an empty/full meter that contradicts the limit.
        let body = makeBody(limits: [
            makeTimeLimit(unit: 5, usage: 100, currentValue: -5, percentage: -3, resetMillis: nil),
            makeTokensLimit(unit: 6, number: 1, percentage: 150, resetMillis: nil)
        ], level: "lite")

        let mapped = try ZaiUsageMapper.mapQuotaLimit(body)

        XCTAssertEqual(progress(mapped.lines, "Daily")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 100)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }
}

@MainActor
final class ZaiProviderTests: XCTestCase {
    func testRefreshWithoutCookiesReturnsNotLoggedIn() async {
        let provider = ZaiProvider(
            authStore: ZaiAuthStore(cookies: FakeBrowserCookieStore()),
            usageClient: ZaiUsageClient(http: QueueHTTPClient())
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(errorText(snapshot.lines), ZaiAuthError.notLoggedIn.localizedDescription)
    }

    func testRefreshUsesCookieHeaderFromAuthStore() async throws {
        let cookies = FakeBrowserCookieStore(["z.ai": ["session_id": "abc123", "jwt": "tok456"]])
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try makeBodyData(limits: [
                makeTokensLimit(unit: 6, number: 1, percentage: 50, resetMillis: nil)
            ], level: "lite"))
        ])
        let provider = ZaiProvider(
            authStore: ZaiAuthStore(cookies: cookies),
            usageClient: ZaiUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "lite")
        XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertEqual(httpClient.requests.count, 1)

        let request = try XCTUnwrap(httpClient.requests.first)
        let cookieHeader = try XCTUnwrap(request.headers["Cookie"])
        XCTAssertTrue(cookieHeader.contains("session_id=abc123"))
        XCTAssertTrue(cookieHeader.contains("jwt=tok456"))
    }

    func testRefreshHandles401AsNotLoggedIn() async {
        let cookies = FakeBrowserCookieStore(["z.ai": ["session_id": "expired"]])
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
        ])
        let provider = ZaiProvider(
            authStore: ZaiAuthStore(cookies: cookies),
            usageClient: ZaiUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), ZaiAuthError.notLoggedIn.localizedDescription)
    }

    func testRefreshHandlesEnvelopeCodeNot200() async throws {
        let cookies = FakeBrowserCookieStore(["z.ai": ["session_id": "valid"]])
        let body = try JSONSerialization.data(withJSONObject: [
            "code": 401, "msg": "unauthorized", "data": [:]
        ])
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: body)
        ])
        let provider = ZaiProvider(
            authStore: ZaiAuthStore(cookies: cookies),
            usageClient: ZaiUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(errorText(snapshot.lines), ZaiUsageError.quotaUnavailable.localizedDescription)
    }

    func testRefreshHandlesNon401ErrorAsQuotaUnavailable() async {
        let cookies = FakeBrowserCookieStore(["z.ai": ["session_id": "valid"]])
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8))
        ])
        let provider = ZaiProvider(
            authStore: ZaiAuthStore(cookies: cookies),
            usageClient: ZaiUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(errorText(snapshot.lines), ZaiUsageError.quotaUnavailable.localizedDescription)
    }

    private func errorText(_ lines: [MetricLine]) -> String? {
        guard case .badge(_, let text, _, _) = lines.first else {
            return nil
        }
        return text
    }
}

// MARK: - Fixtures

private func makeBody(limits: [[String: Any]], level: String) -> [String: Any] {
    ["code": 200, "msg": "Operation successful", "data": ["limits": limits, "level": level], "success": true]
}

private func makeBodyData(limits: [[String: Any]], level: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: makeBody(limits: limits, level: level))
}

private func makeTimeLimit(unit: Int, usage: Int, currentValue: Int, percentage: Double, resetMillis: Int64?) -> [String: Any] {
    var entry: [String: Any] = [
        "type": "TIME_LIMIT",
        "unit": unit,
        "usage": usage,
        "currentValue": currentValue,
        "remaining": usage - currentValue,
        "percentage": percentage
    ]
    if let reset = resetMillis {
        entry["nextResetTime"] = reset
    }
    return entry
}

private func makeTokensLimit(unit: Int, number: Int, percentage: Double, resetMillis: Int64?) -> [String: Any] {
    var entry: [String: Any] = [
        "type": "TOKENS_LIMIT",
        "unit": unit,
        "number": number,
        "percentage": percentage
    ]
    if let reset = resetMillis {
        entry["nextResetTime"] = reset
    }
    return entry
}