import Combine
import Sparkle

/// Auto-updates through Sparkle. Driftflow checks the feed in Info.plist once a day, downloads a
/// new version quietly and installs it when the app quits; "Check for Updates…" asks right away.
/// Every update must be signed with the key whose public half is SUPublicEDKey.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updater()

    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?

    private override init() {
        super.init()
        // Only a real run updates itself: never a developer run with a test flag.
        let start = !CommandLine.arguments.contains { $0.hasPrefix("--") }
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: self)
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var automaticallyInstalls: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    // Driftflow is a menu bar app: when Sparkle does need to show a scheduled update, it shouldn't
    // pull focus away from what you're typing.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        AppLog.info("Update available: \(item.displayVersionString)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // "No update found" arrives here too; it isn't a problem.
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) { return }
        AppLog.error("Update failed: \(error.localizedDescription)")
    }
}
