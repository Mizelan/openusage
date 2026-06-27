import Foundation

struct MiniMaxPlatformAuth: Hashable, Sendable {
    var cookieHeader: String
    var source: Source
    enum Source: Hashable, Sendable { case browserCookies }
}

enum MiniMaxPlatformAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "MiniMax Platform session not found. Sign in to platform.minimax.io in Chrome and unlock Keychain."
        }
    }
}

struct MiniMaxPlatformAuthStore: Sendable {
    static let domain = "platform.minimax.io"
    static let origin = "https://platform.minimax.io"
    static let referer = "https://platform.minimax.io/"

    let cookies: BrowserCookieAccessing

    init(cookies: BrowserCookieAccessing = ChromeBrowserCookieStore()) {
        self.cookies = cookies
    }

    func loadAuth() async throws -> MiniMaxPlatformAuth {
        let all = try await cookies.allCookies(forDomain: Self.domain)
        guard !all.isEmpty else {
            throw MiniMaxPlatformAuthError.notLoggedIn
        }
        let header = all
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        return MiniMaxPlatformAuth(cookieHeader: header, source: .browserCookies)
    }
}