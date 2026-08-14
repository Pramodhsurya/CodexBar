import Foundation

#if os(macOS)
import SweetCookieKit

public enum HuggingFaceCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.huggingface, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["huggingface.co"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.huggingface]?.browserCookieOrder ?? Browser.defaultImportOrder

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        preferredBrowsers: [Browser] = [],
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        guard let session = try self.importSessions(
            browserDetection: browserDetection,
            preferredBrowsers: preferredBrowsers,
            logger: logger).first
        else {
            throw HuggingFaceCookieImportError.missingCookie
        }
        return session
    }

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        preferredBrowsers: [Browser] = [],
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let installedBrowsers = preferredBrowsers.isEmpty
            ? self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
            : preferredBrowsers.cookieImportCandidates(using: browserDetection)
        var sessions: [SessionInfo] = []

        let query = BrowserCookieQuery(domains: self.cookieDomains)
        for browserSource in installedBrowsers {
            do {
                let sources = try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: { msg in self.emit(msg, logger: logger) })
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !cookies.isEmpty else { continue }
                    self.emit("Found \(cookies.count) cookies in \(source.label)", logger: logger)
                    sessions.append(SessionInfo(cookies: cookies, sourceLabel: source.label))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                self.emit(
                    "\(browserSource.displayName) cookie import failed: \(error.localizedDescription)",
                    logger: logger)
            }
        }

        guard !sessions.isEmpty else {
            throw HuggingFaceCookieImportError.missingCookie
        }
        return sessions
    }

    public static func hasSession(browserDetection: BrowserDetection = BrowserDetection()) -> Bool {
        (try? self.importSessions(browserDetection: browserDetection))?.isEmpty == false
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[huggingface-cookie] \(message)")
        self.log.debug(message)
    }
}

public enum HuggingFaceCookieImportError: LocalizedError, Sendable {
    case missingCookie

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "Hugging Face session cookie not found. Sign in to huggingface.co in Chrome, or paste a Cookie header."
        }
    }
}
#endif
