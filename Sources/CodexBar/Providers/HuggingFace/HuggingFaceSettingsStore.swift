import CodexBarCore
import Foundation

extension SettingsStore {
    var huggingfaceCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .huggingface)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .huggingface) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .huggingface, field: "cookieHeader", value: newValue)
        }
    }

    var huggingfaceCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .huggingface, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .huggingface) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .huggingface, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureHuggingFaceCookieLoaded() {}
}

extension SettingsStore {
    func huggingfaceSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
        .HuggingFaceProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .huggingface,
            configuredSource: self.huggingfaceCookieSource,
            configuredHeader: self.huggingfaceCookieHeader,
            tokenOverride: tokenOverride)
    }
}
