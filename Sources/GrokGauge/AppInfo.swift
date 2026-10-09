import AppKit

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let grokURL = URL(string: "https://grok.com")!
    static let repoURL = URL(string: "https://github.com/stevencombs/GrokGauge")!
    static let youTubeHandle = "@retroCombs-Tech"
    static let youTubeURL = URL(string: "https://www.youtube.com/@retroCombs-Tech")!
    static let contactEmail = "retroCombs@icloud.com"
    static let contactURL = URL(string: "mailto:retroCombs@icloud.com")!
    /// Tips (PayPal.Me). Opens in the browser; GrokGauge sends nothing.
    static let tipURL = URL(string: "https://paypal.me/stevencombs")!

    /// The retroCombs logo bundled in Contents/Resources (nil when running outside the .app).
    static var makerLogo: NSImage? {
        Bundle.main.url(forResource: "retrocombs-logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
    static let refreshInterval: TimeInterval = 15 * 60   // default; see Settings › Colors & Alerts
    static let botRefreshInterval: TimeInterval = 2 * 60
}
