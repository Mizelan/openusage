# MiniMax verification procedure

Companion to `minimax-investigation.md`. That doc explains *why* every previous MiniMax
implementation was unverified; this one explains *how* to capture the data needed to build a
working one. Follow this for **any** MiniMax product (minimax.com, chat.minimax.io,
platform.minimax.io, or a future one).

## TL;DR

1. Log in to the MiniMax product in Chrome.
2. Open DevTools → Network → reload the dashboard / subscription page.
3. Find the JSON request that carries usage/quota/balance data.
4. Copy **request URL + method + headers** and the **full response JSON** into a capture file.
5. Redact cookies/session tokens; keep field names.
6. Paste the capture at the end of `docs/research/minimax-investigation.md` (or a sibling
   `minimax-{product}-capture.md`) and open a PR — the provider can then be implemented against
   the actual shape.

## Step 1 — Log in, then open DevTools first

Chrome DevTools is order-sensitive: it must be open *before* the relevant request fires, otherwise
the request never appears in the panel.

1. Open Chrome. Log in to the MiniMax product you want to capture (`minimax.com`,
   `chat.minimax.io`, etc.). Keep this tab — don't close it.
2. Open a **second tab** to the same domain, then press `⌥⌘I` (DevTools).
3. Click the **Network** tab. Tick **Preserve log** so reloads don't clear requests.
4. Filter by **Fetch/XHR** (most usage endpoints are JSON via `fetch`, not plain HTML).
5. In the filter box, also type a hint like `usage`, `quota`, `limit`, `billing`, `subscription`,
   `plan`, `balance`, or `monitor` — the exact word varies per product.

## Step 2 — Trigger the request

Most usage endpoints fire when a dashboard or subscription page loads. Try in order:

1. The page you landed on after login (a "home" / "dashboard" page).
2. A "Subscription", "Plan", "API Keys", or "Usage" nav item.
3. If the dashboard shows live data without a nav, click a refresh / reload button if there is one.
4. Open the browser console (`⌥⌘J`) and type:
   ```js
   performance.getEntriesByType("resource")
     .filter(r => r.name.includes("/api/") || r.name.includes("usage") || r.name.includes("quota"))
   ```
   This lists XHR/fetch URLs that already fired — useful when the request happened before you
   opened DevTools.

If no relevant request appears, the product may load usage data via WebSocket or postMessage
embedded in an iframe. That's much harder to capture — note it and we can discuss.

## Step 3 — Identify the right request

Right-click each candidate request → **Copy → Copy as cURL**. Paste into a text file. Look for:

- **Response is JSON** (Content-Type `application/json`).
- **Response body has numbers that look like percentages, counts, or dollar amounts.**
- **URL path includes one of**: `/api/`, `/v1/`, `/usage`, `/quota`, `/billing`, `/plan`,
  `/monitor`, `/balance`, `/remains`, `/me`, `/user`.
- **Response size is small** (under 10 KB) — usage endpoints aren't big.

If multiple candidates look right, capture **all** of them — each may represent a different
metric (e.g., one for daily, one for weekly, one for monthly).

## Step 4 — Copy what I need

For each candidate, copy **these five things**:

| What | Where in DevTools | Why I need it |
|------|-------------------|---------------|
| Request URL (full, including query string) | Headers tab → General | The endpoint |
| Request method | Headers tab → General | GET vs POST |
| Request headers (Cookie, Origin, Referer, Authorization, anthropic-version, x-api-key, …) | Headers tab → Request Headers | Auth scheme |
| Response status | Headers tab → General | Success/failure |
| Response body | Response tab | The actual shape |

## Step 5 — Redact secrets

Replace any of these with `<REDACTED>` before sharing:

- Cookie header values: `Cookie: session_id=<REDACTED>; jwt=<REDACTED>`
- Authorization header: `Authorization: Bearer <REDACTED>`
- Any field in the response body whose name includes `token`, `secret`, `password`, `key`,
  `session`, `csrf`, `signature` — even if its value looks harmless.
- User identifiers (email, user_id) — replace with `<USER>` so I can still see field names.

**Keep** field names, structure, numeric values (percentages, balances), reset times, currency
codes. The numbers and field names are what I need to write the mapper — the actual user identity
isn't.

## Step 6 — Format the capture

Drop a fenced markdown block at the bottom of `minimax-investigation.md` (or a new sibling file
`minimax-{product}-capture.md`):

````markdown
## Capture: minimax.com coding-plan (2026-06-27)

Logged in via Chrome profile `Default`. Page loaded: `https://www.minimax.com/subscription`.

### Request

```
GET https://www.minimax.com/v1/api/openplatform/coding_plan/remains
Origin: https://www.minimax.com
Referer: https://www.minimax.com/subscription
Cookie: session_id=<REDACTED>; csrf=<REDACTED>
User-Agent: Mozilla/5.0 (...)
```

### Response (200)

```json
{
  "code": 200,
  "data": {
    "used": 30,
    "total": 100,
    "reset_at": 1774091383998
  }
}
```

### Notes

- Reset time is unix-ms (matches Z.ai).
- No `remaining` field — only `used` + `total`.
- No envelope at the top — `code` is at the root.
````

## Self-verification checklist

Before opening a PR with the capture, confirm:

- [ ] You are logged in (the page shows your actual usage data, not a "sign in" form).
- [ ] The request URL is `https://...` (not `http://`) — Origin checks typically reject plain HTTP.
- [ ] The response body has at least one numeric value that could be a quota/balance/percent.
- [ ] Cookie header is non-empty (otherwise the request wouldn't have succeeded).
- [ ] You redacted `session_id`, `jwt`, `csrf`, `Authorization`, and similar tokens.
- [ ] You kept field names exactly as the API returned them (don't translate `quota_used` → `used`).

If any of these fail, the capture isn't usable — try again or open a discussion issue first.

## After the capture lands

Once a capture is in the repo, the implementation is mechanical:

1. Add a `Sources/OpenUsage/Providers/MiniMax{CaptureTarget}/` directory with the four standard
   files (`Provider`, `AuthStore`, `UsageClient`, `UsageMapper`).
2. The `UsageClient` uses the captured URL and headers verbatim (Cookie is auto-injected from
   `BrowserCookieStore`).
3. The `UsageMapper` walks the captured JSON shape — **one** shape, not a fallback chain — and
   throws `quotaUnavailable` on deviation. Same contract as every other provider.
4. Tests in `Tests/OpenUsageTests/MiniMax{CaptureTarget}ProviderTests.swift` cover:
   - The captured response → expected `MetricLine` set.
   - 401/403 → `notLoggedIn` (cookie expired or wrong).
   - 200 with no recognizable fields → `quotaUnavailable`.
5. AppContainer registers the new provider; the icon and a `docs/providers/minimax-{target}.md`
   are added alongside.

## Quick smoke test for `BrowserCookieStore` before the capture

If Chrome is unlocked and you're logged in to a MiniMax product, you can confirm
`BrowserCookieStore` works without writing any new code:

```bash
# 1. Make sure the Chrome Safe Storage entry is in the login Keychain
security find-generic-password -s "Chrome Safe Storage" -w

# 2. Open the Chrome Cookies SQLite and confirm a cookie row for the target domain exists
sqlite3 "$HOME/Library/Application Support/Google/Chrome/Default/Cookies" \
  "SELECT name, host_key, length(encrypted_value) FROM cookies WHERE host_key LIKE '%minimax%' LIMIT 5"
```

The first command should print your Chrome Safe Storage password (or prompt you to unlock). The
second should list rows with non-zero `length(encrypted_value)`. If either fails, the cookie
auth path can't work for any provider on this machine — debug Chrome / Keychain access first.

## What if the product uses Bearer auth, not cookies?

Some products ignore browser cookies and require an `Authorization: Bearer <api_key>` header
instead. The capture will reveal this — if there's no `Cookie` header in the request, only
`Authorization`, the product is Bearer-auth.

In that case the implementation is different:

1. Read the API key from a file the user configures (e.g. `~/.minimax-com/auth.json`).
2. The `AuthStore` parses the file; the `UsageClient` adds `Authorization: Bearer <key>` per
   request.
3. No `BrowserCookieStore` involvement.

This is the pattern `Cursor` / `Grok` / `Codex` use for token-based providers — well-trodden in
the codebase. Just say so in the capture notes and we'll wire it up that way.