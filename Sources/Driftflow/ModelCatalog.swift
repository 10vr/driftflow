import FluidAudio
import Foundation

/// The model that writes the final text. (The live preview while you speak always comes from
/// Apple's built-in speech model, which needs no download and streams instantly.)
enum AccuracyModel: String, CaseIterable, Identifiable {
    case parakeetUnified
    case parakeetV2
    case parakeetV3
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetUnified: "Parakeet Unified"
        case .parakeetV2: "Parakeet TDT v2"
        case .parakeetV3: "Parakeet TDT v3"
        case .apple: "Apple Speech"
        }
    }

    var badge: String {
        switch self {
        case .parakeetUnified: "Recommended"
        case .parakeetV2: "Fastest"
        case .parakeetV3: "25 languages"
        case .apple: "Built in"
        }
    }

    var summary: String {
        switch self {
        case .parakeetUnified: "Most accurate English model. NVIDIA, 0.6B parameters, runs on the Neural Engine."
        case .parakeetV2: "A few milliseconds faster, slightly less accurate. English only."
        case .parakeetV3: "English plus 24 European languages: French, German, Spanish, Italian, Portuguese, Dutch, Polish, Russian…"
        case .apple: "No download. The same model that powers the live preview. Covers 50+ languages, including Malay."
        }
    }

    /// Measured on this Mac (M5): 300 LibriSpeech recordings, 5,603 words, numbers normalized.
    var englishErrorRate: Double {
        switch self {
        case .parakeetUnified: 2.55
        case .parakeetV2: 2.89
        case .parakeetV3: 2.96
        case .apple: 3.30
        }
    }

    /// Median time to transcribe a clip (key release → text for a typical dictation).
    /// Share of words transcribed correctly in the same test (100 − word error rate).
    var accuracy: Double { 100 - englishErrorRate }

    var medianMilliseconds: Int {
        switch self {
        case .parakeetUnified: 51
        case .parakeetV2: 47
        case .parakeetV3: 46
        case .apple: 98
        }
    }

    var languagesLabel: String {
        switch self {
        case .parakeetUnified, .parakeetV2: "English"
        case .parakeetV3: "25 languages"
        case .apple: "50+ languages"
        }
    }

    var downloadSize: String {
        switch self {
        case .parakeetUnified: "590 MB"
        case .parakeetV2: "445 MB"
        case .parakeetV3: "470 MB"
        case .apple: "Managed by macOS"
        }
    }

    static let v3Languages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// Whether this model can write the final text for `language` (ISO 639-1 code).
    func supports(language: String?) -> Bool {
        guard let language else { return false }
        switch self {
        case .parakeetUnified, .parakeetV2: return language == "en"
        case .parakeetV3: return Self.v3Languages.contains(language)
        case .apple: return true
        }
    }

    var needsDownload: Bool { self != .apple }
}

/// Tracks which Parakeet models are on disk, and downloads or deletes them.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Status: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    @Published private(set) var status: [AccuracyModel: Status] = [:]

    private var downloads: [AccuracyModel: Task<Void, Never>] = [:]

    private init() {
        refresh()
    }

    func status(of model: AccuracyModel) -> Status {
        model.needsDownload ? status[model] ?? .notDownloaded : .downloaded
    }

    func isDownloaded(_ model: AccuracyModel) -> Bool {
        status(of: model) == .downloaded
    }

    /// Re-checks the model files on disk.
    func refresh() {
        for model in AccuracyModel.allCases where model.needsDownload {
            if case .downloading = status[model] { continue }
            status[model] = Self.filesExist(for: model) ? .downloaded : .notDownloaded
        }
    }

    /// Called by the engine while it downloads the model it's loading.
    func reportProgress(_ model: AccuracyModel, _ progress: Double?) {
        guard model.needsDownload else { return }
        if let progress {
            // Loading a model already on disk reports progress too; that isn't a download.
            if case .downloading = status[model] {} else if Self.filesExist(for: model) { return }
            status[model] = .downloading(progress)
        } else {
            status[model] = Self.filesExist(for: model) ? .downloaded : .notDownloaded
        }
    }

    func download(_ model: AccuracyModel) {
        guard model.needsDownload, downloads[model] == nil, !isDownloaded(model) else { return }
        status[model] = .downloading(0)
        let id = UUID()
        downloadIDs[model] = id
        // Only the current download may report: a cancelled one can finish later and must not
        // overwrite the state of a new download of the same model.
        let isCurrent = { @MainActor in ModelManager.shared.downloadIDs[model] == id }
        downloads[model] = Task {
            do {
                let progress: ProgressHandler = { progress in
                    Task { @MainActor in
                        if isCurrent() { ModelManager.shared.status[model] = .downloading(progress.fractionCompleted) }
                    }
                }
                switch model {
                case .parakeetV2:
                    _ = try await AsrModels.download(version: .v2, progressHandler: progress)
                case .parakeetV3:
                    _ = try await AsrModels.download(version: .v3, progressHandler: progress)
                case .parakeetUnified:
                    // Unified exposes download only through loading; load once, then let it go.
                    try await UnifiedAsrManager().loadModels(progressHandler: progress)
                case .apple:
                    break
                }
                guard isCurrent() else { return }
                status[model] = Self.filesExist(for: model) ? .downloaded : .failed("Download incomplete")
            } catch {
                guard isCurrent() else { return }
                status[model] = .failed(error.localizedDescription)
            }
            downloads[model] = nil
            downloadIDs[model] = nil
        }
    }

    private var downloadIDs: [AccuracyModel: UUID] = [:]

    func cancelDownload(_ model: AccuracyModel) {
        downloads[model]?.cancel()
        downloads[model] = nil
        downloadIDs[model] = nil
        status[model] = Self.filesExist(for: model) ? .downloaded : .notDownloaded
    }

    /// TDT v2 and v3 live in FluidAudio's shared model folder, which other apps built on it
    /// (FluidVoice, for one) use too: deleting them here deletes their copy as well.
    static func isShared(_ model: AccuracyModel) -> Bool { model == .parakeetV2 || model == .parakeetV3 }

    func delete(_ model: AccuracyModel) {
        guard let directory = Self.directory(for: model) else { return }
        try? FileManager.default.removeItem(at: directory)
        refresh()
    }

    /// Bytes on disk, for the model rows.
    func sizeOnDisk(_ model: AccuracyModel) -> Int64? {
        guard let directory = Self.directory(for: model),
              let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total > 0 ? total : nil
    }

    private static func directory(for model: AccuracyModel) -> URL? {
        switch model {
        case .parakeetV2: AsrModels.defaultCacheDirectory(for: .v2)
        case .parakeetV3: AsrModels.defaultCacheDirectory(for: .v3)
        case .parakeetUnified:
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FluidAudio/Models/parakeet-unified-en-0.6b", isDirectory: true)
        case .apple: nil
        }
    }

    private static func filesExist(for model: AccuracyModel) -> Bool {
        guard let directory = directory(for: model) else { return true }
        switch model {
        case .parakeetV2: return AsrModels.modelsExist(at: directory, version: .v2)
        case .parakeetV3: return AsrModels.modelsExist(at: directory, version: .v3)
        case .parakeetUnified:
            let encoder = directory.appendingPathComponent(ModelNames.ParakeetUnified.offlineEncoderFile(precision: .int8))
            return FileManager.default.fileExists(atPath: encoder.path)
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocab.json").path)
        case .apple: return true
        }
    }
}
