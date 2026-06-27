# MiniMax Platform (platform.minimax.io)

Tracks the MiniMax Platform (model API) account balance. Best-effort: the platform's billing
endpoint isn't publicly documented, so the provider degrades to `quotaUnavailable` if the endpoint
shape changes.

## What it tracks

| Metric | Meaning |
|---|---|
| Balance | Account credit balance in dollars |
| This Month | Current-month spend in dollars (when the API exposes it) |
| Plan | Plan / tier (when the response carries one) |

## Where credentials come from

Live Chrome session on `platform.minimax.io`, decrypted via `BrowserCookieStore`. Sign in to
platform.minimax.io in Chrome and unlock the Keychain.

## Endpoints

`GET https://platform.minimax.io/v1/dashboard/billing/credit_balance` — Anthropic-compatible
billing endpoint shape (matches the Claude provider's billing probe). 404 from this path means
the platform doesn't expose an Anthropic-compatible billing route; update the URL to whatever the
platform actually serves.

## Field fallbacks

| Field tried | Usage |
|---|---|
| `credit_balance` / `balance` | Dollar balance (decimal) |
| `balance_cents` | Dollar balance (cents → divided by 100) |
| `monthlySpend` / `current_month_spend` | This-month spend (decimal) |
| `monthly_spend_cents` | This-month spend (cents → divided by 100) |

Narrow these in `MiniMaxPlatformUsageMapper` once a real sample is captured.

## Error states

- **Not logged in** — no `*.platform.minimax.io` cookies, or 401/403.
- **Quota unavailable** — response lacked any recognizable balance field, or the endpoint
  returned 404 (URL mismatch).

## Under the hood

`MiniMaxPlatformAuthStore.loadAuth()` → `MiniMaxPlatformUsageClient.fetchBalance` →
`MiniMaxPlatformUsageMapper.mapBalance`. The provider sends an `anthropic-version: 2023-06-01`
header so the server's content negotiation routes to an Anthropic-compatible billing handler if
one exists.
