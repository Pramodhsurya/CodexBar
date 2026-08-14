import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct HuggingFaceCookieCacheTests {
    private static let testCookieHeader = "token=fake-hf-session-token; another=fake-value"

    // MARK: - Cache round-trip

    @Test
    func `cache round trip returns matching cookie header and source label`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .huggingface)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        CookieHeaderCache.store(
            provider: .huggingface,
            cookieHeader: Self.testCookieHeader,
            sourceLabel: "Chrome (Test)")

        let cached = CookieHeaderCache.load(provider: .huggingface)
        #expect(cached != nil)
        #expect(cached?.cookieHeader == Self.testCookieHeader)
        #expect(cached?.sourceLabel == "Chrome (Test)")
    }

    // MARK: - Empty cache returns nil

    @Test
    func `load returns nil when nothing has been cached`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .huggingface)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        #expect(CookieHeaderCache.load(provider: .huggingface) == nil)
    }

    // MARK: - Clear empties the cache

    @Test
    func `clear empties a populated cache`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .huggingface)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        CookieHeaderCache.store(
            provider: .huggingface,
            cookieHeader: Self.testCookieHeader,
            sourceLabel: "Chrome (Test)")
        #expect(CookieHeaderCache.load(provider: .huggingface) != nil)

        CookieHeaderCache.clear(provider: .huggingface)

        #expect(CookieHeaderCache.load(provider: .huggingface) == nil)
    }

    // MARK: - Cache is isolated per provider

    @Test
    func `clearing huggingface does not affect other providers`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            CookieHeaderCache.clear(provider: .huggingface)
            CookieHeaderCache.clear(provider: .qoder)
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        CookieHeaderCache.store(
            provider: .huggingface,
            cookieHeader: Self.testCookieHeader,
            sourceLabel: "Chrome (Test)")
        CookieHeaderCache.store(
            provider: .qoder,
            cookieHeader: "unrelated=fake-value",
            sourceLabel: "Chrome (Test)")

        CookieHeaderCache.clear(provider: .huggingface)

        #expect(CookieHeaderCache.load(provider: .huggingface) == nil)
        #expect(CookieHeaderCache.load(provider: .qoder) != nil)
    }

    // MARK: - hasSession without a real browser cookie store

    #if os(macOS)
    @Test
    func `hasSession returns false when no browser cookie store is reachable`() {
        // The test sandbox suppresses real browser cookie store access (see
        // BrowserCookieAccessGate.cookieStoreAccessDecision), so this never touches a real
        // browser or triggers a Keychain prompt: it exercises the swallow-and-return-false path.
        let hasSession = HuggingFaceCookieImporter.hasSession(browserDetection: BrowserDetection(cacheTTL: 0))
        #expect(hasSession == false)
    }
    #endif
}
