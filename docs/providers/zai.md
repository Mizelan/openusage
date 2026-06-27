# Z.ai

Tracks your Z.ai subscription usage — daily, weekly, and monthly limits — using the same endpoint
the Z.ai subscription-management page calls in your browser.

## What it tracks

| Metric | Meaning |
|---|---|
| Daily | Daily time/quota used (the `TIME_LIMIT / unit=5` entry) |
| Weekly | Weekly token quota used (the `TOKENS_LIMIT / unit=6` entry) |
| Monthly | Monthly token quota used (the `TOKENS_LIMIT / unit=3` entry) |
| Plan | Your subscription tier (e.g. "lite") — pulled from the response's `level` field |

Each period is a separate `MetricLine.progress`; absent entries (your plan doesn't include that
period) are simply not shown — no zero placeholders.

## Where credentials come from

Z.ai is a web-only product with no API key registration, so OpenUsage authenticates by replaying
the cookies from your live Chrome session:

1. Reads the "Chrome Safe Storage" entry from the user's login Keychain (using the same
   `KeychainAccessing` / `SecurityKeychainAccessor` path as every other provider).
2. Decrypts the user's `*.z.ai` cookies out of `~/Library/Application Support/Google/Chrome/Default/Cookies`
   via `BrowserCookieStore` (PBKDF2 + AES-128-CBC, the same scheme Chromium uses for its own cookies).
3. Sends the cookie pair on the `Cookie` request header, plus `Origin` / `Referer` / `User-Agent`
   headers so the server's same-origin check accepts the request.

Chrome must be unlocked and you must be signed in to z.ai in Chrome. If you sign out in Chrome,
OpenUsage falls back to "not logged in" on the next refresh.

## Endpoints

`GET https://z.ai/api/monitor/usage/quota/limit` — the same path the Z.ai subscription page calls.

## Error states

- **Not logged in** — no cookies for `z.ai`, Chrome Safe Storage key unavailable, or the server
  returns 401/403. Sign in to z.ai in Chrome and unlock the Keychain, then refresh.
- **Quota unavailable** — the server returned 2xx but no displayable `limits[]` entries, or the
  `code` envelope was non-200. Try again later.
- **Decryption failed** — the Chrome cookie DB is corrupted or written by a newer Chromium with
  a different encryption scheme. File an issue with your Chrome version.

## Under the hood

`ZaiAuthStore.loadAuth()` returns a single `ZaiAuth{ cookieHeader }` (no token refresh — the
session is the session). `ZaiUsageClient.fetchQuota(auth:)` issues the GET; `ZaiUsageMapper`
turns each `limits[]` entry into a `MetricLine.progress` keyed on `(type, unit)` (see upstream
issue #242 for the unit code → period mapping).
