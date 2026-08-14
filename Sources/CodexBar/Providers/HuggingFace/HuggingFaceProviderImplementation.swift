import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct HuggingFaceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .huggingface

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .huggingface, field: .apiKey]
        _ = settings.huggingfaceCookieSource
        _ = settings.huggingfaceCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .huggingface(context.settings.huggingfaceSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.huggingfaceCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.huggingfaceCookieSource != .manual {
            settings.huggingfaceCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.huggingfaceCookieSource.rawValue },
            set: { raw in
                context.settings.huggingfaceCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.huggingfaceCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports your Hugging Face browser session to also show credits available.",
                manual: "Paste a Cookie header captured from huggingface.co.",
                off: "Hugging Face browser sign-in is disabled; the user access token is used instead.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "huggingface-cookie-source",
                title: "Browser sign-in",
                subtitle: "Automatic imports your Hugging Face browser session to also show credits available.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .huggingface)
                }),
        ]
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
            ProviderSettingsFieldDescriptor(
                id: "huggingface-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.huggingfaceCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "huggingface-open-billing",
                        title: "Open Hugging Face Billing",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://huggingface.co/settings/billing") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.huggingfaceCookieSource == .manual },
                onActivate: { context.settings.ensureHuggingFaceCookieLoaded() }),
        ]
    }
}
