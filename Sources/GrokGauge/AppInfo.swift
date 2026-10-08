import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let grokURL = URL(string: "https://grok.com")!
    static let repoURL = URL(string: "https://github.com/stevencombs/GrokGauge")!
    static let refreshInterval: TimeInterval = 15 * 60
}
