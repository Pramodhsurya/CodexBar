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

When both are configured, browser sign-in is preferred (it is a strict superset of what the token path reports) and
falls back to the token automatically if the browser session is missing, expired, or unreadable — the token path
keeps working exactly as before either way.

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

Browser sign-in path — a single authenticated fetch of `https://huggingface.co/settings/billing` (the account's own
billing page) using the browser session cookie, either imported automatically or pasted manually. CodexBar parses only
two figures out of that page: the prepaid credit balance, and the exact current-period Inference Providers usage total
(the same number huggingface.co itself displays). Payment method and invoicing details present on that page are never
parsed, stored, or displayed.

## Display

The "Inference Providers" section shows username, request totals, credits used (current period), and — only when
browser sign-in supplied it — credits available. The "Subscription" section shows plan (Free/PRO), billing mode, and
the billing-period end date: "Renews" for PRO accounts (Hugging Face PRO auto-renews and the API exposes no
cancellation flag to say otherwise), "Billing period ends" for Free accounts (a billing-period boundary, not a
subscription claim). `subscriptionRenewsAt` (the menu card's "Renews: …" note) is set only for PRO accounts.

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
