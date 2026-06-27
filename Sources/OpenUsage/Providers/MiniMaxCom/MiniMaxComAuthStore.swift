import Foundation

struct MiniMaxComAuth: Hashable, Sendable {
    var cookieHeader: String
    var source: Source
    enum Source: Hashable, Sendable { case browserCookies }
}

enum MiniMaxComAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "MiniMax session not found. Sign in to minimax.com in Chrome and unlock Keychain."
        }
    }
}

struct MiniMaxComAuthStore: Sendable {
    static let domain = "minimax.com"
    static let origin = "https://www.minimax.com"
    static let referer = "https://www.minimax.com/"

    let cookies: BrowserCookieAccessing

    init(cookies: BrowserCookieAccessing = ChromeBrowserCookieStore()) {
        self.cookies = cookies
    }

    func loadAuth() async throws -> MiniMaxComAuth {
        let all = try await cookies.allCookies(forDomain: Self.domain)
        guard !all.isEmpty else {
            throw MiniMaxComAuthError.notLoggedIn
        }
        let header = all
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        return MiniMaxComAuth(cookieHeader: header, source: .browserCookies)
    }
}