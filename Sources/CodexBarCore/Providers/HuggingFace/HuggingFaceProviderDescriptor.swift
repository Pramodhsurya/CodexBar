import Foundation

public enum HuggingFaceProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: HuggingFaceSettingsReader.apiKeyEnvironmentKey,
        resolve: HuggingFaceSettingsReader.apiKey)

    static func makeDescriptor(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ProviderDescriptor
    {
        ProviderDescriptor(
            id: .huggingface,
            menuBarMetrics: .automaticOnly,
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
                let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0
                    ? .apiSpend
                    : .generic
                return ProviderCostPresentation(menuCardStyle: style)
            }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ScriptFetchStrategy(
                        id: "huggingface.js",
                        provider: .huggingface,
                        bundledPlugin: "huggingface",
                        secretKey: HuggingFaceSettingsReader.apiKeyEnvironmentKey,
                        sourceLabel: "api",
                        transport: transport,
                        resolveSecret: { environment in
                            self.credentials.resolveToken(environment: environment)?.token
                        },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(
                name: "huggingface",
                aliases: ["hf"],
                versionDetector: nil))
    }
}
