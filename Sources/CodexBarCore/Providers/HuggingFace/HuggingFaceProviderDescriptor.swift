import Foundation

public enum HuggingFaceProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        environmentProjections: [
            .apiKey(HuggingFaceSettingsReader.apiKeyEnvironmentKey),
            .cookieHeader(HuggingFaceSettingsReader.cookieHeaderEnvironmentKey, onlyWhenManual: true),
        ],
        tokenResolver: { kind, environment, _ in
            let token: String? = switch kind {
            case .primary: HuggingFaceSettingsReader.apiKey(environment: environment)
            case .secondary: HuggingFaceSettingsReader.cookieHeader(environment: environment)
            case .projectID: nil
            }
            guard let token else { return nil }
            return ProviderTokenResolution(token: token, source: .environment)
        },
        tokenAccountSupport: TokenAccountSupport(
            title: "Session cookies",
            subtitle: "Store a Hugging Face Cookie header.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        missingCredentialMessage: { _ in
            "Add a Hugging Face user access token, or sign in with your browser."
        })

    /// Hugging Face cookie import is documented for Chrome; avoid probing unrelated browser keychains.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    static func makeDescriptor(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ProviderDescriptor
    {
        ProviderDescriptor(
            id: .huggingface,
            menuBarMetrics: .automaticOnly,
            settingsSection: .init(
                HuggingFaceProviderSettingsKey.self,
                cookieSettings: HuggingFaceProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .huggingface,
                displayName: "Hugging Face",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Hugging Face usage",
                cliName: "huggingface",
                defaultEnabled: false,
                widgetSelectable: false,
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://huggingface.co/settings/billing",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .huggingface),
                iconResourceName: "ProviderIcon-huggingface",
                color: ProviderColor(red: 1, green: 208 / 255, blue: 51 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xFFD033),
                    ProviderColor(hex: 0xFF9D00),
                    ProviderColor(hex: 0x3B2F00),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Hugging Face spend comes from the Hub billing API." }),
            presentation: ProviderUsagePresentation(costPresenter: { snapshot in
                let style: ProviderCostMenuCardStyle = if snapshot.providerCost?.balance != nil {
                    .payAsYouGoSpend
                } else if (snapshot.providerCost?.limit ?? 1) <= 0 {
                    .apiSpend
                } else {
                    .generic
                }
                return ProviderCostPresentation(menuCardStyle: style)
            }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    switch context.sourceMode {
                    case .web:
                        [HuggingFaceWebFetchStrategy()]
                    case .api:
                        [Self.apiStrategy(transport: transport)]
                    case .cli, .oauth:
                        []
                    case .auto:
                        [HuggingFaceWebFetchStrategy(), Self.apiStrategy(transport: transport)]
                    }
                })),
            cli: ProviderCLIConfig(
                name: "huggingface",
                aliases: ["hf"],
                versionDetector: nil,
                browserSupportExemption: { sourceMode, _, settings in
                    guard sourceMode == .auto || sourceMode == .web else { return false }
                    return settings?.huggingface?.cookieSource == .manual
                }))
    }

    private static func apiStrategy(transport: any ProviderHTTPTransport) -> ScriptFetchStrategy {
        ScriptFetchStrategy(
            id: "huggingface.js",
            provider: .huggingface,
            bundledPlugin: "huggingface",
            secretKey: HuggingFaceSettingsReader.apiKeyEnvironmentKey,
            sourceLabel: "api",
            transport: transport,
            resolveSecret: { environment in
                self.credentials.resolveToken(environment: environment)?.token
            },
            isEnabled: { _ in true })
    }
}

struct HuggingFaceWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "huggingface.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let cookieSource = context.settings?.huggingface?.cookieSource ?? .auto
        switch cookieSource {
        case .off:
            return false
        case .manual:
            return CookieHeaderNormalizer.normalize(Self.manualCookieHeader(context: context)) != nil
        case .auto:
            if CookieHeaderCache.load(provider: .huggingface) != nil {
                return true
            }
            #if os(macOS)
            guard context.runtime == .app, ProviderInteractionContext.current == .userInitiated else { return false }
            return HuggingFaceCookieImporter.hasSession(browserDetection: context.browserDetection)
            #else
            return false
            #endif
        }
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.huggingface?.cookieSource ?? .auto

        if cookieSource == .manual {
            guard let cookieHeader = CookieHeaderNormalizer.normalize(Self.manualCookieHeader(context: context)) else {
                throw HuggingFaceBillingError.missingCookie
            }
            let snapshot = try await HuggingFaceBillingPageFetcher.fetchBilling(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout)
            return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
        }

        var lastError: Error?
        if let cached = CookieHeaderCache.load(provider: .huggingface),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            do {
                let snapshot = try await HuggingFaceBillingPageFetcher.fetchBilling(
                    cookieHeader: cached.cookieHeader,
                    timeout: context.webTimeout)
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
            } catch let error as HuggingFaceBillingError {
                lastError = error
                switch error {
                case .loginRequired, .parseFailed:
                    CookieHeaderCache.clear(provider: .huggingface)
                case .missingCookie, .apiError:
                    throw error
                }
            }
        }

        #if os(macOS)
        guard context.runtime == .app, ProviderInteractionContext.current == .userInitiated else {
            throw lastError ?? HuggingFaceBillingError.missingCookie
        }

        let sessions = (try? HuggingFaceCookieImporter.importSessions(browserDetection: context.browserDetection)) ?? []
        for session in sessions {
            do {
                let snapshot = try await HuggingFaceBillingPageFetcher.fetchBilling(
                    cookieHeader: session.cookieHeader,
                    timeout: context.webTimeout)
                CookieHeaderCache.store(
                    provider: .huggingface,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
            } catch let error as HuggingFaceBillingError {
                lastError = error
                switch error {
                case .loginRequired, .parseFailed:
                    continue
                case .missingCookie, .apiError:
                    throw error
                }
            }
        }
        #endif

        throw lastError ?? HuggingFaceBillingError.missingCookie
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        true
    }

    private static func manualCookieHeader(context: ProviderFetchContext) -> String? {
        context.settings?.huggingface?.manualCookieHeader
            ?? ProviderTokenResolver.token(for: .huggingface, kind: .secondary, environment: context.env)
    }
}
