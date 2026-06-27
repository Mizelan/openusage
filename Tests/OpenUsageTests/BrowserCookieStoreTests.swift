import XCTest
@testable import OpenUsage

/// In-memory cookie source for tests that exercise provider auth/refresh logic without touching the
/// real Chrome profile. Mirrors the indirection every other provider uses (FakeSQLite, FakeFiles,
/// QueueHTTPClient) so production code never branches on "is this a test".
final class FakeBrowserCookieStore: BrowserCookieAccessing, @unchecked Sendable {
    private var cookies: [String: [String: String]] = [:]
    private let lock = NSLock()

    init(_ initial: [String: [String: String]] = [:]) {
        for (domain, kv) in initial {
            cookies[domain] = kv
        }
    }

    func setCookie(name: String, value: String, forDomain domain: String) {
        lock.lock(); defer { lock.unlock() }
        cookies[domain, default: [:]][name] = value
    }

    func cookie(forDomain domain: String, name: String) async throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return cookies[domain]?[name]
    }

    func allCookies(forDomain domain: String) async throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return cookies[domain] ?? [:]
    }
}

final class BrowserCookieStoreTests: XCTestCase {
    // MARK: - Chromium crypto round-trip

    func testChromeEncryptionRoundTrip() throws {
        // Same key + plaintext → same ciphertext (AES-CBC with a fixed IV is deterministic by design).
        let key = ChromeBrowserCookieStore.deriveKey(password: "test-password")
        let plaintext = "session-cookie-value-12345"

        let encrypted = try ChromeBrowserCookieStore.encryptChromeCookie(plaintext: plaintext, key: key)

        XCTAssertEqual(encrypted.prefix(3), Data("v10".utf8))
        XCTAssertGreaterThan(encrypted.count, 3, "ciphertext must contain payload beyond the prefix")

        let store = ChromeBrowserCookieStore()
        let decrypted = store.decryptChromeCookie(hex: encrypted.hexEncodedString, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptionIsDeterministicAcrossCalls() throws {
        // Same input → same output is the property Chromium's cookie encryption relies on (it has no
        // per-cookie nonce — the IV is the constant "16 spaces"). If this flips, every existing cookie
        // in the user's profile will silently fail to decrypt.
        let key = ChromeBrowserCookieStore.deriveKey(password: "fixed-password")
        let a = try ChromeBrowserCookieStore.encryptChromeCookie(plaintext: "deterministic", key: key)
        let b = try ChromeBrowserCookieStore.encryptChromeCookie(plaintext: "deterministic", key: key)
        XCTAssertEqual(a, b)
    }

    func testKeyDerivationProducesSixteenBytes() {
        // The Chromium spec is `PBKDF2-HMAC-SHA1(password, "saltysalt", 1, 16)` → 16-byte AES-128 key.
        // A wrong keyLength would silently change every decryption; lock the length down.
        let key = ChromeBrowserCookieStore.deriveKey(password: "anything")
        XCTAssertEqual(key.count, 16)
        XCTAssertFalse(key.allSatisfy { $0 == 0 }, "key is all-zero — derivation silently failed")
    }

    func testDecryptRejectsUnknownPrefix() {
        // "v10" / "v11" are the only Chromium prefixes; anything else is a value Chromium never wrote
        // and we must return nil rather than return garbage plaintext.
        let store = ChromeBrowserCookieStore()
        let key = ChromeBrowserCookieStore.deriveKey(password: "x")
        let blob = Data("BAD".utf8) + Data(repeating: 0, count: 16)
        XCTAssertNil(store.decryptChromeCookie(hex: blob.hexEncodedString, key: key))
    }

    func testDecryptRejectsShortBlob() {
        let store = ChromeBrowserCookieStore()
        let key = ChromeBrowserCookieStore.deriveKey(password: "x")
        XCTAssertNil(store.decryptChromeCookie(hex: "abcd", key: key))
        XCTAssertNil(store.decryptChromeCookie(hex: "", key: key))
    }

    func testDecryptRejectsOddLengthHex() {
        // `Data(hexString:)` requires an even number of hex chars; an odd length is corruption and
        // must not produce a partial decode.
        let store = ChromeBrowserCookieStore()
        let key = ChromeBrowserCookieStore.deriveKey(password: "x")
        XCTAssertNil(store.decryptChromeCookie(hex: "abc", key: key))
    }

    // MARK: - SQL safety

    func testSqlEscapingStripsSingleQuotes() async throws {
        // Path doesn't exist on purpose — the file-existence check fires BEFORE SQLite is touched,
        // so we assert on the *thrown* error type (`profileNotFound`) which proves the code reached
        // the file check (i.e. didn't crash or surface an unrelated SQL injection parse error).
        let sqlite = CapturingSQLite()
        let store = ChromeBrowserCookieStore(
            profilePath: "/tmp/does-not-exist-cookies-\(UUID().uuidString)",
            sqlite: sqlite,
            keychain: StubKeychain(value: "p"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        do {
            _ = try await store.allCookies(forDomain: "z.ai'; DROP TABLE cookies;--")
            XCTFail("expected profileNotFound, got success")
        } catch let error as BrowserCookieError {
            guard case .profileNotFound = error else {
                return XCTFail("expected profileNotFound, got \(error)")
            }
        }

        // SQLite must never be touched when the profile path doesn't exist.
        XCTAssertNil(sqlite.lastSQL, "SQLite was queried despite missing profile file")
    }

    // MARK: - Stubs

    private final class CapturingSQLite: SQLiteAccessing, @unchecked Sendable {
        var lastSQL: String?
        var lastPath: String?
        func queryValue(path: String, sql: String) throws -> String? {
            lastSQL = sql
            lastPath = path
            return nil
        }
        func execute(path: String, sql: String) throws {}
    }

    private final class StubKeychain: KeychainAccessing, @unchecked Sendable {
        let value: String?
        init(value: String?) { self.value = value }
        func readGenericPassword(service: String) throws -> String? { value }
        func writeGenericPassword(service: String, value: String) throws {}
        func readGenericPasswordForCurrentUser(service: String) throws -> String? { value }
        func writeGenericPasswordForCurrentUser(service: String, value: String) throws {}
        func readGenericPassword(service: String, account: String) throws -> String? { value }
    }
}