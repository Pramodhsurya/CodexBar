type HuggingFaceIdentity = {
  name?: unknown;
  isPro?: unknown;
  periodEnd?: unknown;
  billingMode?: unknown;
};

type HuggingFaceSession = {
  requestCount?: unknown;
  costCents?: unknown;
};

type HuggingFacePeriod = {
  period?: unknown;
  sessions?: unknown;
};

type HuggingFaceUsage = {
  currency?: unknown;
  periods?: unknown;
};

defineProvider({
  id: "huggingface",
  name: "Hugging Face",
  endpoints: ["https://huggingface.co"],
  auth: { type: "bearer", secret: "HF_TOKEN" },
  capabilities: ["http-status"],
  settings: [
    {
      key: "HF_TOKEN",
      title: "User access token",
      subtitle: "Read token used for personal Inference Providers billing usage.",
      type: "secure",
    },
  ],

  async fetchUsage(ctx) {
    function classifyStatus(status: number, operation: string): void {
      if (status === 401) {
        throw ctx.fail.authenticationExpired(
          "Hugging Face rejected the user access token. Create a read token at huggingface.co/settings/tokens.",
        );
      }
      if (status === 403) {
        throw ctx.fail.permissionDenied(`Hugging Face denied access to the ${operation}.`);
      }
      if (status === 429) {
        throw ctx.fail.rateLimited("Hugging Face billing API rate limit exceeded.");
      }
      if (status >= 500) {
        throw ctx.fail.providerUnavailable(`Hugging Face ${operation} returned HTTP ${status}.`);
      }
      if (status < 200 || status >= 300) {
        throw ctx.fail.apiFailure(`Hugging Face ${operation} returned HTTP ${status}.`);
      }
    }

    async function getJSON(url: string, operation: string): Promise<unknown> {
      let response: CodexBarHTTPTextResponse;
      try {
        response = await ctx.http.get(url);
      } catch (error) {
        throw ctx.fail.networkFailure(
          `Hugging Face ${operation} network error: ${(error as Error)?.message || String(error)}`,
        );
      }
      classifyStatus(response.status, operation);
      try {
        return JSON.parse(response.bodyText) as unknown;
      } catch (error) {
        void error;
        throw ctx.fail.parseFailure(`Hugging Face ${operation} response was not valid JSON.`);
      }
    }

    function object(value: unknown, path: string): Record<string, unknown> {
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw ctx.fail.parseFailure(`Hugging Face ${path} must be an object.`);
      }
      return value as Record<string, unknown>;
    }

    function finiteNumber(value: unknown, path: string): number {
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
        throw ctx.fail.parseFailure(`Hugging Face ${path} must be a non-negative number.`);
      }
      return value;
    }

    function optionalEpochSecondsDate(value: unknown, path: string): Date | null {
      if (value === null || value === undefined) {
        return null;
      }
      if (typeof value === "number") {
        if (!Number.isFinite(value) || value <= 0) {
          return null;
        }
        const date = new Date(value * 1000);
        if (!Number.isFinite(date.getTime())) {
          throw ctx.fail.parseFailure(`Hugging Face ${path} is not a valid Unix timestamp.`);
        }
        return date;
      }
      if (typeof value === "string") {
        const trimmed = value.trim();
        if (!trimmed) {
          return null;
        }
        const date = new Date(trimmed);
        if (!Number.isFinite(date.getTime())) {
          throw ctx.fail.parseFailure(`Hugging Face ${path} is not a valid date.`);
        }
        return date;
      }
      throw ctx.fail.parseFailure(`Hugging Face ${path} must be a Unix timestamp or date string.`);
    }

    function optionalTitleCaseString(value: unknown, path: string): string | null {
      if (value === null || value === undefined) {
        return null;
      }
      if (typeof value !== "string") {
        throw ctx.fail.parseFailure(`Hugging Face ${path} must be a string.`);
      }
      const trimmed = value.trim();
      if (!trimmed) {
        return null;
      }
      return trimmed.charAt(0).toUpperCase() + trimmed.slice(1).toLowerCase();
    }

    const identityPayload = (await getJSON(
      "https://huggingface.co/api/whoami-v2",
      "identity request",
    )) as HuggingFaceIdentity;
    const account = object(identityPayload, "identity response") as HuggingFaceIdentity;
    if (typeof account.name !== "string" || !account.name.trim()) {
      throw ctx.fail.parseFailure("Hugging Face identity response is missing name.");
    }
    if (typeof account.isPro !== "boolean") {
      throw ctx.fail.parseFailure("Hugging Face identity response is missing isPro.");
    }
    const username = account.name.trim();
    const plan = account.isPro ? "PRO" : "Free";
    const periodEnd = optionalEpochSecondsDate(account.periodEnd, "identity response periodEnd");
    const billingMode = optionalTitleCaseString(account.billingMode, "identity response billingMode");

    const now = ctx.date.now();
    const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
    const startDate = monthStart.toISOString();
    const endDate = now.toISOString();
    const usageURL =
      "https://huggingface.co/api/settings/billing/usage-by-inference-session" +
      `?startDate=${encodeURIComponent(startDate)}&endDate=${encodeURIComponent(endDate)}`;
    const usagePayload = (await getJSON(usageURL, "billing request")) as HuggingFaceUsage;
    const usage = object(usagePayload, "billing response") as HuggingFaceUsage;
    if (typeof usage.currency !== "string" || !/^[A-Za-z]{3}$/.test(usage.currency.trim())) {
      throw ctx.fail.parseFailure("Hugging Face billing currency must be a three-letter code.");
    }
    if (!Array.isArray(usage.periods)) {
      throw ctx.fail.parseFailure("Hugging Face billing periods must be an array.");
    }

    const currency = usage.currency.trim().toUpperCase();
    let requestCount = 0;
    let costCents = 0;
    const chartPoints: Array<{ label: string; value: number }> = [];
    for (let periodIndex = 0; periodIndex < usage.periods.length; periodIndex += 1) {
      const period = object(usage.periods[periodIndex], `periods[${periodIndex}]`) as HuggingFacePeriod;
      if (typeof period.period !== "string" || !period.period.trim()) {
        throw ctx.fail.parseFailure(`Hugging Face periods[${periodIndex}].period must be a date string.`);
      }
      if (!Array.isArray(period.sessions)) {
        throw ctx.fail.parseFailure(`Hugging Face periods[${periodIndex}].sessions must be an array.`);
      }
      let periodCostCents = 0;
      for (let sessionIndex = 0; sessionIndex < period.sessions.length; sessionIndex += 1) {
        const session = object(
          period.sessions[sessionIndex],
          `periods[${periodIndex}].sessions[${sessionIndex}]`,
        ) as HuggingFaceSession;
        const requests = finiteNumber(
          session.requestCount,
          `periods[${periodIndex}].sessions[${sessionIndex}].requestCount`,
        );
        const cost = finiteNumber(session.costCents, `periods[${periodIndex}].sessions[${sessionIndex}].costCents`);
        requestCount += requests;
        costCents += cost;
        periodCostCents += cost;
      }
      const date = new Date(period.period);
      if (!Number.isFinite(date.getTime())) {
        throw ctx.fail.parseFailure(`Hugging Face periods[${periodIndex}].period is not a valid date.`);
      }
      chartPoints.push({ label: date.toISOString().slice(0, 10), value: periodCostCents / 100 });
    }

    const usageCost = costCents / 100;
    const rows: CodexBarDetailRow[] = [
      { label: "Username", value: username },
      { label: "Requests", value: ctx.format.number(requestCount, { maximumFractionDigits: 0 }) },
      {
        label: "API-reported usage",
        value: `${currency} ${usageCost.toFixed(2)}`,
        secondaryValue: "Current month",
      },
    ];
    const usageSection: CodexBarDetailSection = { title: "Inference Providers", rows };
    if (chartPoints.length) {
      usageSection.chart = { kind: "bars", title: "Monthly usage", unit: currency, points: chartPoints };
    }

    const isRenewingSubscription = account.isPro === true && periodEnd !== null;
    const subscriptionRows: CodexBarDetailRow[] = [{ label: "Plan", value: plan }];
    if (billingMode) {
      subscriptionRows.push({ label: "Billing", value: billingMode });
    }
    if (periodEnd) {
      subscriptionRows.push({
        label: isRenewingSubscription ? "Renews" : "Billing period ends",
        value: periodEnd.toISOString().slice(0, 10),
        secondaryValue: "UTC",
      });
    }
    const subscriptionSection: CodexBarDetailSection = { title: "Subscription", rows: subscriptionRows };

    return {
      cost: { used: usageCost, currency, period: "Current month usage" },
      identity: { accountID: username, loginMethod: plan },
      subscriptionRenewsAt: isRenewingSubscription ? periodEnd : undefined,
      dataConfidence: "exact",
      details: [usageSection, subscriptionSection],
    };
  },
});
