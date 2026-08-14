---
summary: "Hugging Face provider: personal Inference Providers usage cost and request totals."
read_when:
  - Configuring Hugging Face usage
  - Debugging Hugging Face billing requests
---

# Hugging Face Provider

CodexBar reads personal Hugging Face Inference Providers billing usage with a user access token. Organization billing,
Hub compute services, and custom provider-key charges are outside this provider's current scope.

## Authentication

Create a read token in [Hugging Face token settings](https://huggingface.co/settings/tokens), then add it in CodexBar
Settings → Providers → Hugging Face.

You can also set the canonical Hugging Face environment variable:

```bash
export HF_TOKEN="hf_..."
```

Or configure it through the CLI:

```bash
printf '%s' "$HF_TOKEN" | codexbar config set-api-key --provider huggingface --stdin
```

## Data Sources

CodexBar requests these official Hub API endpoints:

- `GET https://huggingface.co/api/whoami-v2` for username, PRO status, and the account's `periodEnd` (billing period
  end, Unix seconds) and `billingMode` (`prepaid`/`postpaid`).
- `GET https://huggingface.co/api/settings/billing/usage-by-inference-session` with explicit UTC current-month
  `startDate` and `endDate` query parameters for personal Inference Providers request counts and API-reported usage cost.

Both requests send the token only through the `Authorization: Bearer` header.

## Display

The provider displays current-month Inference Providers usage cost, request totals, and username in an "Inference
Providers" section, plus a "Subscription" section with plan (Free/PRO), billing mode, and the current billing period's
end date. "Exact" means CodexBar exactly aggregates the `costCents` values returned by this API; it does not mean the
amount is the account's net payable invoice. Hugging Face can apply included credits separately, so this reported usage
amount is independent of those credits and does not establish a final charge. CodexBar does not derive an
included-credit allowance, remaining credits, prepaid balance, quota percentage, or reset date because the endpoint does
not provide those values.

Requests made with a custom inference-provider key are billed by that provider rather than Hugging Face and therefore do
not appear in this Hugging Face usage amount.

## Subscription

For PRO accounts, `periodEnd` is shown as the "Renews" date, since Hugging Face PRO subscriptions auto-renew and the
API exposes no cancellation flag to distinguish an active renewal from a lapsing one. For Free accounts, the same field
(when present) is shown as "Billing period ends" instead, since it reflects a billing-period boundary rather than a
subscription. `subscriptionRenewsAt` (used for the menu card's "Renews: …" note) is set only for PRO accounts.

CodexBar does not show a subscription price, included-credit allowance, or prepaid credit balance for the PRO
subscription itself. Hugging Face's billing overview page (`huggingface.co/settings/billing`) surfaces those values,
but only via a server-rendered page authenticated by browser session cookie — there is no token-authenticated API that
returns them, so this provider does not fabricate or scrape that data.

## CLI Usage

```bash
codexbar --provider huggingface
# Alias:
codexbar --provider hf
```
