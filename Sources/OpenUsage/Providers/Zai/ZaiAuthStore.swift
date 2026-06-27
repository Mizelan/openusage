import Foundation

/// Auth state for a Z.ai session — whatever cookies the user's browser has stored for `z.ai`,
/// packaged as a `Cookie` request header. The web server decides which specific cookie values are
/// required; we just send them all.
struct ZaiAuth: Hashable, Sendable {
    /// The Cookie header value (e.g. `session_id=abc; jwt=xyz`). Always non-empty when this struct
    /// is returned; the auth loader throws `notLoggedIn` instead of producing an empty header.
    var cookieHeader: String
    var source: Source

    enum Source: Hashable, Sendable {
        case browserCookies
    }
}

enum ZaiAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Z.ai session not found. Sign in to z.ai in Chrome and unlock Keychain."
        }
    }
}

/// Reads the user's live Z.ai session cookies from Chrome (Keychain + `Cookies` SQLite) and packages
/// them into a request header. There is no on-disk credential file to fall back to — Z.ai is a pure
/// web-app, so the only authoritative credential source is the browser session.
struct ZaiAuthStore: Sendable {
    static let domain = "z.ai"
    static let origin = "https://z.ai"
    static let referer = "https://z.ai/manage-apikey/subscription"

    let cookies: BrowserCookieAccessing

    init(cookies: BrowserCookieAccessing = ChromeBrowserCookieStore()) {
        self.cookies = cookies
    }

    func loadAuth() async throws -> ZaiAuth {
        let all = try await cookies.allCookies(forDomain: Self.domain)
        guard !all.isEmpty else {
            throw ZaiAuthError.notLoggedIn
        }
        // Preserve name=value order lexicographically for determinism in tests; the server doesn't care.
        let header = all
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        return ZaiAuth(cookieHeader: header, source: .browserCookies)
    }
}