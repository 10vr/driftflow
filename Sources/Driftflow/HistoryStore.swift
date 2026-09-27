import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        /// Transcription failed; `audioFile` holds the recording so it can be retried.
        case failed
    }

    var id = UUID()
    var text: String
    let date: Date
    /// The app the text was dictated into, e.g. "Slack".
    let appName: String?
    /// Key release → text inserted.
    let latencyMs: Int?
    /// nil for a normal dictation.
    var status: Status?
    /// File name in `RescueAudio.directory` while a failed dictation can be retried.
    var audioFile: String?

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

enum HistoryRetention: String, CaseIterable, Identifiable {
    case off, day, week, month, forever

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Don't keep history"
        case .day: "1 day"
        case .week: "7 days"
        case .month: "30 days"
        case .forever: "Forever"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off: 0
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .forever: nil
        }
    }
}

/// Dictation history, kept only on this Mac in ~/Library/Application Support/Driftflow/history.json
/// (readable by your user account only), so it survives restarts and app updates.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "driftflow.history", qos: .utility)

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL) {
            if let saved = try? JSONDecoder.iso.decode([HistoryEntry].self, from: data) {
                entries = saved
            } else {
                // Never overwrite history we couldn't read; keep it aside instead.
                let aside = directory.appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: fileURL, to: aside)
            }
        }
        prune()
    }

    var todayCount: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    func add(_ text: String, appName: String?, latencyMs: Int?) {
        guard AppSettings.shared.historyRetention != .off else { return }
        entries.insert(HistoryEntry(text: text, date: Date(), appName: appName, latencyMs: latencyMs), at: 0)
        prune()
        save()
    }

    /// A failed dictation, kept with its audio so it can be retried.
    func addFailed(audioFile: String?, appName: String?) {
        guard AppSettings.shared.historyRetention != .off else { return }
        entries.insert(HistoryEntry(text: "", date: Date(), appName: appName, latencyMs: nil, status: .failed, audioFile: audioFile), at: 0)
        save()
    }

    func update(_ entry: HistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        if let file = entry.audioFile { RescueAudio.delete(file) }
        save()
    }

    func clear() {
        entries.removeAll()
        RescueAudio.deleteAll()
        save()
    }

    var totalWords: Int { entries.reduce(0) { $0 + $1.wordCount } }

    var wordsThisWeek: Int {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return entries.filter { $0.date >= start }.reduce(0) { $0 + $1.wordCount }
    }

    /// Deletes every saved failed-dictation recording (when you turn keeping them off); the
    /// entries stay, marked failed, without a Retry.
    func discardRescueAudio() {
        var changed = false
        for index in entries.indices where entries[index].audioFile != nil {
            entries[index].audioFile = nil
            changed = true
        }
        RescueAudio.deleteAll()
        if changed { save() }
    }

    /// Drops rescue audio older than 24 hours (the entry stays, marked failed) and files no entry uses.
    /// Also applies the retention period, so old entries go even if you don't dictate for a while.
    func expireRescueAudio() {
        prune()
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        var changed = false
        for index in entries.indices where entries[index].audioFile != nil && entries[index].date < cutoff {
            RescueAudio.delete(entries[index].audioFile!)
            entries[index].audioFile = nil
            changed = true
        }
        RescueAudio.deleteAll(except: Set(entries.compactMap(\.audioFile)))
        if changed { save() }
    }

    /// Drops entries older than the retention period (and caps the list at 5,000).
    func prune() {
        let before = entries.count
        let retention = AppSettings.shared.historyRetention
        if let interval = retention.interval {
            let cutoff = Date().addingTimeInterval(-interval)
            for entry in entries where entry.date < cutoff { if let file = entry.audioFile { RescueAudio.delete(file) } }
            entries.removeAll { $0.date < cutoff }
        }
        if entries.count > 5_000 {
            for entry in entries[5_000...] { if let file = entry.audioFile { RescueAudio.delete(file) } }
            entries.removeLast(entries.count - 5_000)
        }
        if entries.count != before { save() }
    }

    /// Waits for pending writes (at quit).
    func flush() { writeQueue.sync {} }

    private func save() {
        let snapshot = entries
        let url = fileURL
        writeQueue.async {
            guard let data = try? JSONEncoder.iso.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Audio of failed dictations, so they can be retried: 16 kHz mono WAV in
/// ~/Library/Application Support/Driftflow/Rescue (your account only), deleted after a retry or 24 hours.
enum RescueAudio {
    static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftflow/Rescue", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }()

    /// Writes the samples; returns the file name.
    static func save(_ samples: [Float]) -> String? {
        guard !samples.isEmpty else { return nil }
        let name = "\(UUID().uuidString).wav"
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(16_000).littleEndian); append(UInt32(32_000).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(bytes.littleEndian)
        data.reserveCapacity(data.count + Int(bytes))
        for sample in samples { append(Int16(max(-1, min(1, sample)) * 32_767).littleEndian) }
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return name
        } catch {
            FileHandle.standardError.write(Data("[rescue] \(error)\n".utf8))
            return nil
        }
    }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    static func deleteAll(except keep: Set<String> = []) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !keep.contains(file) { delete(file) }
    }
}
