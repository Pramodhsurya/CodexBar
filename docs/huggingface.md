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

- `GET https://huggingface.co/api/whoami-v2` for username and PRO status.
- `GET https://huggingface.co/api/settings/billing/usage-by-inference-session` with explicit UTC current-month
  `startDate` and `endDate` query parameters for personal Inference Providers request counts and API-reported usage cost.

Both requests send the token only through the `Authorization: Bearer` header.

## Display

The provider displays current-month Inference Providers usage cost, request totals, username, and Free/PRO account
status. "Exact" means CodexBar exactly aggregates the `costCents` values returned by this API; it does not mean the
amount is the account's net payable invoice. Hugging Face can apply included credits separately, so this reported usage
amount is independent of those credits and does not establish a final charge. CodexBar does not derive an
included-credit allowance, remaining credits, prepaid balance, quota percentage, or reset date because the endpoint does
not provide those values.

Requests made with a custom inference-provider key are billed by that provider rather than Hugging Face and therefore do
not appear in this Hugging Face usage amount.

## CLI Usage

```bash
codexbar --provider huggingface
# Alias:
codexbar --provider hf
```
