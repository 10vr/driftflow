import AppKit
import Combine
import Sparkle

/// Auto-updates through Sparkle. Driftflow looks for a new version every 10 minutes and when the
/// Mac wakes (a conditional request for the small feed file: nothing is downloaded unless it
/// changed), and downloads it quietly. Then it says so where you can't miss it (a badge on the menu bar icon, a
/// "Restart to Update" item at the top of the menu, and a notice once) and installs it:
/// - when you choose Restart to Update,
/// - by itself once the Mac has been idle for 10 minutes or the screen locks (a menu bar app is
///   rarely quit, so waiting for quit could mean waiting for months), never mid-dictation,
/// - or when Driftflow quits.
/// "Check for Updates…" asks right away. Every update must be signed with the key whose public
/// half is SUPublicEDKey.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updater()

    @Published private(set) var canCheck = false
    /// The version downloaded and waiting to be installed.
    @Published private(set) var readyVersion: String?
    /// What's new in it, as plain text (from the feed).
    private(set) var readyNotes = ""
    private var installHandler: (() -> Void)?
    private var idleTimer: Timer?
    private var lockObserver: NSObjectProtocol?
    /// When the update window was last shown, so "Later" brings it back a day later.
    private var windowShownAt: Date?
    static let idleBeforeInstall: TimeInterval = 10 * 60
    static let remindAfter: TimeInterval = 24 * 3600
    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?

    private override init() {
        super.init()
        // Only a real run updates itself: never a developer run with a test flag.
        let start = !CommandLine.arguments.contains { $0.hasPrefix("--") }
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: self)
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }
        if start { startWatchingFeed() }
    }

    // MARK: Watching the feed

    private var feedTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var feedETag: String?
    static let feedPollInterval: TimeInterval = 10 * 60

    /// Sparkle checks at most hourly; this notices a release within minutes. Each look is one small
    /// conditional request (GitHub answers "not modified" with no body), and only a newer version
    /// starts Sparkle's check and download.
    private func startWatchingFeed() {
        feedTimer = Timer.scheduledTimer(withTimeInterval: Self.feedPollInterval, repeats: true) { [weak self] _ in
            onMainThread { self?.lookForRelease() }
        }
        feedTimer?.tolerance = 60 // lets macOS batch it with other work
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the network a moment to come back after sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { onMainThread { self?.lookForRelease() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in onMainThread { self?.lookForRelease() } }
    }

    private func lookForRelease() {
        guard updater.automaticallyChecksForUpdates, readyVersion == nil, updater.canCheckForUpdates,
              !updater.sessionInProgress,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, let url = URL(string: feed)
        else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if let feedETag { request.setValue(feedETag, forHTTPHeaderField: "If-None-Match") }
        Task {
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { return } // 304: unchanged
            feedETag = http.value(forHTTPHeaderField: "ETag")
            let text = String(decoding: data, as: UTF8.self)
            guard let found = text.range(of: "(?<=<sparkle:shortVersionString>)[^<]+", options: .regularExpression),
                  case let latest = text[found],
                  let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  Self.isNewer(String(latest), than: current), updater.canCheckForUpdates
            else { return }
            AppLog.info("Release \(latest) published: checking for it")
            updater.checkForUpdatesInBackground()
        }
    }

    /// "0.2.10" is newer than "0.2.9".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Installs the downloaded update now; Driftflow quits and reopens in a few seconds.
    func installNow() {
        guard let installHandler else { return }
        AppLog.info("Installing update \(readyVersion ?? "?")")
        AppLog.flush()
        installHandler()
    }

    private func updateReady(version: String, notes: String, install: @escaping () -> Void) {
        let first = readyVersion != version
        readyVersion = version
        readyNotes = notes
        installHandler = install
        guard first else { return }
        AppLog.info("Update \(version) downloaded, ready to install")
        StatusMenu.shared.refreshIcon()
        windowShownAt = nil
        showWindowWhenFree()
        // Every minute: install if nobody's using the Mac, or remind a day after "Later".
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            onMainThread {
                guard let self else { return }
                self.installIfIdle(screenLocked: false)
                if let shown = self.windowShownAt, Date().timeIntervalSince(shown) >= Self.remindAfter,
                   !UpdateWindow.shared.isVisible {
                    self.showWindowWhenFree()
                }
            }
        }
        if lockObserver == nil {
            lockObserver = DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in
                onMainThread { self?.installIfIdle(screenLocked: true) }
            }
        }
    }

    /// Shows the update window once nothing is being dictated, without taking the focus.
    private func showWindowWhenFree() {
        windowShownAt = Date()
        Task {
            while DictationController.shared.phase != .idle { try? await Task.sleep(for: .seconds(2)) }
            guard let version = readyVersion else { return }
            AppLog.info("Showing the update window for \(version)")
            UpdateWindow.shared.show(version: version, notes: readyNotes)
        }
    }

    private func installIfIdle(screenLocked: Bool) {
        guard installHandler != nil,
              DictationController.shared.phase == .idle,
              FileTranscriber.shared.jobs.isEmpty // a long file mid-transcription
        else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard screenLocked || idle >= Self.idleBeforeInstall else { return }
        AppLog.info(screenLocked ? "Screen locked: installing the update" : "Mac idle for \(Int(idle / 60)) min: installing the update")
        installNow()
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

    /// A downloaded update that would otherwise wait for quit: take it over, to install it sooner.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        let notes = Self.plainText(item.itemDescription ?? "")
        DispatchQueue.main.async {
            onMainThread { Updater.shared.updateReady(version: version, notes: notes, install: immediateInstallHandler) }
        }
        return true
    }

    /// The feed's HTML notes as plain lines ("<p>A</p><p>B</p>" → "A\nB").
    nonisolated static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<li>", with: "• ")
            .replacingOccurrences(of: "</p>|</li>|<br ?/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

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
