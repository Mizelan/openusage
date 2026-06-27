import Foundation

/// MiniMax provider for `www.minimax.com` — the coding-plan product surfaced by issue #222.
/// Auth via the user's live Chrome session on `minimax.com`; endpoint is the public coding-plan
/// remaining-quota route.
@MainActor
final class MiniMaxComProvider: ProviderRuntime {
    let provider = Provider(id: "minimax-com", displayName: "MiniMax", icon: .providerMark("minimax-com"))

    let authStore: MiniMaxComAuthStore
    let usageClient: MiniMaxComUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: MiniMaxComAuthStore = MiniMaxComAuthStore(),
        usageClient: MiniMaxComUsageClient = MiniMaxComUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "minimax-com.coding", provider: provider, title: "Coding Plan", metricLabel: "Coding plan usage"),
            .values(id: "minimax-com.credits", provider: provider, title: "Credits", metricLabel: "Credits balance")
        ]
    }

    func refresh() async -> ProviderSnapshot {
        let auth: MiniMaxComAuth
        do {
            auth = try await authStore.loadAuth()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.fetchCodingPlanRemains(auth: auth)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxComAuthError.notLoggedIn)
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxComUsageError.quotaUnavailable)
        }

        guard let body = ProviderParse.jsonObject(response.body) else {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxComUsageError.invalidResponse)
        }

        // Top-level `code` envelope check (matches z.ai and most MiniMax product responses).
        if let envelopeCode = body["code"] as? Int, envelopeCode != 200 {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxComUsageError.quotaUnavailable)
        }

        do {
            let mapped = try MiniMaxComUsageMapper.mapCodingPlanRemains(body)
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