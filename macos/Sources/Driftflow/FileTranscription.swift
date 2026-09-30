@preconcurrency import AVFoundation
import FluidAudio
import Foundation

// MARK: - Transcript

struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

struct FileTranscript: Codable, Identifiable, Hashable {
    let id: UUID
    let fileName: String
    let path: String
    let created: Date
    /// Seconds of audio.
    let duration: Double
    /// Wall-clock seconds the transcription took.
    let processingSeconds: Double
    /// e.g. "Parakeet Unified · English"
    let engine: String
    var segments: [TranscriptSegment]

    var url: URL { URL(fileURLWithPath: path) }
    var wordCount: Int { segments.reduce(0) { $0 + $1.text.split(separator: " ").count } }
    var speed: Double { processingSeconds > 0 ? duration / processingSeconds : 0 }

    /// Readable prose: a new paragraph after a long pause, or once a paragraph gets long.
    var text: String { Self.paragraphs(segments).map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n\n") }

    static func paragraphs(_ segments: [TranscriptSegment]) -> [[TranscriptSegment]] {
        var result: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var length = 0
        for segment in segments {
            if let last = current.last {
                let pause = segment.start - last.end
                let sentenceDone = last.text.last.map { ".?!".contains($0) } ?? false
                if pause >= 1.6 || (length > 650 && sentenceDone) {
                    result.append(current)
                    current = []
                    length = 0
                }
            }
            current.append(segment)
            length += segment.text.count + 1
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Export

    enum Format: String, CaseIterable, Identifiable {
        case text, timestamped, srt, vtt

        var id: String { rawValue }

        var label: String {
            switch self {
            case .text: "Plain Text"
            case .timestamped: "Text with Timestamps"
            case .srt: "Subtitles (SRT)"
            case .vtt: "Web Subtitles (VTT)"
            }
        }

        var fileExtension: String {
            switch self {
            case .text, .timestamped: "txt"
            case .srt: "srt"
            case .vtt: "vtt"
            }
        }
    }

    func export(_ format: Format) -> String {
        switch format {
        case .text:
            return text + "\n"
        case .timestamped:
            return Self.paragraphs(segments).map { paragraph in
                "[\(Self.clock(paragraph[0].start))] " + paragraph.map(\.text).joined(separator: " ")
            }.joined(separator: "\n\n") + "\n"
        case .srt, .vtt:
            let cues = Self.cues(segments)
            let separator = format == .srt ? "," : "."
            let body = cues.enumerated().map { index, cue in
                let times = "\(Self.stamp(cue.start, separator)) --> \(Self.stamp(cue.end, separator))"
                return format == .srt ? "\(index + 1)\n\(times)\n\(cue.text)" : "\(times)\n\(cue.text)"
            }.joined(separator: "\n\n")
            return (format == .vtt ? "WEBVTT\n\n" : "") + body + "\n"
        }
    }

    /// Subtitle cues stay on screen a little after the last word (up to the next cue), at least 1 s.
    static func cues(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.enumerated().map { index, segment in
            var cue = segment
            let next = index + 1 < segments.count ? segments[index + 1].start : .infinity
            cue.end = min(max(segment.end + 0.6, segment.start + 1), next)
            cue.end = max(cue.end, cue.start + 0.2)
            return cue
        }
    }

    /// "1:05" or "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "00:01:05,250"
    static func stamp(_ seconds: Double, _ separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
}

// MARK: - Segmenting

enum TranscriptBuilder {
    /// Groups words into subtitle-sized lines: split at pauses and sentence ends, and before a line
    /// gets too long to read (about 84 characters or 6.5 seconds).
    static func segments(from words: [WordTiming]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: [WordTiming] = []
        var characters = 0

        func close() {
            guard let first = current.first, let last = current.last else { return }
            let text = NumberStyle.apply(current.map(\.word).joined(separator: " "))
            result.append(TranscriptSegment(start: first.startTime, end: last.endTime, text: text))
            current = []
            characters = 0
        }

        for (index, word) in words.enumerated() {
            current.append(word)
            characters += word.word.count + 1
            let next = index + 1 < words.count ? words[index + 1] : nil
            let pause = next.map { $0.startTime - word.endTime } ?? .infinity
            let duration = word.endTime - current[0].startTime
            let last = word.word.last
            let sentenceEnd = last.map { ".?!".contains($0) } ?? false
            let clauseEnd = last.map { ",;:".contains($0) } ?? false
            if pause >= 0.7
                || (sentenceEnd && (duration >= 1.2 || pause >= 0.3))
                || (clauseEnd && characters >= 50)
                || characters >= 84 || duration >= 6.5 {
                close()
            }
        }
        close()
        return result
    }
}

// MARK: - Decoding

/// Reads any audio or video file macOS can decode (MP3, M4A/AAC, ALAC, WAV, AIFF, FLAC, CAF, Opus
/// in CAF, AC-3, AMR, MP4, MOV, M4V, 3GP…) as 16 kHz mono, a block at a time so hour-long files
/// don't have to fit in memory. Formats Apple can't open (Ogg, WebM, MKV, WMA…) go through ffmpeg
/// when it's installed.
enum AudioDecoder {
    enum DecodeError: LocalizedError {
        case noAudio
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: "This file has no audio track."
            case .unsupported(let ext):
                "macOS can't decode .\(ext) files. Install ffmpeg (brew install ffmpeg) to open them, or convert the file to MP3, M4A or WAV."
            }
        }
    }

    static let sampleRate = 16_000.0

    /// Length in seconds, or nil if unknown.
    static func duration(of url: URL) async -> Double? {
        if let file = try? AVAudioFile(forReading: url), file.length > 0 {
            return Double(file.length) / file.fileFormat.sampleRate
        }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0
        else { return nil }
        return duration.seconds
    }

    /// Opens `url` for reading 16 kHz mono blocks, via AVFoundation or, failing that, ffmpeg.
    static func open(_ url: URL) async throws -> AudioBlockReader {
        // DRIFTFLOW_ASSET_READER=1 skips the audio-file reader, to test the video path with any file.
        if ProcessInfo.processInfo.environment["DRIFTFLOW_ASSET_READER"] != "1", let reader = AudioFileBlockReader(url) { return reader }
        if let reader = try await AssetBlockReader.open(url) { return reader }
        guard let ffmpeg = ffmpegPath else { throw DecodeError.unsupported(url.pathExtension.lowercased()) }
        return try FFmpegBlockReader(ffmpeg: ffmpeg, url: url)
    }

    /// Whether macOS reads Ogg files (Opus, FLAC, Vorbis) itself: new in macOS 26, and what
    /// WhatsApp voice notes are. Earlier versions need ffmpeg for them.
    static var readsOgg: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var ffmpegPath: String? {
        let candidates = [ProcessInfo.processInfo.environment["DRIFTFLOW_FFMPEG"],
                          "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Pull-based, so decoding never runs ahead of the model: memory stays at one block (~10 s of
/// audio) however long the file is.
class AudioBlockReader: @unchecked Sendable {
    static let blockSamples = 16_000 * 10

    /// The next block of up to 10 s, or nil at the end. Blocking; call off the main actor.
    func next() throws -> [Float]? { nil }
    func close() {}

    /// `next()` on a background thread.
    func nextBlock() async throws -> [Float]? {
        try await Task.detached(priority: .userInitiated) { try self.next() }.value
    }
}

/// Averages all channels to mono (5.1 and multi-track recordings often carry no channel layout
/// the converter could use), then resamples to 16 kHz.
private final class MonoResampler {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioDecoder.sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    /// `buffer` must be 32-bit float, interleaved or not.
    func append(_ buffer: AVAudioPCMBuffer, to block: inout [Float]) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return }
        guard let mono = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                                                   channels: 1, interleaved: false)!,
                                          frameCapacity: AVAudioFrameCount(frames)) else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        let out = mono.floatChannelData![0]
        let scale = 1 / Float(channels)
        if buffer.format.isInterleaved {
            let samples = data[0]
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[i * channels + c] }
                out[i] = sum * scale
            }
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                out[i] = sum * scale
            }
        }
        if mono.format.sampleRate == target.sampleRate {
            block.append(contentsOf: UnsafeBufferPointer(start: out, count: frames))
            return
        }
        if converter == nil || converter?.inputFormat.sampleRate != mono.format.sampleRate {
            converter = AVAudioConverter(from: mono.format, to: target)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        convert(mono, into: &block)
    }

    /// Drains what the resampler still holds at the end of the file.
    func finish(into block: inout [Float]) {
        convert(nil, into: &block)
    }

    private func convert(_ input: AVAudioPCMBuffer?, into block: inout [Float]) {
        guard let converter else { return }
        let frames = Double(input?.frameLength ?? 0)
        let capacity = AVAudioFrameCount(frames * target.sampleRate / converter.inputFormat.sampleRate) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        let status = converter.convert(to: out, error: nil) { _, inputStatus in
            guard let input, !supplied else {
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        block.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}

/// Audio files (WAV, AIFF, CAF, M4A, MP3, FLAC, Opus in CAF…) through ExtAudioFile: plain file
/// decoding that never talks to the system audio server.
private final class AudioFileBlockReader: AudioBlockReader, @unchecked Sendable {
    private let file: AVAudioFile
    private let resampler = MonoResampler()
    private var ended = false

    init?(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 0 else { return nil }
        self.file = file
    }

    override func next() throws -> [Float]? {
        guard !ended else { return nil }
        var block: [Float] = []
        block.reserveCapacity(Self.blockSamples + 16_000)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate)
        while block.count < Self.blockSamples {
            // Reading at the end throws rather than returning 0 frames.
            let remaining = file.length - file.framePosition
            guard remaining > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
                ended = true
                resampler.finish(into: &block)
                break
            }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunk), remaining)))
            guard buffer.frameLength > 0 else { // a truncated file can claim more frames than it has
                ended = true
                resampler.finish(into: &block)
                break
            }
            resampler.append(buffer, to: &block)
        }
        return block.isEmpty ? nil : block
    }
}

/// Video and other containers (MP4, MOV, M4V, 3GP…): the first audio track decoded to float PCM.
/// (AVAssetReaderAudioMixOutput could also resample, but it goes through the system audio server
/// and was measured stalling for ~90 s while that was busy.)
private final class AssetBlockReader: AudioBlockReader, @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let url: URL
    private let resampler = MonoResampler()
    private var ended = false

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, url: URL) {
        self.reader = reader
        self.output = output
        self.url = url
    }

    /// nil if AVFoundation can't open the file at all.
    static func open(_ url: URL) async throws -> AssetBlockReader? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return nil }
        guard let track = tracks.first else {
            // A readable container without audio, e.g. a silent screen recording.
            if let video = try? await asset.loadTracks(withMediaType: .video), !video.isEmpty {
                throw AudioDecoder.DecodeError.noAudio
            }
            return nil
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        return AssetBlockReader(reader: reader, output: output, url: url)
    }

    override func next() throws -> [Float]? {
        guard !ended else { return nil }
        var block: [Float] = []
        block.reserveCapacity(Self.blockSamples + 16_000)
        while block.count < Self.blockSamples {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    throw reader.error ?? AudioDecoder.DecodeError.unsupported(url.pathExtension.lowercased())
                }
                ended = true
                resampler.finish(into: &block)
                break
            }
            if let buffer = Self.pcmBuffer(from: sample) { resampler.append(buffer, to: &block) }
        }
        return block.isEmpty ? nil : block
    }

    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let format = format(of: description) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// The PCM format, including its channel layout: AVAudioFormat refuses more than two channels
    /// without one (5.1 video, 4-channel camera audio), and our downmix then gets nothing.
    private static func format(of description: CMAudioFormatDescription) -> AVAudioFormat? {
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        if format.channelCount <= 2 || format.channelLayout != nil { return format }
        guard var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame)
        else { return nil }
        return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
    }

    override func close() {
        if reader.status == .reading { reader.cancelReading() }
    }
}

private final class FFmpegBlockReader: AudioBlockReader, @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let url: URL
    private var pending = Data()
    private var finished = false

    init(ffmpeg: String, url: URL) throws {
        self.url = url
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-v", "error", "-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "f32le", "-"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    override func next() throws -> [Float]? {
        let blockBytes = Self.blockSamples * MemoryLayout<Float>.size
        while !finished, pending.count < blockBytes {
            if let chunk = try pipe.fileHandleForReading.read(upToCount: 256 * 1024), !chunk.isEmpty {
                pending.append(chunk)
            } else {
                finished = true
                process.waitUntilExit()
                if process.terminationStatus != 0, pending.isEmpty {
                    throw AudioDecoder.DecodeError.unsupported(url.pathExtension.lowercased())
                }
            }
        }
        let usable = min(pending.count, blockBytes) / MemoryLayout<Float>.size * MemoryLayout<Float>.size
        guard usable > 0 else { return nil }
        let floats = pending.prefix(usable).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        pending = Data(pending.dropFirst(usable))
        return floats
    }

    override func close() {
        if process.isRunning { process.terminate() }
    }
}

// MARK: - Transcribing

enum FileTranscription {
    struct Progress: Sendable {
        /// Seconds of audio processed so far.
        var seconds: Double
        /// Segments finished so far, in order.
        var segments: [TranscriptSegment]
    }

    enum Engine {
        case parakeet(ParakeetEngine, AccuracyModel)
        case apple(SpeechConfig)
    }

    /// Transcribes `url` in pause-aligned chunks of about 30 s: the model's attention window is
    /// 15 s anyway, cutting at the quietest moment keeps words whole, and each chunk takes only a
    /// fraction of a second so progress (and live dictation) never waits long.
    ///
    /// `helpers` can supply more copies of the same Parakeet model: they transcribe other chunks
    /// at the same time (it's called once the first copy is already working).
    @MainActor
    static func run(_ url: URL, engine: Engine, helpers: @escaping () async -> [ParakeetEngine] = { [] },
                    beforeChunk: @escaping () async throws -> Void = {},
                    onProgress: @escaping (Progress) -> Void) async throws -> [TranscriptSegment] {
        switch engine {
        case .parakeet(let parakeet, let model):
            // Unified emits a word ~0.38 s after it starts; TDT (v2/v3) ~0.18 s before (medians
            // against speech onsets over 90 recordings). Shifting Unified 0.3 s earlier puts both
            // on the word, a touch early rather than late.
            let lag = model == .parakeetUnified ? 0.3 : 0
            return try await runParakeet(url, parakeet, lag: lag, helpers: helpers, beforeChunk: beforeChunk, onProgress: onProgress)
        case .apple(let config):
            guard #available(macOS 26.0, *), !SpeechEngine.disabledForTesting else {
                struct Unavailable: LocalizedError {
                    var errorDescription: String? { "This needs Apple's speech model, which comes with macOS 26. On this Mac, pick a Parakeet model and a language it supports in Settings › Models." }
                }
                throw Unavailable()
            }
            return try await runApple(url, config, onProgress: onProgress)
        }
    }

    private static let chunkSamples = 30 * 16_000
    private static let searchSamples = 8 * 16_000

    /// Chunks cut from the file, waiting for (or done by) the model copies.
    @MainActor
    private final class ChunkQueue {
        var starts: [Int] = []
        var ends: [Int] = []
        var pieces: [[Float]] = []
        var words: [[WordTiming]?] = []
        var taken = 0
        var allCut = false
        /// Chunks finished from the start with no gaps (what progress shows).
        var reported = 0

        /// The next chunk to transcribe, or nil when the file is done.
        func take() async throws -> Int? {
            while true {
                try Task.checkCancellation()
                if taken < pieces.count {
                    taken += 1
                    return taken - 1
                }
                if allCut { return nil }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @MainActor
    private static func runParakeet(_ url: URL, _ parakeet: ParakeetEngine, lag: Double, helpers: @escaping () async -> [ParakeetEngine],
                                    beforeChunk: @escaping () async throws -> Void,
                                    onProgress: @escaping (Progress) -> Void) async throws -> [TranscriptSegment] {
        let model = await parakeet.model
        let queue = ChunkQueue()

        struct ModelChanged: LocalizedError {
            var errorDescription: String? { "The speech model was changed during transcription. Transcribe the file again to use the new one." }
        }

        // Decoding is ~20× faster than transcribing: cut chunks ahead, a few at a time.
        @MainActor func cutChunks() async throws {
            let reader = try await AudioDecoder.open(url)
            defer { reader.close() }
            var pending: [Float] = []
            var offset = 0
            func add(_ piece: [Float]) async throws {
                while queue.pieces.count - queue.taken >= 6 { try await Task.sleep(for: .milliseconds(5)) }
                queue.starts.append(offset)
                queue.ends.append(offset + piece.count)
                queue.pieces.append(piece)
                queue.words.append(nil)
                offset += piece.count
            }
            while let block = try await reader.nextBlock() {
                try Task.checkCancellation()
                pending += block
                while pending.count >= chunkSamples {
                    let cut = quietestPoint(pending, from: chunkSamples - searchSamples, to: chunkSamples)
                    let piece = Array(pending[..<cut])
                    pending.removeFirst(cut)
                    try await add(piece)
                }
            }
            if !pending.isEmpty { try await add(pending) }
            queue.allCut = true
        }

        @MainActor func transcribeChunks(with engine: ParakeetEngine) async throws {
            while let index = try await queue.take() {
                try await beforeChunk()
                let samples = queue.pieces[index]
                queue.pieces[index] = [] // done with the audio
                // Every chunk must come from the same model (its timing and label are the job's).
                guard await engine.model == model, let chunkWords = try await engine.transcribeWords(samples),
                      await engine.model == model else {
                    throw ModelChanged()
                }
                let start = Double(queue.starts[index]) / AudioDecoder.sampleRate
                queue.words[index] = chunkWords.map {
                    WordTiming(word: $0.word, startTime: max(0, $0.startTime + start - lag), endTime: max(0, $0.endTime + start - lag))
                }
                let before = queue.reported
                while queue.reported < queue.words.count, queue.words[queue.reported] != nil { queue.reported += 1 }
                if queue.reported > before {
                    let words = queue.words[..<queue.reported].flatMap { $0 ?? [] }
                    onProgress(Progress(seconds: Double(queue.ends[queue.reported - 1]) / AudioDecoder.sampleRate,
                                        segments: TranscriptBuilder.segments(from: words)))
                }
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in try await cutChunks() }
            group.addTask { @MainActor in try await transcribeChunks(with: parakeet) }
            // Copies of the model work side by side (their steps overlap on the Neural Engine and
            // CPU): see FileTranscriber.helperCount for how many pay off.
            for helper in await helpers() {
                group.addTask { @MainActor in try await transcribeChunks(with: helper) }
            }
            try await group.waitForAll()
        }
        return TranscriptBuilder.segments(from: queue.words.flatMap { $0 ?? [] })
    }

    /// Loudness every 10 ms (RMS), for `tighten`. 16 kHz input; any tail shorter than 10 ms is dropped.
    static func envelope(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count - 159, by: 160).map { start in
            var sum: Float = 0
            for i in start..<(start + 160) { sum += samples[i] * samples[i] }
            return (sum / 160).squareRoot()
        }
    }

    /// Apple's word ranges run back to back, so each word's range swallows the pause before it and
    /// subtitles would start early and never break at pauses. Trims every word to the part of its
    /// range that's actually louder than the recording's background.
    static func tighten(_ words: [WordTiming], envelope: [Float]) -> [WordTiming] {
        guard envelope.count > 100 else { return words }
        let decibels = envelope.map { 20 * log10(max($0, 1e-6)) }
        let sorted = decibels.sorted()
        let background = sorted[sorted.count * 15 / 100], loud = sorted[sorted.count * 95 / 100]
        let threshold = background + max(6, 0.3 * (loud - background))
        let frame = 0.01
        return words.map { word in
            let lower = max(0, Int(word.startTime / frame))
            let upper = min(decibels.count, Int((word.endTime / frame).rounded(.up)))
            guard lower < upper,
                  let first = (lower..<upper).first(where: { decibels[$0] > threshold }),
                  let last = (lower..<upper).last(where: { decibels[$0] > threshold })
            else { return word }
            return WordTiming(word: word.word, startTime: Double(first) * frame, endTime: Double(last + 1) * frame)
        }
    }

    /// Words with times from an Apple result: each attributed run carries the audio it came from;
    /// runs without a time (spaces, punctuation) attach to the word before them.
    @available(macOS 26.0, *)
    static func words(in text: AttributedString) -> [WordTiming] {
        var words: [WordTiming] = []
        var current = ""
        var start = 0.0, end = 0.0
        func flush() {
            let word = current.trimmingCharacters(in: .whitespaces)
            if !word.isEmpty { words.append(WordTiming(word: word, startTime: start, endTime: end)) }
            current = ""
        }
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let range = run.audioTimeRange
            for (index, part) in piece.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                if index > 0 || (piece.first == " " && !current.isEmpty) { flush() }
                if part.isEmpty { continue }
                if current.isEmpty, let range, range.start.isNumeric {
                    start = range.start.seconds
                }
                current += part
                if let range, range.end.isNumeric { end = range.end.seconds }
            }
        }
        flush()
        return words
    }

    /// The middle of the quietest 200 ms in `lower..<upper`: a pause between words, if there is one.
    static func quietestPoint(_ samples: [Float], from lower: Int, to upper: Int) -> Int {
        let frame = 320 // 20 ms
        let window = 10 // frames = 200 ms
        let first = max(0, lower / frame), last = min(samples.count, upper) / frame
        guard last - first > window else { return min(samples.count, upper) }
        var energy = [Float](repeating: 0, count: last - first)
        for index in 0..<energy.count {
            let base = (first + index) * frame
            var sum: Float = 0
            for i in base..<(base + frame) { sum += samples[i] * samples[i] }
            energy[index] = sum
        }
        var running = energy[0..<window].reduce(0, +)
        var best = running, bestIndex = 0
        for index in window..<energy.count {
            running += energy[index] - energy[index - window]
            if running < best {
                best = running
                bestIndex = index - window + 1
            }
        }
        return (first + bestIndex + window / 2) * frame
    }

    @available(macOS 26.0, *)
    @MainActor
    private static func runApple(_ url: URL, _ config: SpeechConfig,
                                 onProgress: @escaping (Progress) -> Void) async throws -> [TranscriptSegment] {
        let engine = SpeechEngine()
        let prepared = try await engine.prepare(config, timestamps: true)
        let session = DictationSession(prepared: prepared, recordsSamples: false) { _, _ in }
        var words: [WordTiming] = []
        var envelope: [Float] = []
        var leftover: [Float] = [] // samples short of a whole 10 ms frame, carried to the next block
        session.onFinalResult = { text in
            words += Self.words(in: text)
            onProgress(Progress(seconds: words.last?.endTime ?? 0, segments: TranscriptBuilder.segments(from: words)))
        }
        try await session.start()
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioDecoder.sampleRate, channels: 1, interleaved: false)!
            let reader = try await AudioDecoder.open(url)
            defer { reader.close() }
            while let block = try await reader.nextBlock() {
                try Task.checkCancellation()
                // Frames must line up across blocks, or the envelope drifts from real time.
                let joined = leftover + block
                let whole = joined.count - joined.count % 160
                envelope += Self.envelope(Array(joined[..<whole]))
                leftover = Array(joined[whole...])
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.count)) else { continue }
                buffer.frameLength = AVAudioFrameCount(block.count)
                block.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: block.count) }
                session.feed(buffer)
            }
            _ = try await session.finish()
        } catch {
            await session.cancel()
            throw error
        }
        return TranscriptBuilder.segments(from: tighten(words, envelope: envelope))
    }
}
