import Foundation

/// MiniMax provider for `chat.minimax.io` — the international chat-platform product surfaced by
/// upstream issue #666 ("Add MiniMax weekly usage limit tracking").
///
/// The chat-platform quota endpoint isn't publicly documented; this provider makes a best-effort
/// attempt and degrades to `quotaUnavailable` if the endpoint shape changes. Update the endpoint
/// URL or mapper field fallbacks in one place when a real sample is captured from a logged-in
/// browser session.
@MainActor
final class MiniMaxIoProvider: ProviderRuntime {
    let provider = Provider(id: "minimax-io", displayName: "MiniMax Chat", icon: .providerMark("minimax-io"))

    let authStore: MiniMaxIoAuthStore
    let usageClient: MiniMaxIoUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: MiniMaxIoAuthStore = MiniMaxIoAuthStore(),
        usageClient: MiniMaxIoUsageClient = MiniMaxIoUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "minimax-io.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly quota"),
            .percent(id: "minimax-io.daily", provider: provider, title: "Daily", metricLabel: "Daily quota")
        ]
    }

    func refresh() async -> ProviderSnapshot {
        let auth: MiniMaxIoAuth
        do {
            auth = try await authStore.loadAuth()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.fetchUsage(auth: auth)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxIoAuthError.notLoggedIn)
        }
        // A 404 from this best-guess endpoint means we picked the wrong URL — degrade to the
        // unavailable error rather than crash or render zeros.
        if response.statusCode == 404 {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxIoUsageError.quotaUnavailable)
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxIoUsageError.quotaUnavailable)
        }

        guard let body = ProviderParse.jsonObject(response.body) else {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxIoUsageError.invalidResponse)
        }

        if let envelopeCode = body["code"] as? Int, envelopeCode != 200 {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxIoUsageError.quotaUnavailable)
        }

        do {
            let mapped = try MiniMaxIoUsageMapper.mapUsage(body)
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