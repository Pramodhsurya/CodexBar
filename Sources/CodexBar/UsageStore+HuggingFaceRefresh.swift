import CodexBarCore
import Foundation

extension UsageStore {
    /// True when the Hugging Face web strategy failed only because it couldn't (re-)import a
    /// browser cookie in the background -- not because the underlying account data is wrong.
    static func isHuggingFaceCookieRefreshFailure(_ error: Error) -> Bool {
        if case HuggingFaceBillingError.loginRequired = error {
            return true
        }
        if case HuggingFaceBillingError.missingCookie = error {
            return true
        }
        if case HuggingFaceCookieImportError.missingCookie = error {
            return true
        }
        return false
    }
}
