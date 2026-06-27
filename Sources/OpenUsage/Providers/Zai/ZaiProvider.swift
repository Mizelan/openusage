import Foundation

/// Z.ai provider for OpenUsage — surfaces the user's daily/weekly/monthly usage limits backed by the
/// z.ai subscription page's quota endpoint. Auth comes from the live Chrome session (cookies read
/// via `ChromeBrowserCookieStore`); there's no API key to paste.
@MainActor
final class ZaiProvider: ProviderRuntime {
    let provider = Provider(id: "zai", displayName: "Z.ai", icon: .providerMark("zai"))

    let authStore: ZaiAuthStore
    let usageClient: ZaiUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: ZaiAuthStore = ZaiAuthStore(),
        usageClient: ZaiUsageClient = ZaiUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "zai.daily", provider: provider, title: "Daily", metricLabel: "Daily usage"),
            .percent(id: "zai.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly usage"),
            .percent(id: "zai.monthly", provider: provider, title: "Monthly", metricLabel: "Monthly usage")
        ]
    }

    func refresh() async -> ProviderSnapshot {
        let auth: ZaiAuth
        do {
            auth = try await authStore.loadAuth()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.fetchQuota(auth: auth)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        guard (200..<300).contains(response.statusCode) else {
            // 401/403 → session expired / cleared; surface the auth error so the user knows to log
            // back in. Other non-2xx → generic quota unavailable.
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: ZaiAuthError.notLoggedIn)
            }
            return ProviderSnapshot.error(provider: provider, error: ZaiUsageError.quotaUnavailable)
        }

        guard let body = ProviderParse.jsonObject(response.body) else {
            return ProviderSnapshot.error(provider: provider, error: ZaiUsageError.invalidResponse)
        }

        // The response envelope carries a top-level `code` that's `200` on success. Some endpoints
        // return HTTP 200 with a non-200 envelope `code`; check both before declaring success.
        if let envelopeCode = body["code"] as? Int, envelopeCode != 200 {
            return ProviderSnapshot.error(provider: provider, error: ZaiUsageError.quotaUnavailable)
        }

        do {
            let mapped = try ZaiUsageMapper.mapQuotaLimit(body)
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now()
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}