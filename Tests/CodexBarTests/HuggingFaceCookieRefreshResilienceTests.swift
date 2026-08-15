import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HuggingFaceCookieRefreshResilienceTests {
    @Test
    func `cookie login required respects failure gate while keeping prior Hugging Face snapshot`() async throws {
        let prior = Self.makePriorSnapshot()
        let store = try await MainActor.run {
            try Self.makeStore(
                suite: "HuggingFaceCookieRefreshResilienceTests-login-required",
                prior: prior,
                strategy: HuggingFaceCookieFailureFetchStrategy(error: HuggingFaceBillingError.loginRequired))
        }

        await store.refreshProvider(.huggingface)
        let firstResult = await MainActor.run {
            (
                updatedAt: store.snapshot(for: .huggingface)?.updatedAt,
                hasError: store.error(for: .huggingface) != nil)
        }

        #expect(firstResult.updatedAt == prior.updatedAt)
        #expect(!firstResult.hasError)

        await store.refreshProvider(.huggingface)
        let secondResult = await MainActor.run {
            (
                updatedAt: store.snapshot(for: .huggingface)?.updatedAt,
                error: store.error(for: .huggingface))
        }

        #expect(secondResult.updatedAt == prior.updatedAt)
        #expect(secondResult.error == HuggingFaceBillingError.loginRequired.localizedDescription)
    }

    @Test
    func `cookie import missing respects failure gate while keeping prior Hugging Face snapshot`() async throws {
        let prior = Self.makePriorSnapshot()
        let store = try await MainActor.run {
            try Self.makeStore(
                suite: "HuggingFaceCookieRefreshResilienceTests-import-missing",
                prior: prior,
                strategy: HuggingFaceCookieFailureFetchStrategy(error: HuggingFaceCookieImportError.missingCookie))
        }

        await store.refreshProvider(.huggingface)
        await store.refreshProvider(.huggingface)
        let result = await MainActor.run {
            (
                updatedAt: store.snapshot(for: .huggingface)?.updatedAt,
                error: store.error(for: .huggingface))
        }

        #expect(result.updatedAt == prior.updatedAt)
        #expect(result.error == HuggingFaceCookieImportError.missingCookie.localizedDescription)
    }

    @Test
    func `cookie login required without prior Hugging Face snapshot still surfaces failure`() async throws {
        let store = try await MainActor.run {
            try Self.makeStore(
                suite: "HuggingFaceCookieRefreshResilienceTests-login-required-no-prior",
                prior: nil,
                strategy: HuggingFaceCookieFailureFetchStrategy(error: HuggingFaceBillingError.loginRequired))
        }

        await store.refreshProvider(.huggingface)
        let result = await MainActor.run {
            (
                hasSnapshot: store.snapshot(for: .huggingface) != nil,
                error: store.error(for: .huggingface))
        }

        #expect(!result.hasSnapshot)
        #expect(result.error == HuggingFaceBillingError.loginRequired.localizedDescription)
    }

    @Test
    func `unrelated billing failure clears prior Hugging Face snapshot when surfaced`() async throws {
        let prior = Self.makePriorSnapshot()
        let store = try await MainActor.run {
            try Self.makeStore(
                suite: "HuggingFaceCookieRefreshResilienceTests-api-error",
                prior: prior,
                strategy: HuggingFaceCookieFailureFetchStrategy(error: HuggingFaceBillingError.apiError(500)))
        }

        await store.refreshProvider(.huggingface)
        let firstResult = await MainActor.run {
            (
                updatedAt: store.snapshot(for: .huggingface)?.updatedAt,
                hasError: store.error(for: .huggingface) != nil)
        }

        #expect(firstResult.updatedAt == prior.updatedAt)
        #expect(!firstResult.hasError)

        await store.refreshProvider(.huggingface)
        let secondResult = await MainActor.run {
            (
                hasSnapshot: store.snapshot(for: .huggingface) != nil,
                error: store.error(for: .huggingface))
        }

        #expect(!secondResult.hasSnapshot)
        #expect(secondResult.error == HuggingFaceBillingError.apiError(500).localizedDescription)
    }

    @MainActor
    private static func makeStore(
        suite: String,
        prior: UsageSnapshot?,
        strategy: any ProviderFetchStrategy) throws -> UsageStore
    {
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: provider == .huggingface)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        if let prior {
            store._setSnapshotForTesting(prior, provider: .huggingface)
        }

        let baseSpec = try #require(store.providerSpecs[.huggingface])
        let descriptor = ProviderDescriptor(
            id: .huggingface,
            metadata: baseSpec.descriptor.metadata,
            branding: baseSpec.descriptor.branding,
            tokenCost: baseSpec.descriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.web],
                pipeline: ProviderFetchPipeline { _ in [strategy] }),
            cli: baseSpec.descriptor.cli)
        store.providerSpecs[.huggingface] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: descriptor,
            makeFetchContext: baseSpec.makeFetchContext)
        return store
    }

    private static func makePriorSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 9.5,
                limit: 0,
                currencyCode: "USD",
                period: "Current period usage",
                balance: 128.4,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .huggingface,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "PRO",
                accountID: "octocat"))
    }

    @MainActor
    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        return settings
    }
}

private struct HuggingFaceCookieFailureFetchStrategy: ProviderFetchStrategy {
    let id = "test.huggingface-cookie-failure"
    let kind: ProviderFetchKind = .web
    let error: Error

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw self.error
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
