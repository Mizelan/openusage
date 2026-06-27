import Foundation

/// MiniMax Platform provider for `platform.minimax.io` — the model API / billing surface.
///
/// Best-effort: the platform's billing endpoint isn't publicly documented, so this provider
/// degrades to `quotaUnavailable` on 404 or unknown response shapes. Update the endpoint URL or
/// mapper field fallbacks in one place when a real sample is captured from a logged-in browser.
@MainActor
final class MiniMaxPlatformProvider: ProviderRuntime {
    let provider = Provider(id: "minimax-platform", displayName: "MiniMax Platform", icon: .providerMark("minimax-platform"))

    let authStore: MiniMaxPlatformAuthStore
    let usageClient: MiniMaxPlatformUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: MiniMaxPlatformAuthStore = MiniMaxPlatformAuthStore(),
        usageClient: MiniMaxPlatformUsageClient = MiniMaxPlatformUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .values(id: "minimax-platform.balance", provider: provider, title: "Balance", metricLabel: "Balance", valueWord: "left"),
            .values(id: "minimax-platform.month", provider: provider, title: "This Month", metricLabel: "Monthly spend", valueWord: "spent")
        ]
    }

    func refresh() async -> ProviderSnapshot {
        let auth: MiniMaxPlatformAuth
        do {
            auth = try await authStore.loadAuth()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.fetchBalance(auth: auth)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxPlatformAuthError.notLoggedIn)
        }
        // 404 means the billing endpoint path was wrong — fall through to quotaUnavailable rather
        // than render zeros or crash. The user can fix the path in MiniMaxPlatformUsageClient.
        if response.statusCode == 404 {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxPlatformUsageError.quotaUnavailable)
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxPlatformUsageError.quotaUnavailable)
        }

        guard let body = ProviderParse.jsonObject(response.body) else {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxPlatformUsageError.invalidResponse)
        }

        if let envelopeCode = body["code"] as? Int, envelopeCode != 200 {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxPlatformUsageError.quotaUnavailable)
        }

        do {
            let mapped = try MiniMaxPlatformUsageMapper.mapBalance(body)
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