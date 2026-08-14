import AppKit
import CodexBarCore
import Foundation

struct HuggingFaceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .huggingface

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .huggingface, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if HuggingFaceSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .huggingface, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "huggingface-token",
                title: "User access token",
                subtitle: "Stored in ~/.codexbar/config.json. Create a read token in Hugging Face settings.",
                kind: .secure,
                placeholder: "hf_...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "huggingface-open-tokens",
                        title: "Open Hugging Face Tokens",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://huggingface.co/settings/tokens") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
