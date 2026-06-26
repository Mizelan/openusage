import Foundation

/// Antigravity surfaces exactly two user-facing failures. Every per-strategy error (LS not running,
/// a transient Cloud Code 5xx, a decode miss) is swallowed and the next strategy is tried; only when
/// all strategies are exhausted does one of these reach the UI.
enum AntigravityError: Error, LocalizedError, Equatable {
    /// No usable credentials anywhere (no LS running, no keychain token, nothing cached).
    case notSignedIn
    /// A token was found but rejected (401/403) and a refresh couldn't recover it.
    case authExpired

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Start Antigravity or run `agy` and try again."
        case .authExpired:
            return "Antigravity sign-in expired. Open Antigravity or run `agy` to refresh."
        }
    }
}
