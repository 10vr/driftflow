import Foundation
import os
import ServiceManagement

/// Opening Driftflow at login, through macOS's own Login Items (System Settings › General).
enum LoginItem {
    private static let log = Logger(subsystem: "dev.driftflow.app", category: "login-item")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    /// On by default: turned on once, the first time Driftflow runs from /Applications (a copy
    /// running from a download or build folder would register the wrong path). After that, only
    /// the toggle in Settings changes it.
    static func applyDefaultOnce() {
        let key = "loginItemDefaultApplied"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        // A never-registered app reports .notFound rather than .notRegistered.
        if !isEnabled, !needsApproval { set(true) }
    }
}
