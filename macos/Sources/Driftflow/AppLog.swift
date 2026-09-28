import AppKit
import os

/// Driftflow's log file, ~/Library/Logs/Driftflow/driftflow.log: what the app did (launches,
/// dictations with their timing and length, model loads, updates, errors), for "Copy Log for
/// Support". What you dictate is never written to it. Kept to about 2 MB, plus one older file.
enum AppLog {
    static let url = ProcessInfo.processInfo.environment["DRIFTFLOW_LOG_PATH"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Driftflow/driftflow.log")

    private static let queue = DispatchQueue(label: "dev.driftflow.log")
    private static let system = Logger(subsystem: "dev.driftflow.app", category: "app")
    private static let maxBytes = 2_000_000
    /// Developer runs with a test flag don't write to the real log.
    private static let enabled = !CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
        || (CommandLine.arguments.contains("--log-test") && ProcessInfo.processInfo.environment["DRIFTFLOW_LOG_PATH"] != nil)

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        system.log("\(message, privacy: .public)")
        guard enabled else { return }
        let date = Date()
        queue.async {
            let line = "[\(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))] [\(level)] \(message)\n"
            let files = FileManager.default
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let older = url.appendingPathExtension("1")
                try? files.removeItem(at: older)
                try? files.moveItem(at: url, to: older)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Version, macOS, chip and memory: the first line of a support log.
    static var systemSummary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chip = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &chip, &size, nil, 0)
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "Driftflow \(version) (\(build)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · "
            + "\(String(cString: chip)) · \(memory) GB"
    }

    /// The end of the log with the system summary on top, ready to paste into a message.
    static func recent(lines count: Int = 600) -> String {
        queue.sync {} // let pending lines land first
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "(no log yet)"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return "\(systemSummary)\nLog: \(url.path) (last \(min(lines.count, count)) lines)\n\n"
            + lines.suffix(count).joined(separator: "\n")
    }

    static func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recent(), forType: .string)
    }

    static func showInFinder() {
        queue.sync {}
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent().deletingLastPathComponent())
        }
    }
}
