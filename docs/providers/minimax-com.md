# MiniMax (minimax.com)

Tracks the MiniMax coding-plan quota for `www.minimax.com`, the developer-product surface
surfaced in upstream issue #222.

## What it tracks

| Metric | Meaning |
|---|---|
| Coding Plan | Coding-plan quota used (percent) |
| Credits | Residual credits balance in dollars (when the API exposes it) |
| Plan | Plan name (when the response carries one) |

## Where credentials come from

Same web-cookie pattern as the Z.ai provider — Chrome's `*.minimax.com` cookies are decrypted via
`BrowserCookieStore` and replayed on the request. Sign in to minimax.com in Chrome and unlock
the Keychain.

## Endpoints

`GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains` — the path from upstream
issue #222.

## Field fallbacks (response shape not documented)

The MiniMax coding-plan response shape isn't publicly documented. The mapper tries several
plausible layouts and renders whichever fits first:

| Field tried | Usage |
|---|---|
| `data.used` / `data.total` (or `used` / `total`) | Coding-plan quota percent |
| `data.remaining` / `data.limit` | Same, but `used = total - remaining` |
| `data.balance` / `data.creditBalance` / `data.credits` | Residual credits |

When a fresh sample is captured from a logged-in user, narrow the fallbacks in
`MiniMaxComUsageMapper` to one canonical shape.

## Error states

- **Not logged in** — no `*.minimax.com` cookies, or the server returns 401/403.
- **Quota unavailable** — the response didn't contain a recognizable `used`/`total`/`remaining`/
  `limit` pair, or the envelope `code` was non-200. Capture the actual response shape from a
  browser session and update the mapper fallbacks.

## Under the hood

`MiniMaxComAuthStore.loadAuth()` reads the cookie set; `MiniMaxComUsageClient.fetchCodingPlanRemains`
issues the GET with browser headers; `MiniMaxComUsageMapper` walks the field-fallback chain and
returns the first matching `MetricLine.progress` / `MetricLine.values`.
