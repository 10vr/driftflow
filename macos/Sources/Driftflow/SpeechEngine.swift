@preconcurrency import AVFoundation
import Foundation
import Speech

/// What to transcribe: language, accent, Apple model preference and vocabulary hints.
struct SpeechConfig: Equatable {
    /// ISO 639 language code, e.g. "en", "ms", "de".
    var language: String
    /// Region for the language's accent, e.g. "GB"; "" = match the Mac, then the language's home.
    var accent: String = ""
    var model: ModelPreference
    var vocabulary: [String]
}

/// Every language Apple's on-device models support, with the regions (accents) available.
struct SpeechCatalog: Sendable {
    let speech: Set<String>     // SpeechTranscriber locales (bcp47)
    let dictation: Set<String>  // DictationTranscriber locales (bcp47)

    var all: Set<String> { speech.union(dictation) }

    func regions(for language: String) -> [String] {
        all.compactMap { id -> String? in
            let parts = id.split(separator: "-")
            return parts.count == 2 && parts[0] == Substring(language) ? String(parts[1]) : nil
        }
        .sorted()
    }

    var languages: [String] {
        Array(Set(all.compactMap { $0.split(separator: "-").first.map(String.init) })).sorted()
    }

    /// The exact locale to use: chosen accent → the Mac's region → the language's home region
    /// (German → Germany) → the first available. Never a locale the models don't list.
    func locale(for language: String, accent: String) -> String? {
        let available = Set(regions(for: language))
        let home = Locale.Language(identifier: language).maximalIdentifier
            .split(separator: "-").last.map(String.init)
        let candidates = [accent, Locale.current.language.region?.identifier, Locale.current.region?.identifier, home]
        for case let region? in candidates where !region.isEmpty && available.contains(region) {
            return "\(language)-\(region)"
        }
        return regions(for: language).first.map { "\(language)-\($0)" }
    }

    /// The region the accent picker shows for "Match my Mac".
    func automaticRegion(for language: String) -> String? {
        locale(for: language, accent: "")?.split(separator: "-").last.map(String.init)
    }

    /// Apple's models, or nil before macOS 26 (which doesn't have SpeechAnalyzer).
    static func current() async -> SpeechCatalog? {
        guard #available(macOS 26.0, *), !SpeechEngine.disabledForTesting else { return nil }
        return await SpeechEngine.catalog()
    }

    /// "English (United States)". Handles IDs with regional overrides like "en_US@rg=myzzzz",
    /// which `localizedString(forIdentifier:)` can't name.
    static func displayName(for identifier: String) -> String {
        let base = String(identifier.split(separator: "@").first ?? Substring(identifier))
        return Locale.current.localizedString(forIdentifier: base) ?? base
    }
}

/// One dictation's audio. Always recorded at 16 kHz for Parakeet; on macOS 26 also streamed to
/// Apple's model (`DictationSession`), which adds live text, phrase ends and a fallback transcript.
@MainActor
protocol SpeechSession: AnyObject {
    nonisolated var recorder: SampleRecorder { get }
    /// Audio thread.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer)
    /// The language being transcribed ("en"), for choosing the final model and cleanup rules.
    var languageCode: String? { get }
    /// Called with a phrase's end time in seconds when the speaker pauses.
    var onPhraseEnd: ((Double) -> Void)? { get set }
    /// Ends input; returns Apple's transcript ("" without Apple's model).
    func finish() async throws -> String
    func cancel() async
}

/// macOS 15: records only. Parakeet writes both the live preview and the final text, and
/// `PauseDetector` supplies the phrase ends that Apple's model reports on macOS 26.
@MainActor
final class RecordingSession: SpeechSession {
    nonisolated let recorder = SampleRecorder()
    let languageCode: String?
    var onPhraseEnd: ((Double) -> Void)?

    init(language: String) { languageCode = language }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) { recorder.append(buffer) }
    func finish() async throws -> String { "" }
    func cancel() async {}
}

/// Wraps Apple's on-device SpeechAnalyzer (macOS 26). Models run on the Neural Engine and are
/// shared system-wide, so nothing is bundled with the app and no audio leaves the Mac.
@available(macOS 26.0, *)
@MainActor
final class SpeechEngine {
    typealias Config = SpeechConfig
    typealias Catalog = SpeechCatalog

    /// `DRIFTFLOW_NO_APPLE_SPEECH=1` makes the app behave as on macOS 15 (Parakeet only), for testing.
    nonisolated static let disabledForTesting = ProcessInfo.processInfo.environment["DRIFTFLOW_NO_APPLE_SPEECH"] == "1"

    static func catalog() async -> Catalog {
        Catalog(speech: Set(await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }),
                dictation: Set(await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }))
    }

    enum Model {
        case speech
        case dictation

        var displayName: String {
            switch self {
            case .speech: "SpeechTranscriber"
            case .dictation: "DictationTranscriber"
            }
        }
    }

    struct Language: Identifiable, Hashable {
        let id: String
        let name: String
        let model: Model
        let installed: Bool
    }

    /// An analyzer whose model is loaded and ready to accept audio.
    struct Prepared: @unchecked Sendable {
        let config: Config
        let locale: Locale
        let model: Model
        let analyzer: SpeechAnalyzer
        let module: any SpeechModule
        let format: AVAudioFormat
    }

    enum EngineError: LocalizedError {
        case unsupportedLanguage(String)
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let id): "“\(id)” isn't supported by the on-device speech models."
            case .noAudioFormat: "The speech model didn't report a usable audio format."
            }
        }
    }

    /// Reports model download progress (0...1), or nil when no download is running.
    var onDownloadProgress: ((Double?) -> Void)?

    private var prewarmTask: Task<Prepared, Error>?
    private var prewarmConfig: Config?

    // MARK: Languages

    /// Exact matching only: `supportedLocale(equivalentTo:)` was measured to claim models that
    /// don't exist (SpeechTranscriber answers "ms-MY" for Malay) and to pick odd regions ("de-AT").
    static func resolve(_ config: Config) async -> (Locale, Model)? {
        let catalog = await catalog()
        guard let id = catalog.locale(for: config.language, accent: config.accent) else { return nil }
        if config.model == .automatic, catalog.speech.contains(id) {
            return (Locale(identifier: id), .speech)
        }
        if catalog.dictation.contains(id) {
            return (Locale(identifier: id), .dictation)
        }
        return catalog.speech.contains(id) ? (Locale(identifier: id), .speech) : nil
    }

    static func displayName(for identifier: String) -> String { SpeechCatalog.displayName(for: identifier) }

    static func availableLanguages(preference: ModelPreference) async -> [Language] {
        let speech = preference == .automatic ? Set(await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }) : []
        let speechInstalled = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        let dictation = Set(await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) })
        let dictationInstalled = Set(await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) })

        return speech.union(dictation).map { id in
            let model: Model = speech.contains(id) ? .speech : .dictation
            let installed = model == .speech ? speechInstalled.contains(id) : dictationInstalled.contains(id)
            let name = displayName(for: id)
            return Language(id: id, name: name, model: model, installed: installed)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `timestamps` adds per-word audio times (for file transcripts and subtitles).
    private static func makeModule(locale: Locale, model: Model, timestamps: Bool) -> any SpeechModule {
        switch model {
        case .speech:
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: timestamps ? [] : [.volatileResults, .fastResults],
                attributeOptions: timestamps ? [.audioTimeRange] : []
            )
        case .dictation:
            DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: timestamps ? [] : [.volatileResults, .frequentFinalization],
                attributeOptions: timestamps ? [.audioTimeRange] : []
            )
        }
    }

    // MARK: Preparation

    /// Downloads the model for `module` if the system doesn't have it yet.
    func ensureInstalled(_ module: any SpeechModule, locale: Locale) async throws {
        guard await AssetInventory.status(forModules: [module]) != .installed else { return }
        _ = try? await AssetInventory.reserve(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }

        onDownloadProgress?(0)
        defer { onDownloadProgress?(nil) }
        let progress = request.progress
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.onDownloadProgress?(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
    }

    func prepare(_ config: Config, timestamps: Bool = false) async throws -> Prepared {
        guard let (locale, model) = await Self.resolve(config) else {
            throw EngineError.unsupportedLanguage(Locale.current.localizedString(forLanguageCode: config.language) ?? config.language)
        }
        let module = Self.makeModule(locale: locale, model: model, timestamps: timestamps)
        try await ensureInstalled(module, locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw EngineError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if !config.vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = config.vocabulary
            try await analyzer.setContext(context)
        }
        // Loads the model into memory now so the first words of the next dictation aren't delayed.
        try await analyzer.prepareToAnalyze(in: format)
        return Prepared(config: config, locale: locale, model: model, analyzer: analyzer, module: module, format: format)
    }

    /// Prepares an analyzer in the background for the next dictation.
    func prewarm(_ config: Config) {
        if prewarmConfig == config, prewarmTask != nil { return }
        prewarmTask?.cancel()
        prewarmConfig = config
        prewarmTask = Task { try await self.prepare(config) }
    }

    /// Returns a running session, reusing the pre-warmed analyzer when the config still matches.
    func begin(_ config: Config, onUpdate: @escaping @MainActor (String, String) -> Void) async throws -> DictationSession {
        // Claim the pre-warmed analyzer before waiting on it, so two quick dictations (one aborted
        // while loading) can never share one, and the next prewarm() starts a fresh one.
        let task = prewarmTask
        let warmedFor = prewarmConfig
        prewarmTask = nil
        prewarmConfig = nil
        let prepared: Prepared
        if let task, warmedFor == config, let ready = try? await task.value {
            prepared = ready
        } else {
            task?.cancel()
            prepared = try await prepare(config)
        }

        let session = DictationSession(prepared: prepared, onUpdate: onUpdate)
        try await session.start()
        return session
    }
}

/// One dictation: audio in, text out. `feed` is called from the audio thread; everything else on the main actor.
@available(macOS 26.0, *)
@MainActor
final class DictationSession: SpeechSession {
    let prepared: SpeechEngine.Prepared
    private let inputStream: AsyncStream<AnalyzerInput>
    private nonisolated let continuation: AsyncStream<AnalyzerInput>.Continuation
    private nonisolated(unsafe) var converter: AVAudioConverter?
    /// Full utterance at 16 kHz for the Parakeet final pass.
    nonisolated let recorder = SampleRecorder()
    /// False for file transcription, which doesn't need a second copy of the audio.
    private nonisolated let recordsSamples: Bool
    private let onUpdate: @MainActor (String, String) -> Void
    private var resultsTask: Task<Void, Error>?

    /// Called on the main actor when the model finalizes a phrase, with its end time in seconds.
    var onPhraseEnd: ((Double) -> Void)?
    /// Called on the main actor with each finalized result, including any per-word audio times.
    var onFinalResult: ((AttributedString) -> Void)?
    private(set) var finalized = ""
    private(set) var volatile = ""

    var text: String { (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
    var languageCode: String? { prepared.locale.language.languageCode?.identifier }
    nonisolated var format: AVAudioFormat { prepared.format }

    init(prepared: SpeechEngine.Prepared, recordsSamples: Bool = true, onUpdate: @escaping @MainActor (String, String) -> Void) {
        self.prepared = prepared
        self.recordsSamples = recordsSamples
        self.onUpdate = onUpdate
        (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    func start() async throws {
        let module = prepared.module
        resultsTask = Task { @MainActor [weak self] in
            if let transcriber = module as? SpeechTranscriber {
                for try await result in transcriber.results {
                    if result.isFinal { self?.onFinalResult?(result.text) }
                    self?.handle(String(result.text.characters), isFinal: result.isFinal, range: result.range)
                }
            } else if let transcriber = module as? DictationTranscriber {
                for try await result in transcriber.results {
                    if result.isFinal { self?.onFinalResult?(result.text) }
                    self?.handle(String(result.text.characters), isFinal: result.isFinal, range: result.range)
                }
            }
        }
        try await prepared.analyzer.start(inputSequence: inputStream)
    }

    private func handle(_ text: String, isFinal: Bool, range: CMTimeRange) {
        if isFinal {
            finalized += text
            volatile = ""
            if range.end.isNumeric {
                onPhraseEnd?(range.end.seconds)
            }
        } else {
            volatile = text
        }
        onUpdate(finalized, volatile)
    }

    /// Converts a microphone buffer to the analyzer's format and queues it. Audio thread.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        if recordsSamples { recorder.append(buffer) }
        let target = prepared.format
        if buffer.format == target {
            if let copy = buffer.deepCopy() { continuation.yield(AnalyzerInput(buffer: copy)) }
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status != .error, output.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    /// Ends input, waits for the model to finalize everything it heard, and returns the text.
    func finish() async throws -> String {
        continuation.finish()
        try await prepared.analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        return text
    }

    func cancel() async {
        continuation.finish()
        resultsTask?.cancel()
        await prepared.analyzer.cancelAndFinishNow()
    }
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let from = s.mData, let to = d.mData else { continue }
            memcpy(to, from, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }
}
