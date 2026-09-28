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
    /// Local time with its offset (like crash reports), e.g. 2026-09-28T15:07:03.662+08:00.
    /// Used only on `queue`, or before any logging starts.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()

    /// When a log line was written (lines from 0.2.6–0.2.7 are UTC without an offset).
    private static func date(ofLine line: Substring) -> Date? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let text = String(line[line.index(after: line.startIndex)..<close])
        if let date = queue.sync(execute: { stamp.date(from: text) }) { return date }
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return utc.date(from: text)
    }
    /// Developer runs with a test flag don't write to the real log.
    private static let enabled = !CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
        || (CommandLine.arguments.contains("--log-test") && ProcessInfo.processInfo.environment["DRIFTFLOW_LOG_PATH"] != nil)

    static func info(_ message: String) { write("INFO", message) }
    /// Waits for pending lines to be written (at quit).
    static func flush() { queue.sync {} }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        system.log("\(message, privacy: .public)")
        guard enabled else { return }
        let date = Date()
        queue.async {
            let line = "[\(stamp.string(from: date))] [\(level)] \(message)\n"
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

    /// Everything that helps diagnose a problem, ready to paste into a message: the system
    /// summary, Driftflow's recent crash reports (summarised), and the log of past sessions
    /// (this file and the one before it, up to `lines` lines).
    static func report(lines count: Int = 5_000, fullCrashReports: Bool = false) -> String {
        queue.sync {} // let pending lines land first
        let older = (try? String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = (older + current).split(separator: "\n", omittingEmptySubsequences: true)
        let crashes = CrashReports.recent()
        var text = "\(systemSummary)\nLog: \(url.path) (\(min(lines.count, count)) of \(lines.count) lines)\n"
        text += "\n== Crash reports (last 14 days): \(crashes.isEmpty ? "none" : String(crashes.count)) ==\n"
        for crash in crashes {
            text += "\n" + (fullCrashReports ? crash.full : crash.summary) + "\n"
        }
        text += "\n== Log ==\n" + lines.suffix(count).joined(separator: "\n") + "\n"
        return text
    }

    static func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
    }

    /// Writes the complete report (every log line kept, full crash reports) to a file you choose.
    @MainActor
    static func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Driftflow diagnostics \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try report(lines: .max, fullCrashReports: true).write(to: destination, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Call first thing at launch: notes when the previous session didn't end with Quit (a crash,
    /// a force quit or a power loss), so the log shows where it stopped.
    static func noteHowLastSessionEnded() {
        guard enabled else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let lastStart = text.range(of: "] Started", options: .backwards) else { return }
        if text[lastStart.upperBound...].contains("] Quit") { return }
        // That session's crash report, if any: one written after it started.
        let lineStart = text[..<lastStart.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let startedAt = date(ofLine: text[lineStart...]) ?? .distantPast
        let crash = CrashReports.recent(days: 14).first { $0.modified > startedAt }
        error("The previous session ended unexpectedly" + (crash.map { " (crash report \($0.date): \($0.headline))" } ?? " (no crash report: force quit, logout or power loss?)"))
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

/// Driftflow's crash reports, which macOS keeps in ~/Library/Logs/DiagnosticReports.
enum CrashReports {
    struct Report {
        let modified: Date
        let date: String
        let headline: String
        let summary: String
        let full: String
    }

    static func recent(days: Int = 14, limit: Int = 5) -> [Report] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Driftflow") && $0.pathExtension == "ips" }
            .compactMap { file -> (URL, Date)? in
                guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date > cutoff else { return nil }
                return (file, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return files.compactMap { parse($0.0, modified: $0.1) }
    }

    /// An .ips file is a JSON header line followed by a JSON body.
    private static func parse(_ file: URL, modified: Date) -> Report? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let newline = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any]
        else { return nil }
        let body = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8))) as? [String: Any] ?? [:]
        let date = header["timestamp"] as? String ?? file.lastPathComponent
        let version = "\(header["app_version"] as? String ?? "?") (\(header["build_version"] as? String ?? "?"))"
        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]
        var headline = [exception?["type"] as? String, exception?["signal"] as? String, termination?["indicator"] as? String]
            .compactMap { $0 }.joined(separator: " · ")
        var lines = ["Crash · \(date) · Driftflow \(version) · \(header["os_version"] as? String ?? "")", "  \(headline)"]
        // An uncaught Objective-C exception: its backtrace names the API that raised it.
        if let backtrace = (body["asiBacktraces"] as? [String])?.first {
            lines.append("  Exception backtrace:")
            lines += backtrace.split(separator: "\n").prefix(10).map { "    " + $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(2).joined(separator: " ") }
        }
        if let threads = body["threads"] as? [[String: Any]], let faulting = body["faultingThread"] as? Int, faulting < threads.count,
           let frames = threads[faulting]["frames"] as? [[String: Any]] {
            let images = body["usedImages"] as? [[String: Any]] ?? []
            lines.append("  Crashed thread:")
            for frame in frames.prefix(12) {
                let index = frame["imageIndex"] as? Int ?? -1
                let image = index >= 0 && index < images.count ? images[index]["name"] as? String ?? "?" : "?"
                lines.append("    \(image)  \(frame["symbol"] as? String ?? "?")")
            }
        }
        if headline.isEmpty { headline = "crash" }
        return Report(modified: modified, date: date, headline: headline, summary: lines.joined(separator: "\n"), full: "== \(file.lastPathComponent) ==\n" + text)
    }
}
