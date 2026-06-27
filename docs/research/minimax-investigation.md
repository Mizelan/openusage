# MiniMax integration investigation

This is a runbook for the **failed attempt to ship three MiniMax providers** in commit `944d622`
of `Mizelan/openusage`. The provider code was removed; this document captures what was tried,
why each approach is unverified, and the concrete steps required to build a working one.

## TL;DR

- **z.ai provider**: kept. Endpoint `GET /api/monitor/usage/quota/limit` is documented in
  upstream issue #242 and the response shape (limits[] with `type` / `unit` / `percentage`) is
  publicly visible there.
- **MiniMax providers (all three)**: removed. There is **no public API documentation**, no
  publicly captured response shape, and no merged PR in the openusage repo to copy from. Earlier
  WebFetch results suggesting merged PRs `#168` / `#217` / `#230` / `#534` were **hallucinated by
  the model** — verified by `find . -name "*.swift" -path "*Sources/OpenUsage/Providers/MiniMax*"`
  returning empty and `grep -i minimax CHANGELOG.md` returning zero hits.

## What was attempted (and why each is unverified)

### 1. `MiniMaxComProvider` — `www.minimax.com` (Coding Plan API)

- **Endpoint guess**: `GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains`
  — sourced from upstream issue #222 (a feature request, not a working implementation).
- **Auth**: Chrome session cookies (per user direction; the issue requester proposed `Authorization:
  Bearer <api_key>` instead — never confirmed which the server actually accepts).
- **Response shape guess**: `{ code, data: { used?, total?, remaining?, limit?, balance?, ... } }`.
  The issue requester said "identical to the existing minimax.io integration", but neither shape
  is documented anywhere.
- **Why unverified**: No sample response captured. The mapper walked 6+ field-name fallbacks
  (`used` / `usedQuota` / `consumed` / `consumedQuota` / `remaining` / `remainingQuota`, etc.) —
  if the actual response uses different keys, the mapper silently returns `quotaUnavailable`.
- **Failure mode**: returns a "Quota unavailable" badge even on a successful login — user sees
  no signal of *why* (wrong endpoint? wrong field names? wrong domain cookies?).

### 2. `MiniMaxIoProvider` — `chat.minimax.io` (international chat platform)

- **Endpoint guess**: `GET https://chat.minimax.io/api/user/usage` — **pure speculation**, no
  source.
- **Auth**: Chrome session cookies.
- **Response shape guess**: `{ data: { weeklyUsed?, weeklyTotal?, weeklyRemaining?, weekResetAt?, ... } }`.
- **Why unverified**: zero public references. The only signal was upstream issue #666 ("Add
  MiniMax weekly usage limit tracking") which is a feature request, not an implementation note.
- **Failure mode**: 404 from the server. The provider degraded to `quotaUnavailable`, but it
  would also be impossible to distinguish "wrong URL" from "logged out" without a captured sample.

### 3. `MiniMaxPlatformProvider` — `platform.minimax.io` (model API)

- **Endpoint guess**: `GET https://platform.minimax.io/v1/dashboard/billing/credit_balance` —
  patterned after the Claude provider's billing probe, but the platform may not implement an
  Anthropic-compatible billing route at all.
- **Auth**: Chrome session cookies, plus a speculative `anthropic-version: 2023-06-01` header
  to route to a hypothetical Anthropic-compatible handler.
- **Response shape guess**: `{ credit_balance, balance_cents, monthly_spend, ... }`.
- **Why unverified**: `platform.minimax.io` documents page returns 404; nothing in `openusage`
  repo references the platform.

## Why "best-effort mapper" is the wrong shape here

OpenUsage's contract is "show real numbers, never invent them, never show stale data" — every
mapper throws `quotaUnavailable` (rendered as a "No data" badge) when fields are missing.
That's correct for **a documented API whose shape we partially know** (we just guard against
missing fields). It's wrong for **a guessed API whose shape we don't know at all** — the user
sees the same "No data" badge whether the endpoint is wrong, the cookie is missing, the auth
header is wrong, or the field name changed. No signal to debug.

The right pattern for unverified integrations is **not to ship them at all** — keep them out of
the repo until there's a captured response to validate against.

## What a working MiniMax provider requires

To add **any** MiniMax provider back to this fork, the user (or a contributor) needs to:

1. **Sign in** to the target MiniMax product in Chrome.
2. **Open DevTools → Network**, navigate the dashboard / subscription page until a usage
   endpoint fires.
3. **Capture** the request:
   - Method + URL (the endpoint)
   - Headers (`Cookie`, `Origin`, `Referer`, `User-Agent`, `Authorization` if any)
   - Response body (full JSON)
4. **Paste** the capture into a new `docs/research/minimax-{product}-capture.md` alongside the
   expected field meanings.
5. Open a PR implementing the provider against **the actual captured shape**, not against a
   multi-fallback guess. The mapper should accept the one canonical shape and throw
   `quotaUnavailable` on deviation — same contract as every other provider.

The `BrowserCookieStore` infrastructure (added in commit `944d622`) handles steps 1–2's auth side
correctly for any future provider that wants to replay Chrome session cookies. It's a real
contribution; it stays.

## Reference

- Commit that introduced the speculative providers (now reverted): `944d622`
- Upstream removal-policy issue: #565
- z.ai feature request (worked, kept): #242
- MiniMax feature requests (unverified, blocked on capture): #666, #222, #317, #472, #536