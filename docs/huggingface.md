---
summary: "Hugging Face provider: personal Inference Providers usage cost, request totals, plan/subscription info, and optional browser sign-in for credits available."
read_when:
  - Configuring Hugging Face usage
  - Debugging Hugging Face billing requests
---

# Hugging Face Provider

CodexBar reads personal Hugging Face Inference Providers billing usage with a user access token. Signing in with your
browser is optional and adds two figures the token API cannot provide: prepaid credits available, and current-period
usage matched exactly to what huggingface.co's own billing page shows. Organization billing, Hub compute services, and
custom provider-key charges are outside this provider's current scope.

## Authentication

Two independent, combinable auth methods:

**User access token** — create a read token in [Hugging Face token settings](https://huggingface.co/settings/tokens),
then add it in CodexBar Settings → Providers → Hugging Face. You can also set the canonical Hugging Face environment
variable, or configure it through the CLI:

```bash
export HF_TOKEN="hf_..."
# or
printf '%s' "$HF_TOKEN" | codexbar config set-api-key --provider huggingface --stdin
```

**Browser sign-in** (optional) — Settings → Providers → Hugging Face → Browser sign-in → Automatic imports your
Hugging Face session cookie from Chrome (default) each time CodexBar needs it, the same way several other providers in
CodexBar read a browser session. This requires being signed in to huggingface.co in your browser; nothing is sent
anywhere except to huggingface.co itself. Manual mode accepts a pasted `Cookie:` header instead. Set it to Off to
disable browser sign-in entirely and use only the token.

When both are configured, browser sign-in is preferred (it is a strict superset of what the token path reports). The
token path only steps in when browser sign-in has never produced data yet — for example, right after enabling
Hugging Face, before the first manual refresh imports a cookie — so you get something useful immediately instead of
an empty card.

Browser sign-in only (re-)imports a cookie on a user-initiated refresh (matching MiniMax/Qoder), never silently in the
background. Once a session is established, background refreshes deliberately do **not** fall back to the token path
when the cached cookie goes stale: doing so would silently replace the richer browser-sign-in data (credits
available, per-model breakdown) with the token path's narrower numbers on every routine background refresh. Instead,
the last known (browser-sign-in) data stays visible, marked stale after the first failed background refresh, exactly
like Claude's own web-session cookie expiry — until you click Refresh again, which re-imports a fresh cookie. A
non-cookie web failure (a real network/parse/server error, not just an expired session) still falls back to the
token path as usual, since that's a genuine data problem rather than "needs a click."

## Data Sources

Token path — official Hub API endpoints, token sent only via the `Authorization: Bearer` header:

- `GET https://huggingface.co/api/whoami-v2` for username, PRO status, `periodEnd` (billing period end, Unix seconds),
  and `billingMode` (`prepaid`/`postpaid`).
- `GET https://huggingface.co/api/settings/billing/usage` (best-effort) for the account's actual current billing-period
  start date, which is anchored to the account's signup/renewal day, not the calendar month. If this call fails or is
  rejected, CodexBar falls back to the calendar-month boundary it has always used, and labels the usage row "Current
  month" instead of "Current period" so the difference is visible rather than silently assumed.
- `GET https://huggingface.co/api/settings/billing/usage-by-inference-session`, bounded by the resolved period start
  through now, for personal Inference Providers request counts and cost.

Browser sign-in path — two authenticated page fetches using the browser session cookie, either imported automatically
or pasted manually:

- `https://huggingface.co/settings/billing` (required for this path). CodexBar parses only two figures out of that
  page: the prepaid credit balance, and the exact current-period Inference Providers usage total (the same number
  huggingface.co itself displays). Payment method and invoicing details present on that page are never parsed,
  stored, or displayed.
- `https://huggingface.co/settings/inference-providers/overview` (best-effort enrichment). CodexBar parses the
  per-model usage breakdown from this page — model ID, request count, and accrued cost — the same data behind
  huggingface.co's own "Models breakdown" table. A failure fetching or parsing this second page never fails the
  primary billing fetch; the balance and current-period spend from `/settings/billing` remain available on their own.

## Display

The "Inference Providers" section shows username, request totals, credits used (current period), and — only when
browser sign-in supplied it — credits available. The "Subscription" section shows plan (Free/PRO), billing mode, and
the billing-period end date: "Renews" for PRO accounts (Hugging Face PRO auto-renews and the API exposes no
cancellation flag to say otherwise), "Billing period ends" for Free accounts (a billing-period boundary, not a
subscription claim). `subscriptionRenewsAt` (the menu card's "Renews: …" note) is set only for PRO accounts.

When browser sign-in successfully reads the Inference Providers overview page, a "Models" section lists the 8
highest-cost models by accrued cost this period (model ID, cost, request count) — the per-model equivalent of the
provider-level `providerDetails` breakdown chart. This section is absent for token-only setups, since HF's token API
has no per-model breakdown endpoint.

The "By provider" bar chart (like all bar/line charts built from a generic `ProviderDetailSection.Chart`, shared with
Claude Admin API, Groq, MiniMax, DeepSeek, and ZoomMate) supports hovering a bar to see its exact label and value in a
small detail line below the chart — this is a shared menu-rendering capability, not Hugging-Face-specific.

"Exact" means CodexBar exactly aggregates the values the API/page returns; it does not mean the amount is the
account's net payable invoice. Hugging Face's own billing total can also include Jobs and ZeroGPU overquota usage,
which this provider deliberately does not fold in — it reports Inference Providers usage only, matching its documented
scope. CodexBar does not show a subscription price (Hugging Face exposes one nowhere in either path) and does not infer
quota percentages.

Requests made with a custom inference-provider key are billed by that provider rather than Hugging Face and therefore
do not appear in this Hugging Face usage amount.

## CLI Usage

```bash
codexbar --provider huggingface
# Alias:
codexbar --provider hf
# Force a source:
codexbar --provider huggingface --source api
codexbar --provider huggingface --source web
```
