import AppKit

/// Developer aid (`DRIFTFLOW_DATA_DIR=<dir> Driftflow --perf-test <file>`): opens the main window
/// and moves between sections, writing how long each step took and the longest the main thread
/// froze meanwhile (what feels like lag). Needs DRIFTFLOW_DATA_DIR, so it never reads your history.
@MainActor
enum PerfTest {
    static func run(to file: URL) async {
        guard ProcessInfo.processInfo.environment["DRIFTFLOW_DATA_DIR"] != nil else {
            try? "Set DRIFTFLOW_DATA_DIR to a test folder.".write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let watchdog = Watchdog()
        var lines = ["\(HistoryStore.shared.entries.count) history entries"]
        func step(_ name: String, settle: Double = 1.5, _ body: () -> Void) async {
            watchdog.reset()
            body()
            try? await Task.sleep(for: .seconds(settle))
            lines.append("\(name): longest freeze \(watchdog.longestMs) ms")
            try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        await step("open at General") { DictationController.shared.openSettings(.general) }
        await step("switch to History") { SettingsRouter.shared.pane = .history }
        await step("switch to Files") { SettingsRouter.shared.pane = .files }
        await step("switch to Models") { SettingsRouter.shared.pane = .models }
        await step("back to History") { SettingsRouter.shared.pane = .history }
        await step("back to General") { SettingsRouter.shared.pane = .general }
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Pings the main thread every 5 ms from another thread; a ping that waits shows a freeze.
    final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var longest: Double = 0

        init() {
            let thread = Thread { [weak self] in
                while let self {
                    let sent = CFAbsoluteTimeGetCurrent()
                    DispatchQueue.main.async {
                        let waited = (CFAbsoluteTimeGetCurrent() - sent) * 1000
                        self.lock.lock()
                        self.longest = max(self.longest, waited)
                        self.lock.unlock()
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            thread.start()
        }

        func reset() { lock.lock(); longest = 0; lock.unlock() }
        var longestMs: Int { lock.lock(); defer { lock.unlock() }; return Int(longest) }
    }
}
