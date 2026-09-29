@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Final-pass recognizer: while the user talks, Apple's model streams the live preview; on release
/// NVIDIA Parakeet re-reads the utterance on the Neural Engine (~120x real time) and its more
/// accurate text is what gets inserted.
actor ParakeetEngine {
    enum State: Equatable {
        case unloaded
        case loading
        case ready
        case failed(String)
    }

    private enum Backend {
        case tdt(AsrManager, decoderLayers: Int)
        case unified(UnifiedAsrManager)
    }

    private(set) var state: State = .unloaded
    let gate = SpeechGate()
    private var vocabulary: [String] = []
    private var ctcModels: CtcModels?
    /// True once Unified is rescoring against `vocabulary`.
    private(set) var boostingActive = false
    private(set) var vocabularyError: String?
    private var backend: Backend?
    private var loadedModel: AccuracyModel?
    private var loadTask: Task<Void, Error>?
    /// The most recently requested model: a load that was waiting behind another gives way to it.
    private var requestedModel: AccuracyModel?

    var isReady: Bool { state == .ready }
    var isLoading: Bool { state == .loading }

    /// Downloads (first time only) and loads the model, keeping it resident for instant use.
    func load(_ model: AccuracyModel, onProgress: @escaping @Sendable (Double?) -> Void) async throws {
        requestedModel = model
        // Wait for the load in flight. Several callers can be waiting; only the newest proceeds.
        while let current = loadTask {
            try? await current.value
            if loadTask == current { loadTask = nil }
        }
        guard requestedModel == model else { return }
        if model == .apple {
            backend = nil
            loadedModel = model
            state = .unloaded
            return
        }
        if loadedModel == model, backend != nil { return }

        state = .loading
        backend = nil
        let started = Date()
        AppLog.info("Loading speech model \(model.rawValue)")
        let task = Task {
            onProgress(0)
            defer { onProgress(nil) }
            let progress: ProgressHandler = { onProgress($0.fractionCompleted) }
            switch model {
            case .parakeetUnified:
                let manager = UnifiedAsrManager()
                try await manager.loadModels(progressHandler: progress)
                self.install(.unified(manager), model: model)
            case .parakeetV2, .parakeetV3:
                let models = try await AsrModels.downloadAndLoad(version: model == .parakeetV2 ? .v2 : .v3,
                                                                 progressHandler: progress)
                let manager = AsrManager()
                try await manager.loadModels(models)
                self.install(.tdt(manager, decoderLayers: await manager.decoderLayerCount), model: model)
            case .apple:
                break
            }
            await self.gate.load()
            await self.applyVocabulary()
            // One small inference compiles the ANE graphs now instead of on the first dictation.
            // It skips the speech gate, which would (rightly) find no voice in noise.
            _ = try? await self.recognize((0..<16_000).map { _ in Float.random(in: -0.01...0.01) })
        }
        loadTask = task
        do {
            try await task.value
            if loadTask == task { loadTask = nil }
            AppLog.info("Loaded \(model.rawValue) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        } catch {
            if loadTask == task { loadTask = nil }
            state = .failed(error.localizedDescription)
            AppLog.error("Couldn't load \(model.rawValue): \(error.localizedDescription)")
            throw error
        }
    }

    /// The user's words and names. On Parakeet Unified a small companion model (Parakeet CTC
    /// 110M, ~98 MB, downloaded on first use) listens for them in the audio and corrects the
    /// transcript only where the sound matches, e.g. "drift flow" → "Driftflow".
    func setVocabulary(_ terms: [String]) async {
        guard terms != vocabulary else { return }
        vocabulary = terms
        await applyVocabulary()
    }

    /// Calls can overlap (the actor is re-entered at each await), so each one checks after every
    /// await that its word list and model are still current, and a newer call wins.
    private func applyVocabulary() async {
        guard case .unified(let manager) = backend else { return }
        let terms = vocabulary
        if terms.isEmpty {
            // Boosting can't be switched off in place: swap in a fresh copy of the model (its files
            // are on disk, so this takes about a second). The boosted one keeps working meanwhile.
            guard boostingActive else { return }
            let fresh = UnifiedAsrManager()
            guard (try? await fresh.loadModels()) != nil, vocabulary.isEmpty,
                  case .unified(let current) = backend, current === manager else { return }
            backend = .unified(fresh)
            boostingActive = false
            return
        }
        do {
            if ctcModels == nil { ctcModels = try await CtcModels.downloadAndLoad() }
            guard let ctcModels, terms == vocabulary, case .unified(let current) = backend, current === manager else { return }
            let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
            try await manager.configureVocabularyBoosting(vocabulary: context, ctcModels: ctcModels)
            guard terms == vocabulary else { return } // a newer list is being applied
            boostingActive = true
            vocabularyError = nil
        } catch {
            vocabularyError = error.localizedDescription
        }
    }

    /// A freshly loaded model has no vocabulary boosting until `applyVocabulary` adds it.
    private func install(_ backend: Backend, model: AccuracyModel) {
        self.backend = backend
        loadedModel = model
        boostingActive = false
        state = .ready
    }

    /// Transcribes 16 kHz mono samples. Returns nil if no model is loaded.
    func transcribe(_ samples: [Float]) async throws -> String? {
        guard backend != nil else { return nil }
        guard samples.count >= 4_800 else { return "" } // < 0.3 s: nothing to say
        guard await gate.hasSpeech(samples) else { return "" }
        return try await recognize(samples)
    }

    /// The model itself, without the speech gate.
    private func recognize(_ samples: [Float]) async throws -> String? {
        guard let backend else { return nil }
        let text: String
        switch backend {
        case .tdt(let manager, let layers):
            // Trailing silence works around TDT dropping the final words of >15 s inputs.
            let padded = samples + [Float](repeating: 0, count: max(6_400, 16_000 - samples.count))
            var decoderState = TdtDecoderState.make(decoderLayers: layers)
            text = try await manager.transcribe(padded, decoderState: &decoderState).text
        case .unified(let manager):
            let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
            if boostingActive {
                let result = try await manager.transcribeWithTimings(padded)
                let raw = buildWordTimings(from: result.tokenTimings)
                text = VocabularyMerge.merge(raw: raw, boosted: result.text).map(\.word).joined(separator: " ")
            } else {
                text = try await manager.transcribe(padded)
            }
        }
        // Parakeet already writes "25%", "$3,500", "2 p.m.". FluidAudio's extra inverse text
        // normalization was measured to corrupt text ("four to five" → "04:56", "hours" → "h"), so
        // only the conservative prose rules run here.
        return NumberStyle.apply(text)
    }

    /// The loaded model, for labelling file transcripts.
    var model: AccuracyModel? { backend == nil ? nil : loadedModel }

    /// Transcribes 16 kHz mono samples and reports when each word was spoken (seconds from the
    /// start of `samples`). Raw model text: callers apply `NumberStyle` to the finished lines.
    func transcribeWords(_ samples: [Float]) async throws -> [WordTiming]? {
        guard let backend else { return nil }
        guard samples.count >= 4_800 else { return [] }
        guard await gate.hasSpeech(samples) else { return [] }
        switch backend {
        case .tdt(let manager, let layers):
            let padded = samples + [Float](repeating: 0, count: max(6_400, 16_000 - samples.count))
            var decoderState = TdtDecoderState.make(decoderLayers: layers)
            let result = try await manager.transcribe(padded, decoderState: &decoderState)
            return buildWordTimings(from: result.tokenTimings ?? [])
        case .unified(let manager):
            let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
            let result = try await manager.transcribeWithTimings(padded)
            let raw = buildWordTimings(from: result.tokenTimings)
            return boostingActive ? VocabularyMerge.merge(raw: raw, boosted: result.text) : raw
        }
    }
}

/// Folds vocabulary corrections back into the model's own words, keeping their timings and
/// guarding against over-eager replacements: the rescorer was measured turning "the parakeet
/// benchmark" into "Parakeet benchmark", so small words it swallows are put back.
enum VocabularyMerge {
    private static let smallWords: Set<String> = ["the", "a", "an", "to", "of", "and", "in", "on", "at", "for", "with",
                                                  "my", "our", "your", "is", "it", "this", "that", "from", "by", "as"]

    static func merge(raw: [WordTiming], boosted: String) -> [WordTiming] {
        let new = boosted.split(separator: " ").map(String.init)
        let a = raw.map { key($0.word) }, b = new.map(key)
        guard a != b else { return raw.enumerated().map { WordTiming(word: new[$0.offset], startTime: $0.element.startTime, endTime: $0.element.endTime) } }
        // Longest common subsequence over normalized words.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [WordTiming] = []
        var i = 0, j = 0
        func flush(_ rawRange: Range<Int>, _ newRange: Range<Int>) {
            guard !rawRange.isEmpty || !newRange.isEmpty else { return }
            let span = rawRange.isEmpty ? nil : (raw[rawRange.lowerBound].startTime, raw[rawRange.upperBound - 1].endTime)
            var words = Array(new[newRange])
            // Put back leading/trailing small words the replacement swallowed.
            let rawWords = raw[rawRange].map(\.word)
            let newKeys = Set(words.map(key))
            let leading = rawWords.prefix { smallWords.contains(key($0)) && !newKeys.contains(key($0)) }
            let trailing = rawWords.dropFirst(leading.count).reversed().prefix { smallWords.contains(key($0)) && !newKeys.contains(key($0)) }.reversed()
            // Only trust a replacement that resembles what the model heard ("Lamink Kilako" →
            // "Luminkilako"); the rescorer was measured swapping in unrelated terms ("paper" →
            // "Parakeet", "magician" → "Luminkilako") that this rejects.
            let heard = rawWords.dropFirst(leading.count).dropLast(trailing.count).map(key).joined()
            if !words.isEmpty, !heard.isEmpty, similarity(heard, words.map(key).joined()) < minimumSimilarity {
                words = rawWords
            } else if !words.isEmpty {
                words = Array(leading) + words + Array(trailing)
            } else {
                words = rawWords
            }
            let (start, end) = span ?? (result.last?.endTime ?? 0, result.last?.endTime ?? 0)
            let step = (end - start) / Double(max(words.count, 1))
            for (k, word) in words.enumerated() {
                result.append(WordTiming(word: word, startTime: start + step * Double(k), endTime: start + step * Double(k + 1)))
            }
        }
        var rawStart = 0, newStart = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                flush(rawStart..<i, newStart..<j)
                result.append(WordTiming(word: new[j], startTime: raw[i].startTime, endTime: raw[i].endTime))
                i += 1; j += 1
                rawStart = i; newStart = j
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        flush(rawStart..<a.count, newStart..<b.count)
        return result
    }

    static let minimumSimilarity = 0.65

    /// 1 − edit distance / longer length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    private static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Stops the model from inventing words for silence: given about a second of room tone Parakeet
/// answers "Yeah.", so audio with no voice in it is never sent to the model. Silero VAD (~2 MB,
/// Neural Engine) decides; a quick loudness check skips it for plainly silent audio.
actor SpeechGate {
    private var vad: VadManager?
    private var loading: Task<VadManager?, Never>?

    /// Speech probability that counts as a voice. Low on purpose: this gate only has to tell
    /// "someone spoke" from "nobody did", and must never drop quiet speech.
    static let threshold: Float = 0.3

    func load() async {
        if vad != nil { return }
        if loading == nil { loading = Task { try? await VadManager() } }
        vad = await loading?.value
        if vad == nil { loading = nil } // failed (e.g. offline on first run): try again next time
    }

    /// False only when the audio clearly holds no voice. Without the VAD model it lets audio through.
    func hasSpeech(_ samples: [Float]) async -> Bool {
        if Self.peakDecibels(samples) < -52 { return false } // nothing louder than a quiet room
        guard let vad else { return true }
        guard let results = try? await vad.process(samples) else { return true }
        return results.contains { $0.probability >= Self.threshold }
    }

    /// Loudest 32 ms window, in dBFS.
    static func peakDecibels(_ samples: [Float]) -> Float {
        var peak: Float = 0
        var index = 0
        while index + 512 <= samples.count {
            var sum: Float = 0
            for i in index..<(index + 512) { sum += samples[i] * samples[i] }
            peak = max(peak, sum / 512)
            index += 512
        }
        return 10 * log10(max(peak, 1e-12))
    }
}

/// Accumulates the utterance as 16 kHz mono Float samples for the final pass. Audio thread.
final class SampleRecorder: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?

    init() {
        samples.reserveCapacity(16_000 * 30)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
        }
        guard let converter else { return }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var consumed = false
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        lock.unlock()
    }

    func take() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Copies only `range` (clamped), so incremental segments don't copy the whole recording.
    func take(from start: Int, to end: Int? = nil) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let upper = min(end ?? samples.count, samples.count)
        guard start < upper else { return [] }
        return Array(samples[start..<upper])
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }
}

/// Prose-friendly numbers after inverse text normalization: "at first", "two or three", but
/// "March 1st", "3 p.m.", "version 2", "5%", "$4".
enum NumberStyle {
    private static let ordinals = ["1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth", "5th": "fifth",
                                   "6th": "sixth", "7th": "seventh", "8th": "eighth", "9th": "ninth"]
    private static let cardinals = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august",
                                              "september", "october", "november", "december", "jan", "feb", "mar", "apr",
                                              "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
    /// Words after which a digit is a label, not a quantity.
    private static let labels: Set<String> = ["version", "v", "chapter", "page", "step", "number", "no", "room", "level",
                                              "option", "phase", "round", "part", "section", "grade", "size", "gate",
                                              "floor", "line", "item", "day", "week", "q", "iphone", "windows", "episode",
                                              "season", "act", "scene", "figure", "table", "slide", "stage", "tier", "plan"]
    private static let pattern = try! NSRegularExpression(pattern: #"(?<![\w$#£€.,:/-])([0-9])(st|nd|rd|th)?(?![\w%°:/-]|[.,]\d|\s*(?:a\.?m\.?|p\.?m\.?|%|percent|am\b|pm\b))"#,
                                                          options: [.caseInsensitive])

    /// "march 3rd" → "March 3rd", "may 29" → "May 29"; "we may go" is left alone.
    private static let monthPattern = try! NSRegularExpression(
        pattern: #"\b(january|february|march|april|may|june|july|august|september|october|november|december)(?=\s+(?:[0-9]|(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|twentieth|twenty|thirtieth|thirty)\b))|(?<=\b[0-9]{1,2}(?:st|nd|rd|th)?\s(?:of\s)?)(january|february|march|april|may|june|july|august|september|october|november|december)\b"#
    )

    static func apply(_ text: String) -> String {
        let text = capitalizeMonths(text)
        let ns = text as NSString
        var result = text
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let digit = Int(ns.substring(with: match.range(at: 1)))!
            let suffix = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : nil
            let before = ns.substring(to: match.range.location)
            let previousWord = before.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() } ?? ""
            let replacement: String
            if let suffix {
                guard !months.contains(previousWord), let word = ordinals["\(digit)\(suffix.lowercased())"] else { continue }
                replacement = word
            } else {
                // Only spell out when it sits between words (a quantity in prose), not after a label
                // or a month ("March 5").
                guard !labels.contains(previousWord), !months.contains(previousWord), !previousWord.isEmpty else { continue }
                replacement = cardinals[digit]
            }
            let range = Range(match.range, in: result)!
            let atSentenceStart = before.trimmingCharacters(in: .whitespaces).last.map { ".!?".contains($0) } ?? true
            result.replaceSubrange(range, with: atSentenceStart ? replacement.capitalized : replacement)
        }
        return result
    }
}

extension NumberStyle {
    static func capitalizeMonths(_ text: String) -> String {
        var result = text
        let ns = text as NSString
        for match in monthPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let swiftRange = Range(range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: ns.substring(with: range).capitalized)
        }
        return result
    }
}

/// Parakeet-driven live text.
///
/// - `early`: Apple's stream needs ~1 s of speech before its first words, while Parakeet turns half
///   a second of audio into text in ~40 ms. So Parakeet shows the opening words, then hands over to
///   Apple as soon as Apple has caught up.
/// - `continuous`: the whole live preview comes from the selected model. A few times a second it
///   re-reads the audio since the last pause-bounded segment (so each read stays short), and
///   finished segments are shown as settled text: the preview is what will be typed.
@MainActor
final class ParakeetPreview {
    enum Mode {
        case early
        case continuous
    }

    private var task: Task<Void, Never>?

    func start(mode: Mode, parakeet: ParakeetEngine, recorder: SampleRecorder, finalizer: SegmentedFinalizer?,
               appleHasText: @escaping @MainActor () -> Bool,
               show: @escaping @MainActor (_ settled: String, _ live: String) -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            let started = ContinuousClock.now
            var lastRead = -1
            // Self-pacing: wait at least twice as long as the last update took, so a slower chip
            // (an M1, or a busy Mac) previews a little less often instead of falling behind.
            var interval: Duration = .milliseconds(mode == .early ? 150 : 200)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if mode == .early, appleHasText() || ContinuousClock.now - started > .seconds(4) { return }
                guard recorder.count >= 6_400 else { continue } // wait for 0.4 s of audio
                // While a finished segment is still being transcribed, keep the current text on screen.
                if let finalizer, finalizer.hasPendingSegments { continue }
                let from = finalizer?.committedSamples ?? 0
                let total = recorder.count
                guard total != lastRead else { continue } // nothing new since the last read
                lastRead = total
                let settled = finalizer?.completedText ?? ""
                let begun = ContinuousClock.now
                let result = try? await parakeet.transcribe(recorder.take(from: from))
                interval = max(.milliseconds(mode == .early ? 150 : 200), (ContinuousClock.now - begun) * 2)
                guard let text = result,
                      !Task.isCancelled, mode == .continuous || !appleHasText() else { continue }
                show(settled, text)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Transcribes long dictations incrementally. Whenever Apple's streaming model finalizes a phrase
/// (it does so at natural pauses) and 8+ seconds are pending, that stretch is handed to Parakeet in
/// the background. On release only the last few seconds remain, so the wait is ~40 ms whether you
/// spoke for 5 seconds or 5 minutes, and chunk seams land on pauses instead of mid-word.
@MainActor
final class SegmentedFinalizer {
    private let parakeet: ParakeetEngine
    private let recorder: SampleRecorder
    private var committed = 0
    private var segments: [Task<String?, Never>] = []
    /// Finished segment texts, in order (nil while that segment is still transcribing).
    private var results: [String?] = []

    /// Audio up to this sample index has been handed to a segment.
    var committedSamples: Int { committed }
    var hasPendingSegments: Bool { results.contains { $0 == nil } }
    /// The settled text of every finished segment, joined.
    var completedText: String { Self.join(results.compactMap { $0 }) }
    private let minimumSegment = 6 * 16_000
    private var finishing = false

    init(parakeet: ParakeetEngine, recorder: SampleRecorder) {
        self.parakeet = parakeet
        self.recorder = recorder
    }

    /// Apple finalized speech up to `seconds` into the utterance.
    func phraseEnded(at seconds: Double) {
        let cut = Int(seconds * 16_000)
        // After finish() starts, the tail already covers this audio.
        guard !finishing, cut - committed >= minimumSegment, cut <= recorder.count else { return }
        let slice = recorder.take(from: committed, to: cut)
        committed = cut
        let parakeet = parakeet
        let index = results.count
        results.append(nil)
        segments.append(Task { @MainActor [weak self] in
            let text = try? await parakeet.transcribe(slice)
            self?.results[index] = text ?? ""
            return text
        })
    }

    /// Transcribes what's left and joins everything. nil means "use Apple's text instead".
    func cancel() {
        finishing = true
        segments.forEach { $0.cancel() }
    }

    func finish() async -> String? {
        finishing = true
        let tail = recorder.take(from: committed)
        var parts: [String] = []
        for segment in segments {
            guard let text = await segment.value else { return nil }
            parts.append(text)
        }
        guard let last = try? await parakeet.transcribe(tail) else { return nil }
        parts.append(last)
        return Self.join(parts)
    }

    static func join(_ parts: [String]) -> String {
        var output = ""
        for part in parts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !part.isEmpty {
            guard let previous = output.last else {
                output = part
                continue
            }
            var next = part
            // A pause mid-sentence shouldn't capitalize the next word ("the client And we").
            let firstWord = next.prefix { $0.isLetter || $0 == "'" }
            if !".!?\n".contains(previous), next.first?.isUppercase == true,
               firstWord != "I", !firstWord.hasPrefix("I'"),
               firstWord.dropFirst().allSatisfy(\.isLowercase) {
                next = next.prefix(1).lowercased() + next.dropFirst()
            } else if ".!?\n".contains(previous), next.first?.isLowercase == true {
                // …and a segment that starts a new sentence gets its capital back.
                next = next.prefix(1).uppercased() + next.dropFirst()
            }
            output += " " + next
        }
        return output
    }
}

/// Finds pauses between phrases in 16 kHz audio, by loudness against an adaptive noise floor.
/// Streaming: feed consecutive samples; returns, for each pause, the sample index of its quietest
/// moment, so a cut never lands inside a word.
struct PauseTracker {
    private static let frame = 320                  // 20 ms
    private let pauseFrames: Int                     // quiet this long ends a phrase
    private let margin: Float                        // dB above the floor that counts as speech
    private var floor: Float = -60                   // dB, follows the room's background noise
    private var spoke = false                        // speech since the last pause
    private var quietFrames = 0
    private var quietest: (db: Float, index: Int) = (0, 0)
    private var pending: [Float] = []
    private var position = 0                         // index of pending[0]

    init(pauseMilliseconds: Int = 400, margin: Float = 9) {
        pauseFrames = pauseMilliseconds / 20
        self.margin = margin
    }

    mutating func consume(_ samples: [Float]) -> [Int] {
        pending += samples
        var cuts: [Int] = []
        var offset = 0
        while pending.count - offset >= Self.frame {
            var energy: Float = 0
            for i in offset..<(offset + Self.frame) { energy += pending[i] * pending[i] }
            let db = 10 * log10(max(energy / Float(Self.frame), 1e-12))
            // The floor drops to quiet frames at once and creeps up slowly, so speech never raises it.
            floor = db < floor ? db : floor + 0.01 * (db - floor)
            if db > floor + margin, db > -55 {
                spoke = true
                quietFrames = 0
            } else {
                let index = position + offset + Self.frame / 2
                if quietFrames == 0 || db < quietest.db { quietest = (db, index) }
                quietFrames += 1
                if spoke, quietFrames == pauseFrames {
                    cuts.append(quietest.index)
                    spoke = false
                }
            }
            offset += Self.frame
        }
        pending.removeFirst(offset)
        position += offset
        return cuts
    }
}

/// macOS 15: reports pauses in the dictation as it's recorded, standing in for the phrase ends
/// Apple's model reports on macOS 26, so long dictations are transcribed in pieces while you talk.
@MainActor
final class PauseDetector {
    private var task: Task<Void, Never>?

    func start(recorder: SampleRecorder, onPause: @escaping @MainActor (Double) -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            var tracker = PauseTracker()
            var read = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let total = recorder.count
                guard total > read else { continue }
                let cuts = tracker.consume(recorder.take(from: read, to: total))
                read = total
                for cut in cuts { onPause(Double(cut) / 16_000) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
