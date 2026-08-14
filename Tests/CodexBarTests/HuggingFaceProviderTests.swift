import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HuggingFaceProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `settings reader trims whitespace and quotes`() {
        #expect(HuggingFaceSettingsReader.apiKey(environment: [
            HuggingFaceSettingsReader.apiKeyEnvironmentKey: "  'hf_fixture'  ",
        ]) == "hf_fixture")
        #expect(HuggingFaceSettingsReader.apiKey(environment: [:]) == nil)
        #expect(HuggingFaceSettingsReader.apiKey(environment: [
            HuggingFaceSettingsReader.apiKeyEnvironmentKey: "   ",
        ]) == nil)
    }

    @Test
    func `config token projects into the canonical environment key`() {
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [HuggingFaceSettingsReader.apiKeyEnvironmentKey: "environment-token"],
            provider: .huggingface,
            config: ProviderConfig(id: .huggingface, apiKey: "config-token"))

        #expect(HuggingFaceSettingsReader.apiKey(environment: environment) == "config-token")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .huggingface))
    }

    @Test @MainActor
    func `descriptor and app registry include Hugging Face`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .huggingface)
        #expect(descriptor.metadata.displayName == "Hugging Face")
        #expect(descriptor.metadata.cliName == "huggingface")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.metadata.widgetSelectable == false)
        #expect(descriptor.metadata.dashboardURL == "https://huggingface.co/settings/billing")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.cli.aliases == ["hf"])
        #expect(descriptor.menuBarMetrics == .automaticOnly)
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-huggingface")

        let implementation = try #require(ProviderImplementationRegistry.implementation(for: .huggingface))
        #expect(implementation is HuggingFaceProviderImplementation)
    }

    @Test @MainActor
    func `app availability accepts environment or stored tokens and rejects missing tokens`() {
        let settings = testSettingsStore(suiteName: "HuggingFaceProviderTests-availability")
        let implementation = HuggingFaceProviderImplementation()

        #expect(implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .huggingface,
            settings: settings,
            environment: [HuggingFaceSettingsReader.apiKeyEnvironmentKey: "hf_environment"])))
        #expect(!implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .huggingface,
            settings: settings,
            environment: [:])))

        settings[providerConfig: .huggingface, field: .apiKey] = "hf_stored"
        #expect(implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .huggingface,
            settings: settings,
            environment: [:])))
    }

    @Test
    func `descriptor strategy availability and missing secret fail before transport`() async throws {
        let descriptor = HuggingFaceProviderDescriptor.makeDescriptor(transport: ProviderHTTPTransportStub { _ in
            Issue.record("Missing-secret fetch must not reach transport")
            throw URLError(.badURL)
        })
        let missingContext = Self.context(environment: [:])
        let strategy = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(missingContext).first)

        #expect(strategy.id == "huggingface.js")
        #expect(strategy.kind == .apiToken)
        let missingAvailable = await strategy.isAvailable(missingContext)
        #expect(!missingAvailable)
        await #expect(throws: ProviderPluginError.self) {
            _ = try await strategy.fetch(missingContext)
        }

        let availableContext = Self.context(environment: [
            HuggingFaceSettingsReader.apiKeyEnvironmentKey: "hf_fixture",
        ])
        #expect(await strategy.isAvailable(availableContext))
    }

    @Test
    func `descriptor fetch uses projected config token and bounded current month`() async throws {
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .huggingface,
            config: ProviderConfig(id: .huggingface, apiKey: "hf_configured"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hf_configured")
            switch url.path {
            case "/api/whoami-v2":
                return Self.response(
                    url: url,
                    body: #"{"name":"octocat","isPro":true,"periodEnd":1801440000,"billingMode":"prepaid"}"#)
            case "/api/settings/billing/usage-by-inference-session":
                try Self.expectBoundedCurrentMonthQuery(url)
                return Self.response(url: url, body: Self.usageFixture)
            default:
                Issue.record("Unexpected Hugging Face request: \(url.absoluteString)")
                throw URLError(.badURL)
            }
        }
        let descriptor = HuggingFaceProviderDescriptor.makeDescriptor(transport: transport)
        let result = try await descriptor.fetchPlan.fetchOutcome(
            context: Self.context(environment: environment),
            provider: .huggingface).result.get()

        #expect(result.sourceLabel == "api")
        #expect(result.strategyID == "huggingface.js")
        #expect(result.usage.providerCost?.used == 3.75)
        #expect(result.usage.subscriptionRenewsAt == Date(timeIntervalSince1970: 1_801_440_000))
        #expect(await transport.requests().count == 2)
    }

    @Test
    func `official requests aggregate current month personal inference usage`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(url.scheme == "https")
            #expect(url.host == "huggingface.co")
            #expect(url.fragment == nil)
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hf_fixture")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

            switch url.path {
            case "/api/whoami-v2":
                #expect(url.query == nil)
                return Self.response(
                    url: url,
                    body: #"""
                    {"name":"octocat","fullname":"Octo Cat","isPro":true,"periodEnd":1801440000,"billingMode":"prepaid"}
                    """#)
            case "/api/settings/billing/usage-by-inference-session":
                try Self.expectCurrentMonthQuery(url)
                return Self.response(url: url, body: Self.usageFixture)
            default:
                Issue.record("Unexpected Hugging Face request: \(url.absoluteString)")
                throw URLError(.badURL)
            }
        }

        let snapshot = try await Self.runtime(transport: transport).fetchUsage(
            secrets: ["HF_TOKEN": "hf_fixture"],
            now: Self.now)

        #expect(await transport.requests().count == 2)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.providerCost?.used == 3.75)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.period == "Current month usage")
        #expect(snapshot.identity?.providerID == .huggingface)
        #expect(snapshot.identity?.accountID == "octocat")
        #expect(snapshot.identity?.loginMethod == "PRO")
        #expect(snapshot.detailRow(label: "Requests")?.value == "9")
        #expect(snapshot.detailRow(label: "API-reported usage")?.value == "USD 3.75")
        #expect(snapshot.details.first?.chart?.points.map(\.value) == [3.75])
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.subscriptionRenewsAt == Date(timeIntervalSince1970: 1_801_440_000))
        #expect(snapshot.subscriptionExpiresAt == nil)
        #expect(snapshot.detailRow(label: "Plan")?.value == "PRO")
        #expect(snapshot.detailRow(label: "Billing")?.value == "Prepaid")
        #expect(snapshot.detailRow(label: "Renews")?.value == "2027-02-01")
        #expect(snapshot.details.count == 2)
        #expect(snapshot.details.last?.title == "Subscription")
    }

    @Test
    func `empty usage remains an exact zero-usage identity snapshot`() async throws {
        let snapshot = try await Self.fetch(usageBody: #"{"currency":"usd","periods":[]}"#)

        #expect(snapshot.providerCost?.used == 0)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.accountID == "octocat")
        #expect(snapshot.identity?.loginMethod == "Free")
        #expect(snapshot.detailRow(label: "Requests")?.value == "0")
        #expect(snapshot.details.first?.chart == nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.detailRow(label: "Renews") == nil)
    }

    @Test
    func `absent subscription fields stay a valid snapshot`() async throws {
        let snapshot = try await Self.fetch(identityBody: #"{"name":"octocat","isPro":false}"#)

        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.detailRow(label: "Billing") == nil)
        #expect(snapshot.detailRow(label: "Renews") == nil)
        #expect(snapshot.detailRow(label: "Billing period ends") == nil)
        #expect(snapshot.providerCost?.used == 3.75)
    }

    @Test
    func `ISO period end strings are accepted`() async throws {
        let snapshot = try await Self.fetch(identityBody: #"""
        {"name":"octocat","isPro":true,"periodEnd":"2027-02-01T00:00:00Z","billingMode":"prepaid"}
        """#)

        #expect(snapshot.subscriptionRenewsAt == Date(timeIntervalSince1970: 1_801_440_000))
        #expect(snapshot.detailRow(label: "Renews")?.value == "2027-02-01")
    }

    @Test
    func `non PRO period end is reported without claiming a renewal`() async throws {
        let snapshot = try await Self.fetch(identityBody: #"{"name":"octocat","isPro":false,"periodEnd":1801440000}"#)

        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.detailRow(label: "Billing period ends")?.value == "2027-02-01")
        #expect(snapshot.detailRow(label: "Renews") == nil)
    }

    @Test
    func `zero period end is treated as no subscription`() async throws {
        let snapshot = try await Self.fetch(identityBody: #"{"name":"octocat","isPro":true,"periodEnd":0}"#)

        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.detailRow(label: "Renews") == nil)
        #expect(snapshot.detailRow(label: "Billing period ends") == nil)
    }

    @Test
    func `unknown billing modes are displayed verbatim`() async throws {
        let snapshot = try await Self
            .fetch(identityBody: #"{"name":"octocat","isPro":false,"billingMode":"quarterly"}"#)

        #expect(snapshot.detailRow(label: "Billing")?.value == "Quarterly")
    }

    @Test(arguments: [
        #"{"name":"octocat","isPro":true,"periodEnd":"soon"}"#,
        #"{"name":"octocat","isPro":true,"periodEnd":true}"#,
        #"{"name":"octocat","isPro":true,"periodEnd":{}}"#,
        #"{"name":"octocat","isPro":true,"periodEnd":1e15}"#,
        #"{"name":"octocat","isPro":true,"billingMode":7}"#,
    ])
    func `malformed identity payloads are classified parse failures`(body: String) async throws {
        do {
            _ = try await Self.fetch(identityBody: body)
            Issue.record("Expected Hugging Face identity parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        }
    }

    @Test(arguments: [
        #"{"currency":"USD"}"#,
        #"{"currency":"US","periods":[]}"#,
        #"{"currency":"USD","periods":[{"period":"2027-01-01T00:00:00Z","sessions":{}}]}"#,
        #"{"currency":"USD","periods":[{"period":"invalid","sessions":[]}] }"#,
        #"""
        {"currency":"USD","periods":[{"period":"2027-01-01T00:00:00Z","sessions":[
          {"id":"a","requestCount":1,"costCents":"25"}
        ]}]}
        """#,
    ])
    func `malformed billing payloads are classified parse failures`(body: String) async throws {
        do {
            _ = try await Self.fetch(usageBody: body)
            Issue.record("Expected Hugging Face parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .permissionDenied),
        (429, .rateLimited),
        (500, .providerUnavailable),
        (404, .apiFailure),
    ])
    func `identity status failures classify before parsing non JSON bodies`(
        status: Int,
        kind: ProviderFetchClassifiedError.Kind) async throws
    {
        do {
            _ = try await Self.fetch(identityStatus: status, errorBody: "<html>failure</html>")
            Issue.record("Expected classified Hugging Face failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .permissionDenied),
        (429, .rateLimited),
        (503, .providerUnavailable),
        (422, .apiFailure),
    ])
    func `billing status failures classify before parsing non JSON bodies`(
        status: Int,
        kind: ProviderFetchClassifiedError.Kind) async throws
    {
        do {
            _ = try await Self.fetch(usageStatus: status, errorBody: "not-json")
            Issue.record("Expected classified Hugging Face billing failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        }
    }

    @Test
    func `invalid success JSON is a parse failure`() async throws {
        do {
            _ = try await Self.fetch(usageBody: "<html>ok but invalid</html>")
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        }
    }

    @Test
    func `transport failure is classified as network failure`() async throws {
        let transport = ProviderHTTPTransportStub { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await Self.runtime(transport: transport).fetchUsage(
                secrets: ["HF_TOKEN": "hf_fixture"],
                now: Self.now)
            Issue.record("Expected network failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .networkFailure)
        }
    }

    private static func fetch(
        identityBody: String = identityFixture,
        identityStatus: Int = 200,
        usageBody: String = usageFixture,
        usageStatus: Int = 200,
        errorBody: String = "{}") async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path == "/api/whoami-v2" {
                return Self.response(
                    url: url,
                    body: identityStatus == 200 ? identityBody : errorBody,
                    statusCode: identityStatus)
            }
            try Self.expectCurrentMonthQuery(url)
            return Self.response(
                url: url,
                body: usageStatus == 200 ? usageBody : errorBody,
                statusCode: usageStatus)
        }
        return try await Self.runtime(transport: transport).fetchUsage(
            secrets: ["HF_TOKEN": "hf_fixture"],
            now: Self.now)
    }

    private static func runtime(transport: any ProviderHTTPTransport) throws -> ProviderPluginRuntime {
        try ProviderPluginRuntime(bundledPlugin: "huggingface", transport: transport)
    }

    private static func context(environment: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: HuggingFaceTestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func expectCurrentMonthQuery(_ url: URL) throws {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["startDate"] == "2027-01-01T00:00:00.000Z")
        #expect(items["endDate"] == "2027-01-15T08:00:00.000Z")
        #expect(items.count == 2)
    }

    private static func expectBoundedCurrentMonthQuery(_ url: URL) throws {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        let startText = try #require(items["startDate"])
        let endText = try #require(items["endDate"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = try #require(formatter.date(from: startText))
        let end = try #require(formatter.date(from: endText))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let endComponents = calendar.dateComponents([.year, .month], from: end)
        #expect(startComponents.day == 1)
        #expect(startComponents.hour == 0)
        #expect(startComponents.minute == 0)
        #expect(startComponents.second == 0)
        #expect(startComponents.year == endComponents.year)
        #expect(startComponents.month == endComponents.month)
        #expect(start <= end)
        #expect(items.count == 2)
    }

    private static func response(url: URL, body: String, statusCode: Int = 200) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": statusCode == 200 ? "application/json" : "text/html"]) ?? HTTPURLResponse()
        return (Data(body.utf8), response)
    }

    private static let identityFixture = #"""
    {"name":"octocat","fullname":"Octo Cat","isPro":false,"periodEnd":null,"billingMode":"postpaid","canPay":false}
    """#

    private static let usageFixture = #"""
    {
      "currency": "usd",
      "periods": [
        {
          "period": "2027-01-01T00:00:00.000Z",
          "sessions": [
            {"id": "session-a", "requestCount": 5, "costCents": 125},
            {"id": "session-b", "requestCount": 4, "costCents": 250}
          ]
        }
      ]
    }
    """#
}

private struct HuggingFaceTestClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }

    func detectVersion() -> String? {
        nil
    }
}
