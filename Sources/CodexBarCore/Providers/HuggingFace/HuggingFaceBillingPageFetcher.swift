import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Deliberately narrow: only the fields CodexBar actually displays are decoded. `paymentMethod`
/// (card last4, Stripe payment method id) and `billingDetails` (invoicing/address info) are
/// present in the real page payload but have no matching property here, so `Decodable` silently
/// drops them -- they can never be parsed, stored, logged, or reach the UI.
struct HuggingFaceBillingPagePayload: Decodable {
    struct Entity: Decodable {
        let user: String?
        let isPro: Bool?
        let billingMode: String?
        let currentBalanceUsd: Double?
        let subscriptionIncludedCreditsUsd: Double?
    }

    struct Period: Decodable {
        let periodStart: String?
        let periodEnd: String?
    }

    struct Inference: Decodable {
        let usedNanoUsd: Double?
        let numRequests: Int?
        let providerDetails: [ProviderDetail]?
    }

    struct ProviderDetail: Decodable {
        let provider: String?
        let totalCostNanoUsd: Double?
    }

    struct Usage: Decodable {
        let inference: Inference?
    }

    let entity: Entity?
    let last3periods: [Period]?
    let usage: Usage?
}

/// Deliberately narrow, same rationale as `HuggingFaceBillingPagePayload`: `authorId` and
/// `authorAvatarUrl` are present on the real page payload but have no matching property here.
struct HuggingFaceModelUsagePayload: Decodable {
    struct Model: Decodable {
        let modelId: String?
        let numRequests: Int?
        let usedNanoUsd: Double?
        let lastRequestTimestamp: String?
    }

    struct Metrics: Decodable {
        let byModels: [Model]?
    }

    let inferenceUsageMetrics: Metrics?
}

public enum HuggingFaceBillingError: LocalizedError, Sendable, Equatable {
    case missingCookie
    case loginRequired
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "Missing Hugging Face cookie header."
        case .loginRequired:
            "Hugging Face login is required."
        case let .apiError(code):
            "Hugging Face billing fetch failed (HTTP \(code))."
        case let .parseFailed(message):
            "Failed to parse Hugging Face billing page: \(message)"
        }
    }

    /// True when the failure means "the browser cookie needs a fresh user-initiated import", not
    /// "the underlying account data is unavailable or wrong". Shared by the web fetch strategy
    /// (so it does not silently fall back to the poorer token-only data source) and by the app's
    /// refresh-failure handling (so it keeps showing the last good snapshot instead of clearing it).
    public static func isCookieRefreshNeeded(_ error: Error) -> Bool {
        if case HuggingFaceBillingError.loginRequired = error {
            return true
        }
        if case HuggingFaceBillingError.missingCookie = error {
            return true
        }
        #if os(macOS)
        if case HuggingFaceCookieImportError.missingCookie = error {
            return true
        }
        #endif
        return false
    }
}

/// Hugging Face's `/settings/billing` page, fetched with the account's own browser session
/// cookie. This supplements the token-authenticated Inference Providers API with two figures the
/// API cannot provide: the prepaid credit balance and the exact current-billing-period usage
/// total shown on the account's billing page.
public struct HuggingFaceBillingSnapshot: Sendable {
    public let username: String?
    public let isPro: Bool
    public let billingMode: String?
    public let currentBalanceUsd: Double?
    public let includedCreditsUsd: Double?
    public let usedThisPeriodUsd: Double
    public let requestCount: Int?
    public let periodStart: Date?
    public let periodEnd: Date?
    public let providerBreakdown: [(provider: String, usd: Double)]
    public let modelBreakdown: [(modelId: String, requests: Int, usd: Double)]
    public let updatedAt: Date

    public init(
        username: String?,
        isPro: Bool,
        billingMode: String?,
        currentBalanceUsd: Double?,
        includedCreditsUsd: Double?,
        usedThisPeriodUsd: Double,
        requestCount: Int?,
        periodStart: Date?,
        periodEnd: Date?,
        providerBreakdown: [(provider: String, usd: Double)] = [],
        modelBreakdown: [(modelId: String, requests: Int, usd: Double)] = [],
        updatedAt: Date = Date())
    {
        self.username = username
        self.isPro = isPro
        self.billingMode = billingMode
        self.currentBalanceUsd = currentBalanceUsd
        self.includedCreditsUsd = includedCreditsUsd
        self.usedThisPeriodUsd = usedThisPeriodUsd
        self.requestCount = requestCount
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.providerBreakdown = providerBreakdown
        self.modelBreakdown = modelBreakdown
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let providerCost = ProviderCostSnapshot(
            used: self.usedThisPeriodUsd,
            limit: 0,
            currencyCode: "USD",
            period: "Current period usage",
            resetsAt: self.periodEnd,
            balance: self.currentBalanceUsd,
            updatedAt: self.updatedAt)

        let identity = ProviderIdentitySnapshot(
            providerID: .huggingface,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.isPro ? "PRO" : "Free",
            accountID: self.username)

        let isRenewingSubscription = self.isPro && self.periodEnd != nil

        var details = [self.inferenceProvidersSection(), self.subscriptionSection(isRenewing: isRenewingSubscription)]
        if let modelsSection = self.modelsSection() {
            details.append(modelsSection)
        }

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: providerCost,
            details: details,
            subscriptionRenewsAt: isRenewingSubscription ? self.periodEnd : nil,
            updatedAt: self.updatedAt,
            identity: identity,
            dataConfidence: .exact)
    }

    private func inferenceProvidersSection() -> ProviderDetailSection {
        var rows: [ProviderDetailSection.Row] = []
        if let username {
            rows.append(.makeRow(label: "Username", value: username))
        }
        if let requestCount {
            rows.append(.makeRow(label: "Requests", value: Self.countString(requestCount)))
        }
        rows.append(.makeRow(
            label: "Credits used",
            value: "USD \(String(format: "%.2f", self.usedThisPeriodUsd))",
            secondaryValue: "Current period"))
        if let currentBalanceUsd {
            rows.append(.makeRow(
                label: "Credits available",
                value: "USD \(String(format: "%.2f", currentBalanceUsd))"))
        }

        let chart: ProviderDetailSection.Chart? = self.providerBreakdown.isEmpty ? nil : .makeChart(
            kind: .bars,
            title: "By provider",
            unit: "USD",
            points: self.providerBreakdown.map { (label: $0.provider, value: $0.usd) })

        return .makeSection(title: "Inference Providers", rows: rows, chart: chart)
    }

    private func subscriptionSection(isRenewing: Bool) -> ProviderDetailSection {
        var rows: [ProviderDetailSection.Row] = [
            .makeRow(label: "Plan", value: self.isPro ? "PRO" : "Free"),
        ]
        if let billingMode {
            rows.append(.makeRow(label: "Billing", value: billingMode))
        }
        if let periodEnd {
            rows.append(.makeRow(
                label: isRenewing ? "Renews" : "Billing period ends",
                value: Self.dayString(periodEnd),
                secondaryValue: "UTC"))
        }
        if let includedCreditsUsd, includedCreditsUsd > 0 {
            rows.append(.makeRow(
                label: "Included credits",
                value: "USD \(String(format: "%.2f", includedCreditsUsd))"))
        }
        return .makeSection(title: "Subscription", rows: rows)
    }

    /// Caps at the 8 highest-cost models so the menu card stays scannable; Hugging Face's own
    /// Inference Providers overview page shows a similarly bounded table by default.
    private static let maxModelRows = 8

    private func modelsSection() -> ProviderDetailSection? {
        guard !self.modelBreakdown.isEmpty else { return nil }
        let rows = self.modelBreakdown
            .sorted { $0.usd > $1.usd }
            .prefix(Self.maxModelRows)
            .map {
                ProviderDetailSection.Row.makeRow(
                    label: $0.modelId,
                    value: "USD \(String(format: "%.2f", $0.usd))",
                    secondaryValue: "\(Self.countString($0.requests)) requests")
            }
        return .makeSection(title: "Models", rows: rows)
    }

    private static func countString(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public enum HuggingFaceBillingPageFetcher {
    private static let billingURL = URL(string: "https://huggingface.co/settings/billing")!
    private static let modelUsageURL = URL(string: "https://huggingface.co/settings/inference-providers/overview")!
    private static let defaultTransport: ProviderHTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = ProviderHTTPClient.redirectGuardedSession(configuration: configuration)
        return ProviderHTTPClient(session: session)
    }()

    public static func fetchBilling(
        cookieHeader: String,
        session transportOverride: (any ProviderHTTPTransport)? = nil,
        timeout: TimeInterval = 15,
        now: Date = Date()) async throws -> HuggingFaceBillingSnapshot
    {
        guard let cookieHeader = CookieHeaderNormalizer.normalize(cookieHeader) else {
            throw HuggingFaceBillingError.missingCookie
        }

        var request = URLRequest(url: self.billingURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let transport = transportOverride ?? self.defaultTransport
        let response = try await transport.response(for: request)
        if response.statusCode == 401 || response.statusCode == 403 ||
            (300..<400).contains(response.statusCode)
        {
            throw HuggingFaceBillingError.loginRequired
        }
        guard response.response.url?.scheme?.lowercased() == "https",
              response.response.url?.host?.lowercased() == self.billingURL.host?.lowercased()
        else {
            throw HuggingFaceBillingError.loginRequired
        }
        guard response.statusCode == 200 else {
            throw HuggingFaceBillingError.apiError(response.statusCode)
        }
        guard let html = String(data: response.data, encoding: .utf8), !html.isEmpty else {
            throw HuggingFaceBillingError.parseFailed("Billing page response was empty.")
        }
        let snapshot = try self.parseBillingHTML(html, now: now)
        let modelBreakdown = await self.fetchModelBreakdown(
            cookieHeader: cookieHeader,
            transport: transport,
            timeout: timeout)
        guard !modelBreakdown.isEmpty else { return snapshot }
        return HuggingFaceBillingSnapshot(
            username: snapshot.username,
            isPro: snapshot.isPro,
            billingMode: snapshot.billingMode,
            currentBalanceUsd: snapshot.currentBalanceUsd,
            includedCreditsUsd: snapshot.includedCreditsUsd,
            usedThisPeriodUsd: snapshot.usedThisPeriodUsd,
            requestCount: snapshot.requestCount,
            periodStart: snapshot.periodStart,
            periodEnd: snapshot.periodEnd,
            providerBreakdown: snapshot.providerBreakdown,
            modelBreakdown: modelBreakdown,
            updatedAt: snapshot.updatedAt)
    }

    /// Best-effort enrichment: the per-model breakdown lives on a separate settings page. A
    /// failure here (network error, unexpected shape, or a session that can't reach this specific
    /// page) never fails the primary billing fetch -- balance and current-period spend are the
    /// core, historically-supported contract of this fetcher.
    private static func fetchModelBreakdown(
        cookieHeader: String,
        transport: any ProviderHTTPTransport,
        timeout: TimeInterval) async -> [(modelId: String, requests: Int, usd: Double)]
    {
        var request = URLRequest(url: self.modelUsageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        guard let response = try? await transport.response(for: request),
              response.statusCode == 200,
              response.response.url?.scheme?.lowercased() == "https",
              response.response.url?.host?.lowercased() == self.modelUsageURL.host?.lowercased(),
              let html = String(data: response.data, encoding: .utf8), !html.isEmpty
        else {
            return []
        }
        return self.parseModelBreakdown(html)
    }

    static func parseModelBreakdown(_ html: String) -> [(modelId: String, requests: Int, usd: Double)] {
        let decoder = JSONDecoder()
        for candidate in self.dataPropsCandidates(in: html) {
            let decoded = self.decodeHTMLEntities(candidate)
            guard let data = decoded.data(using: .utf8),
                  let payload = try? decoder.decode(HuggingFaceModelUsagePayload.self, from: data),
                  let models = payload.inferenceUsageMetrics?.byModels, !models.isEmpty
            else {
                continue
            }
            return models.compactMap { model in
                guard let modelId = model.modelId, let usedNanoUsd = model.usedNanoUsd else { return nil }
                return (modelId: modelId, requests: model.numRequests ?? 0, usd: usedNanoUsd / 1_000_000_000.0)
            }
        }
        return []
    }

    /// The page embeds its data as one or more HTML-entity-escaped JSON blobs in `data-props="..."`
    /// attributes -- other unrelated components reuse the same attribute name, so the target blob
    /// is selected by content (first one that both decodes and carries a balance) rather than by
    /// position or length.
    static func parseBillingHTML(_ html: String, now: Date = Date()) throws -> HuggingFaceBillingSnapshot {
        let decoder = JSONDecoder()
        for candidate in self.dataPropsCandidates(in: html) {
            let decoded = self.decodeHTMLEntities(candidate)
            guard let data = decoded.data(using: .utf8),
                  let payload = try? decoder.decode(HuggingFaceBillingPagePayload.self, from: data),
                  payload.entity?.currentBalanceUsd != nil
            else {
                continue
            }
            return self.makeSnapshot(from: payload, now: now)
        }

        if self.looksLikeLoginPage(html) {
            throw HuggingFaceBillingError.loginRequired
        }
        throw HuggingFaceBillingError.parseFailed("Billing data was not found on the page.")
    }

    private static func makeSnapshot(
        from payload: HuggingFaceBillingPagePayload,
        now: Date) -> HuggingFaceBillingSnapshot
    {
        let entity = payload.entity
        let inference = payload.usage?.inference
        let period = payload.last3periods?.first

        let providerBreakdown: [(provider: String, usd: Double)] = (inference?.providerDetails ?? [])
            .compactMap { detail in
                guard let provider = detail.provider, let costNanoUsd = detail.totalCostNanoUsd else { return nil }
                return (provider: provider, usd: costNanoUsd / 1_000_000_000.0)
            }

        return HuggingFaceBillingSnapshot(
            username: entity?.user,
            isPro: entity?.isPro ?? false,
            billingMode: entity?.billingMode.map(self.titleCased),
            currentBalanceUsd: entity?.currentBalanceUsd,
            includedCreditsUsd: entity?.subscriptionIncludedCreditsUsd,
            usedThisPeriodUsd: (inference?.usedNanoUsd ?? 0) / 1_000_000_000.0,
            requestCount: inference?.numRequests,
            periodStart: period?.periodStart.flatMap(self.parseISODate),
            periodEnd: period?.periodEnd.flatMap(self.parseISODate),
            providerBreakdown: providerBreakdown,
            updatedAt: now)
    }

    private static func titleCased(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return String(first).uppercased() + trimmed.dropFirst().lowercased()
    }

    private static func parseISODate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func dataPropsCandidates(in html: String) -> [String] {
        self.matches(pattern: #"data-props="([^"]*)""#, in: html)
            .compactMap { self.capture(1, in: html, match: $0) }
    }

    private static func looksLikeLoginPage(_ html: String) -> Bool {
        let haystack = html.lowercased()
        return haystack.contains("action=\"/login\"")
            || haystack.contains("name=\"login\"")
            || haystack.contains("<title>log in")
            || haystack.contains("<title>sign in")
    }

    /// Matches the exact case/order used by JetBrains' status probe (repo precedent): `&amp;` is
    /// decoded before `&lt;`/`&gt;`/`&apos;`, not after. Hugging Face's page additionally uses
    /// `&#39;` for apostrophe, handled the same way.
    private static func decodeHTMLEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func matches(pattern: String, in html: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, options: [], range: range)
    }

    private static func capture(_ index: Int, in html: String, match: NSTextCheckingResult) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: html)
        else {
            return nil
        }
        let value = html[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
