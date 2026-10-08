import AppKit
import GrokGaugeCore

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("GrokGauge \(AppInfo.version)")
    exit(0)
}

if arguments.contains("--refresh-now") {
    Task {
        let code = await DebugCLI.refreshNow()
        exit(code)
    }
    dispatchMain()
}

if arguments.contains("--print-usage") || arguments.contains("--json") {
    Task {
        let code = await DebugCLI.printUsage(json: arguments.contains("--json"))
        exit(code)
    }
    dispatchMain()
}

if let i = arguments.firstIndex(of: "--render-preview"), i + 1 < arguments.count {
    // Developer aid for README screenshots: renders the popover + menu bar item to PNGs
    // without needing Screen Recording permission. Add --demo for sample data.
    let dir = URL(fileURLWithPath: (arguments[i + 1] as NSString).expandingTildeInPath)
    let demo = arguments.contains("--demo")
    MainActor.assumeIsolated {
        // AppKit drawing needs the real main thread, so run an NSApplication loop
        // (dispatchMain() would service the main queue from a worker thread).
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await PreviewRenderer.render(to: dir, demo: demo)
            exit(code)
        }
        app.run()
    }
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    GrokGauge \(AppInfo.version) — SuperGrok and Grok Bot usage in your menu bar

    Usage:
      GrokGauge                 Launch the menu bar app
      GrokGauge --print-usage   Print Grok + Grok Bot usage once (never prints tokens)
      GrokGauge --json          Same, as JSON
      GrokGauge --refresh-now   Renew the Grok login now (prints expiry times only)
      GrokGauge --render-preview DIR [--demo]   Write popover/menu bar PNGs (for docs)
      GrokGauge --version
    """)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only (LSUIElement)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
