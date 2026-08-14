import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HuggingFaceBillingPageTests {
    @Test
    func `billing html maps balance usage and detail rows`() throws {
        let now = Date(timeIntervalSince1970: 1_782_222_000)
        let snapshot = try HuggingFaceBillingPageFetcher.parseBillingHTML(Self.billingHTML, now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.currentBalanceUsd == 63.75)
        #expect(abs(snapshot.usedThisPeriodUsd - 38.241_960_143) < 0.000_001)
        #expect(snapshot.requestCount == 1786)
        #expect(snapshot.username == "octocat")
        #expect(snapshot.isPro == true)
        #expect(snapshot.billingMode == "Prepaid")
        #expect(snapshot.includedCreditsUsd == 2)

        #expect(usage.detailRow(label: "Credits available")?.value == "USD 63.75")
        #expect(usage.detailRow(label: "Credits used")?.value == "USD 38.24")
        #expect(usage.detailRow(label: "Credits used")?.secondaryValue == "Current period")
        #expect(usage.detailRow(label: "Included credits")?.value == "USD 2.00")
        #expect(usage.detailRow(label: "Plan")?.value == "PRO")
        #expect(usage.detailRow(label: "Billing")?.value == "Prepaid")
        #expect(usage.detailRow(label: "Renews")?.value == "2026-09-01")
        #expect(usage.detailRow(label: "Renews")?.secondaryValue == "UTC")
        #expect(usage.subscriptionRenewsAt == snapshot.periodEnd)
        #expect(usage.providerCost?.used == snapshot.usedThisPeriodUsd)
        #expect(usage.providerCost?.balance == 63.75)
        #expect(usage.identity?.accountID == "octocat")
        #expect(usage.identity?.loginMethod == "PRO")
        #expect(usage.dataConfidence == .exact)
    }

    @Test
    func `content based selection finds the target blob among multiple data props attributes`() throws {
        let longerUnrelatedBlob = #"{"unrelated":true,"other":{"nested":"much longer than the real billing blob"}}"#
        let html = """
        <main>
          <div data-props="\(Self.htmlEscape(longerUnrelatedBlob))"></div>
          \(Self.dataPropsElement(json: Self.billingJSON))
          <div data-props="\(Self.htmlEscape(#"{"anotherComponent":"noise"}"#))"></div>
        </main>
        """

        let snapshot = try HuggingFaceBillingPageFetcher.parseBillingHTML(html)

        #expect(snapshot.currentBalanceUsd == 63.75)
        #expect(snapshot.username == "octocat")
    }

    @Test
    func `missing balance field is a parse failure`() {
        let json = Self.billingJSON.replacingOccurrences(of: #""currentBalanceUsd": 63.75,"#, with: "")
        let html = "<main>\(Self.dataPropsElement(json: json))</main>"

        #expect(throws: HuggingFaceBillingError.self) {
            _ = try HuggingFaceBillingPageFetcher.parseBillingHTML(html)
        }
    }

    @Test
    func `malformed json in the only data props attribute is a parse failure`() {
        let html = """
        <main><div data-props="\(Self.htmlEscape("{not valid json"))"></div></main>
        """

        #expect(throws: HuggingFaceBillingError.self) {
            _ = try HuggingFaceBillingPageFetcher.parseBillingHTML(html)
        }
        do {
            _ = try HuggingFaceBillingPageFetcher.parseBillingHTML(html)
            Issue.record("Expected a parse failure")
        } catch let error as HuggingFaceBillingError {
            #expect(error == .parseFailed("Billing data was not found on the page."))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `page without data props that looks like a login page requires login`() {
        let html = """
        <html><head><title>Log In - Hugging Face</title></head>
        <body><form action="/login" method="post"><input name="login"></form></body></html>
        """

        #expect(throws: HuggingFaceBillingError.loginRequired) {
            _ = try HuggingFaceBillingPageFetcher.parseBillingHTML(html)
        }
    }

    @Test
    func `fetch classifies a 401 status as login required`() async throws {
        let transport = ProviderHTTPTransportStub { _ in
            (Data("expired".utf8), Self.response(statusCode: 401))
        }

        await #expect(throws: HuggingFaceBillingError.loginRequired) {
            _ = try await HuggingFaceBillingPageFetcher.fetchBilling(
                cookieHeader: "session=expired",
                session: transport)
        }
    }

    @Test
    func `fetch classifies a same origin redirect as login required`() async throws {
        let transport = ProviderHTTPTransportStub { _ in
            (Data(), Self.response(statusCode: 302))
        }

        await #expect(throws: HuggingFaceBillingError.loginRequired) {
            _ = try await HuggingFaceBillingPageFetcher.fetchBilling(
                cookieHeader: "session=expired",
                session: transport)
        }
    }

    @Test
    func `fetch classifies a non 200 non redirect status as an api error`() async throws {
        let transport = ProviderHTTPTransportStub { _ in
            (Data("boom".utf8), Self.response(statusCode: 500))
        }

        await #expect(throws: HuggingFaceBillingError.apiError(500)) {
            _ = try await HuggingFaceBillingPageFetcher.fetchBilling(
                cookieHeader: "session=abc",
                session: transport)
        }
    }

    @Test
    func `missing cookie header throws without making a request`() async throws {
        let transport = ProviderHTTPTransportStub { _ in
            Issue.record("Missing cookie fetch must not reach transport")
            throw URLError(.badURL)
        }

        await #expect(throws: HuggingFaceBillingError.missingCookie) {
            _ = try await HuggingFaceBillingPageFetcher.fetchBilling(cookieHeader: "  ", session: transport)
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `fetch sends normalized cookie and accept headers to the billing settings path`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            (Data(Self.billingHTML.utf8), Self.response(statusCode: 200, url: request.url))
        }

        _ = try await HuggingFaceBillingPageFetcher.fetchBilling(
            cookieHeader: "Cookie: session=abc; theme=dark",
            session: transport)

        let requests = await transport.requests()
        let request = try #require(requests.first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session=abc; theme=dark")
        #expect(request.value(forHTTPHeaderField: "Accept")?.hasPrefix("text/html") == true)
        #expect(request.url?.host == "huggingface.co")
        #expect(request.url?.path == "/settings/billing")
    }

    @Test
    func `payment method fields never reach the usage snapshot detail rows`() throws {
        let json = """
        {
          "entity": {
            "user": "octocat",
            "isPro": true,
            "billingMode": "prepaid",
            "currentBalanceUsd": 63.75,
            "subscriptionIncludedCreditsUsd": 2,
            "paymentMethod": {"type": "card", "id": "pm_secret123", "last4": "1004"}
          },
          "last3periods": [{"periodStart": "2026-08-02T16:00:00.000Z", "periodEnd": "2026-09-01T00:00:00.000Z"}],
          "usage": {"inference": {"usedNanoUsd": 38241960143, "numRequests": 1786}}
        }
        """
        let html = "<main>\(Self.dataPropsElement(json: json))</main>"

        let snapshot = try HuggingFaceBillingPageFetcher.parseBillingHTML(html)
        let usage = snapshot.toUsageSnapshot()

        for section in usage.details {
            for row in section.rows {
                #expect(!row.value.contains("1004"))
                #expect(!row.value.contains("pm_secret123"))
                #expect(!row.value.lowercased().contains("card"))
                #expect(!row.value.lowercased().contains("payment"))
                #expect(row.secondaryValue?.contains("1004") != true)
            }
        }
    }

    private static func response(statusCode: Int, url: URL? = nil) -> URLResponse {
        HTTPURLResponse(
            url: url ?? URL(string: "https://huggingface.co/settings/billing")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [:])!
    }

    private static func htmlEscape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func dataPropsElement(json: String) -> String {
        #"<div data-props="\#(self.htmlEscape(json))"></div>"#
    }

    private static let billingJSON = """
    {
      "emailUnconfirmed": false,
      "entity": {
        "avatarUrl": "https://example.com/a.png",
        "isPro": true,
        "fullname": "Octo Cat",
        "user": "octocat",
        "orgs": [],
        "isHf": false,
        "isMod": false,
        "type": "user",
        "canPay": true,
        "billingMode": "prepaid",
        "currentBalanceUsd": 63.75,
        "subscriptionIncludedCreditsUsd": 2,
        "subscriptionProductName": "PRO subscription",
        "paymentMethod": {"type": "card", "id": "pm_redacted", "last4": "1004"},
        "billingDetails": {"country": "US"}
      },
      "last3periods": [{
        "_id": "abc",
        "entityId": "octocat",
        "entityType": "user",
        "entityName": "octocat",
        "periodStart": "2026-08-02T16:00:00.000Z",
        "periodEnd": "2026-09-01T00:00:00.000Z"
      }],
      "rateLimits": {},
      "usage": {
        "storage": {},
        "inference": {
          "usedNanoUsd": 38241960143,
          "numRequests": 1786,
          "providerDetails": [
            {"provider": "together", "numRequests": 312, "totalCostNanoUsd": 18486998920, "totalDurationMs": 2618852.27}
          ]
        },
        "jobs": {},
        "zeroGpu": {},
        "lastUpdatedAt": "2026-08-14T00:00:00.000Z"
      },
      "bandwidth": {},
      "isMetronomeContractualCustomer": false,
      "paymentMethod": {"type": "card", "id": "pm_redacted", "last4": "1004"},
      "billingDetails": {"country": "US"}
    }
    """

    private static let billingHTML = "<main>\(dataPropsElement(json: billingJSON))</main>"
}
