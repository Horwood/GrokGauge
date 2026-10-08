import Foundation
import ServiceManagement

/// Wraps SMAppService.mainApp (macOS 13+). The app must live in /Applications or ~/Applications.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var lastError: String?

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = SMAppService.mainApp.status == .requiresApproval
                ? "Approve GrokGauge in System Settings › General › Login Items."
                : "Couldn't change the login item."
        }
        refresh()
    }
}
