import AppKit

/// When Driftflow is opened from outside Applications (the installer disk image, Downloads, or the
/// temporary copy macOS runs apps from when they haven't been moved), offers to move itself there:
/// updates, permissions and opening at login all need the app to stay in one place.
@MainActor
enum AppMover {
    private static let declinedKey = "moveToApplicationsDeclined"
    static let destination = URL(fileURLWithPath: "/Applications/Driftflow.app")

    static func offerIfNeeded() {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let path = bundle.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        guard !path.hasPrefix("/Applications/"), !path.hasPrefix(userApplications + "/"),
              !path.contains("/build.noindex/"), // a developer build
              !UserDefaults.standard.bool(forKey: declinedKey)
        else { return }

        let alert = NSAlert()
        alert.messageText = "Move Driftflow to your Applications folder?"
        alert.informativeText = "Driftflow is running from \(place(of: path)). From Applications it can update itself, keep its microphone and Accessibility permissions, and open at login."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate()
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: declinedKey) }
        guard answer == .alertFirstButtonReturn else {
            AppLog.info("Not moved to Applications (running from \(place(of: path)))")
            return
        }
        do {
            let files = FileManager.default
            if files.fileExists(atPath: destination.path) {
                try files.trashItem(at: destination, resultingItemURL: nil) // an older copy
            }
            try files.copyItem(at: bundle, to: destination)
            AppLog.info("Moved to Applications from \(place(of: path))")
            AppLog.flush()
            // Open the moved copy once this one has quit.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", destination.path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            AppLog.error("Couldn't move to Applications: \(error.localizedDescription)")
            let failed = NSAlert()
            failed.messageText = "Driftflow couldn't move itself"
            failed.informativeText = "\(error.localizedDescription)\n\nQuit Driftflow, then drag it into the Applications folder in Finder."
            failed.runModal()
        }
    }

    /// "the installer disk image", "Downloads"…, for the prompt and the log.
    private static func place(of path: String) -> String {
        if path.hasPrefix("/Volumes/") { return "the installer disk image" }
        if path.contains("/AppTranslocation/") { return "a temporary copy macOS made (it hasn't been moved to Applications)" }
        if path.contains("/Downloads/") { return "your Downloads folder" }
        return (path as NSString).deletingLastPathComponent
    }
}
