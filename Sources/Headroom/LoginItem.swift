import Foundation
import ServiceManagement

/// Launch at login via SMAppService. Requires the app to live in /Applications.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    /// The `build.sh install-agent` fallback, for when SMAppService misbehaves with ad-hoc signing.
    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.amirali.headroom.plist")
    }
    static var usesLaunchAgent: Bool { FileManager.default.fileExists(atPath: launchAgentURL.path) }

    /// Last registration error, shown as "Allow in Login Items…".
    static var lastError: Error?

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Register automatically the first time the app runs (not on every launch, so
    /// unchecking the menu item sticks).
    static func registerOnFirstLaunch() {
        let key = "didAutoRegisterLoginItem"
        // Only the installed copy: a dev build in build/ shouldn't become the login item.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key), !usesLaunchAgent else { return }
        UserDefaults.standard.set(true, forKey: key)
        if status != .enabled { setEnabled(true) }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
