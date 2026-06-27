import CommonCrypto
import Foundation

/// Reusable credential source for web-cookie-based providers. Mirrors the indirection already used by
/// `SQLiteAccessing` / `KeychainAccessing` / `TextFileAccessing` so tests inject a fake without
/// touching the real Keychain or Chrome profile, and so a future port to Safari/Firefox only swaps the
/// concrete store, not the call sites.
///
/// The default implementation targets Chrome on macOS (Chromium's encrypted `Cookies` SQLite + the
/// "Chrome Safe Storage" Keychain entry). Safari's `Cookies.binarycookies` and Firefox's
/// `cookies.sqlite` use different encryption schemes — out of scope here; add a separate store type
/// when a provider actually needs them.
protocol BrowserCookieAccessing: Sendable {
    func cookie(forDomain domain: String, name: String) async throws -> String?
    func allCookies(forDomain domain: String) async throws -> [String: String]
}

enum BrowserCookieError: Error, LocalizedError, Equatable {
    case keychainUnavailable(String)
    case profileNotFound(String)
    case decryptionFailed
    case databaseReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable(let detail):
            return "Chrome Safe Storage keychain entry unavailable. \(detail)"
        case .profileNotFound(let detail):
            return "Chrome cookies database not found. \(detail)"
        case .decryptionFailed:
            return "Could not decrypt a Chrome cookie value."
        case .databaseReadFailed(let detail):
            return "Could not read Chrome cookies database. \(detail)"
        }
    }
}

/// Real implementation: reads Chrome Safe Storage key from the user's login keychain, derives the
/// Chromium cookie-encryption key via PBKDF2, and decrypts Chromium v10/v11 cookie blobs out of the
/// profile's `Cookies` SQLite file.
///
/// Why this is safe to ship:
/// - Reads only the user's *own* login keychain (`security find-generic-password`).
/// - Cookie values are decrypted in-memory only; never written to disk or logs.
/// - `AppLog` redacts any logged URL/body, so a misbehaving caller can't accidentally leak a cookie.
struct ChromeBrowserCookieStore: BrowserCookieAccessing {
    static let defaultProfilePath = "~/Library/Application Support/Google/Chrome/Default/Cookies"
    static let safeStorageService = "Chrome Safe Storage"

    /// Chromium's cookie-encryption parameters, lifted verbatim from
    /// `components/os_crypt/os_crypt_mac.mm`. The salt and IV are public constants; the key only
    /// depends on a value the user already trusts the keychain to gate.
    private static let keySalt = Data("saltysalt".utf8)
    private static let keyLength = 16
    private static let ivBytes = Data(repeating: 0x20, count: 16)
    private static let pbkdf2Iterations: UInt32 = 1
    /// Seconds between the Windows epoch (1601-01-01) and the Unix epoch (1970-01-01). Chrome stores
    /// `expires_utc` in microseconds since the Windows epoch.
    private static let windowsToUnixEpochSeconds: Double = 11_644_473_600
    /// Prefix tags Chromium writes ahead of encrypted cookie values. Both use the same key + IV.
    private static let validPrefixes: [Data] = [Data("v10".utf8), Data("v11".utf8)]

    let profilePath: String
    let sqlite: SQLiteAccessing
    let keychain: KeychainAccessing
    let now: @Sendable () -> Date

    init(
        profilePath: String = ChromeBrowserCookieStore.defaultProfilePath,
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.profilePath = profilePath
        self.sqlite = sqlite
        self.keychain = keychain
        self.now = now
    }

    func cookie(forDomain domain: String, name: String) async throws -> String? {
        try await allCookies(forDomain: domain)[name]
    }

    func allCookies(forDomain domain: String) async throws -> [String: String] {
        let key = try await loadEncryptionKey()
        let rows = try await queryCookieRows(forDomain: domain)
        var result: [String: String] = [:]
        for row in rows where !isExpired(row.expiresUtc) {
            guard let plaintext = decryptChromeCookie(hex: row.encryptedValueHex, key: key) else { continue }
            result[row.name] = plaintext
        }
        return result
    }

    // MARK: - Keychain

    private func loadEncryptionKey() async throws -> Data {
        guard let password = try keychain.readGenericPassword(service: Self.safeStorageService), !password.isEmpty else {
            throw BrowserCookieError.keychainUnavailable("Open Keychain Access and allow Chrome to unlock.")
        }
        return deriveKey(password: password)
    }

    private func deriveKey(password: String) -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: Self.keyLength)
        let status = derivedKey.withUnsafeMutableBytes { keyBytes -> Int32 in
            passwordData.withUnsafeBytes { passwordBytes -> Int32 in
                Self.keySalt.withUnsafeBytes { saltBytes -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        Self.keySalt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        Self.pbkdf2Iterations,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        Self.keyLength
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 key derivation failed with status \(status)")
        return derivedKey
    }

    // MARK: - SQLite

    private struct CookieRow {
        let name: String
        let encryptedValueHex: String
        let expiresUtc: Int64
    }

    private func queryCookieRows(forDomain domain: String) async throws -> [CookieRow] {
        let expandedPath = expandHome(profilePath)
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw BrowserCookieError.profileNotFound("Expected at \(expandedPath).")
        }
        let cutoffMicros = currentChromeMicros()
        let sql = """
        SELECT name, hex(encrypted_value), IFNULL(expires_utc, 0)
        FROM cookies
        WHERE host_key IN ('\(escapeSql(domain))', '.\(escapeSql(domain))')
          AND (IFNULL(expires_utc, 0) = 0 OR expires_utc > \(cutoffMicros))
        """
        let raw: String
        do {
            raw = try sqlite.queryValue(path: profilePath, sql: sql) ?? ""
        } catch {
            throw BrowserCookieError.databaseReadFailed(String(describing: error))
        }
        return parseCookieRows(raw)
    }

    private func parseCookieRows(_ raw: String) -> [CookieRow] {
        guard !raw.isEmpty else { return [] }
        var rows: [CookieRow] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // sqlite3 -separator default is "|"; queryValue's trim would have eaten leading/trailing
            // whitespace. The format is exactly `name|hex|expires_utc` per SELECT order.
            let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let expires = Int64(parts[2])
            else { continue }
            rows.append(CookieRow(
                name: String(parts[0]),
                encryptedValueHex: String(parts[1]),
                expiresUtc: expires
            ))
        }
        return rows
    }

    private func currentChromeMicros() -> Int64 {
        let unixSeconds = now().timeIntervalSince1970 + Self.windowsToUnixEpochSeconds
        return Int64(unixSeconds * 1_000_000)
    }

    private func isExpired(_ chromeMicros: Int64) -> Bool {
        guard chromeMicros > 0 else { return false } // session cookies (0) are never "expired"
        return chromeMicros <= currentChromeMicros()
    }

    /// Escape a single-quoted SQL literal. Cookies table values are untrusted domain strings, and the
    /// path is interpolated into the SQL string passed to the `sqlite3` CLI — strip single quotes and
    /// NULs so a malicious value can't break out of the literal.
    private func escapeSql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\0", with: "")
    }

    // MARK: - Decryption

    func decryptChromeCookie(hex: String, key: Data) -> String? {
        guard let blob = Data(hexString: hex), blob.count >= 3 else { return nil }
        let prefix = blob.prefix(3)
        guard Self.validPrefixes.contains(prefix) else { return nil }
        let cipher = blob.dropFirst(3)
        guard cipher.count > 0, cipher.count % 16 == 0 else { return nil }

        var plaintext = Data(count: cipher.count + 16)
        var decryptedLength: size_t = 0

        let status = plaintext.withUnsafeMutableBytes { plainBytes -> CCCryptorStatus in
            cipher.withUnsafeBytes { cipherBytes -> CCCryptorStatus in
                key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                    Self.ivBytes.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress, cipher.count,
                            plainBytes.baseAddress, plaintext.count,
                            &decryptedLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        plaintext = plaintext.prefix(decryptedLength)
        return String(data: plaintext, encoding: .utf8)
    }

    /// Mirror of Chromium's encrypt path (AES-128-CBC + PKCS#7 padding + "v10" prefix) so tests can
    /// round-trip a known plaintext through `decryptChromeCookie`. Not used by the production
    /// read path — Chrome writes the cookies; we only decrypt.
    static func encryptChromeCookie(plaintext: String, key: Data) throws -> Data {
        let plainData = Data(plaintext.utf8)
        var cipher = Data(count: plainData.count + 16)
        var cipherLength: size_t = 0

        let status = cipher.withUnsafeMutableBytes { cipherBytes -> CCCryptorStatus in
            plainData.withUnsafeBytes { plainBytes -> CCCryptorStatus in
                key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                    Self.ivBytes.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            plainBytes.baseAddress, plainData.count,
                            cipherBytes.baseAddress, cipher.count,
                            &cipherLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw BrowserCookieError.decryptionFailed
        }
        var output = Data("v10".utf8)
        output.append(cipher.prefix(cipherLength))
        return output
    }
}

private extension Data {
    /// Decode a lowercase or uppercase hex string into bytes. Invalid characters produce `nil` rather
    /// than a partially-decoded blob — cookie decryption is binary; we'd rather skip than guess.
    init?(hexString: String) {
        let cleaned = hexString.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// Encode as a lowercase hex string. Used by tests for round-trip assertions, never in the
    /// production read path.
    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}