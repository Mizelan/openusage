import Foundation

struct MiniMaxIoAuth: Hashable, Sendable {
    var cookieHeader: String
    var source: Source
    enum Source: Hashable, Sendable { case browserCookies }
}

enum MiniMaxIoAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "MiniMax chat session not found. Sign in to chat.minimax.io in Chrome and unlock Keychain."
        }
    }
}

struct MiniMaxIoAuthStore: Sendable {
    static let domain = "minimax.io"
    static let origin = "https://chat.minimax.io"
    static let referer = "https://chat.minimax.io/"

    let cookies: BrowserCookieAccessing

    init(cookies: BrowserCookieAccessing = ChromeBrowserCookieStore()) {
        self.cookies = cookies
    }

    func loadAuth() async throws -> MiniMaxIoAuth {
        let all = try await cookies.allCookies(forDomain: Self.domain)
        guard !all.isEmpty else {
            throw MiniMaxIoAuthError.notLoggedIn
        }
        let header = all
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        return MiniMaxIoAuth(cookieHeader: header, source: .browserCookies)
    }
}