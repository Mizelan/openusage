# MiniMax Chat (chat.minimax.io)

Tracks the MiniMax chat-platform weekly quota surfaced in upstream issue #666. The chat platform's
usage endpoint isn't publicly documented; this provider makes a best-effort attempt and degrades
to `quotaUnavailable` if the endpoint shape changes.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | Weekly token quota used (the primary metric) |
| Daily | Daily token quota used (when the API exposes it) |
| Plan | Plan / tier (when the response carries one) |

## Where credentials come from

Live Chrome session on `minimax.io`, decrypted via `BrowserCookieStore`. Sign in to
chat.minimax.io in Chrome and unlock the Keychain.

## Endpoints

`GET https://chat.minimax.io/api/user/usage` — best-guess path. If the server returns 404 the
provider falls back to the `quotaUnavailable` badge rather than rendering zeros.

## Field fallbacks

| Field tried | Usage |
|---|---|
| `weeklyUsed` / `weekUsed` / `usedWeekly` | Weekly quota numerator |
| `weeklyTotal` / `weekTotal` / `totalWeekly` | Weekly quota denominator |
| `weeklyRemaining` / `weekRemaining` | Same denominator with `used = total - remaining` |
| `weeklyResetAt` / `weekResetAt` | Weekly reset time |
| (analogous set for daily) | Daily quota when present |

Narrow the fallbacks in `MiniMaxIoUsageMapper` once a real sample is captured.

## Error states

- **Not logged in** — no `*.minimax.io` cookies, or 401/403.
- **Quota unavailable** — the response lacked any `used`/`total`/`remaining` pair, or the endpoint
  was wrong (404). Update the URL in `MiniMaxIoUsageClient.endpoint` and/or the field fallbacks in
  the mapper.

## Under the hood

`MiniMaxIoAuthStore.loadAuth()` → `MiniMaxIoUsageClient.fetchUsage` → `MiniMaxIoUsageMapper.mapUsage`
(weekly first, daily second; either may be absent). 404 from the endpoint maps to `quotaUnavailable`
specifically, so a wrong URL is distinguishable from a malformed response.
