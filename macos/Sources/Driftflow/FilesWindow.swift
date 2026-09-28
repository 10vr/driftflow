import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Queue

/// Transcribes dropped audio and video files one after another with the model chosen for dictation,
/// and keeps the finished transcripts in ~/Library/Application Support/Driftflow/transcripts.json.
@MainActor
final class FileTranscriber: ObservableObject {
    static let shared = FileTranscriber()

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var duration: Double?
        var processed: Double = 0
        var segments: [TranscriptSegment] = []
        var running = false
        var failure: String?
        var engine: String?

        var fraction: Double? {
            guard let duration, duration > 0 else { return nil }
            return min(1, processed / duration)
        }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var transcripts: [FileTranscript] = []
    /// Shown briefly when something dropped isn't audio or video.
    @Published var notice: String?

    private var worker: Task<Void, Never>?
    private var running: (id: UUID, task: Task<[TranscriptSegment], Error>)?
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "driftflow.transcripts", qos: .utility)

    /// Formats macOS can't decode itself but ffmpeg can.
    static let ffmpegExtensions: Set<String> = ["ogg", "oga", "opus", "webm", "mkv", "mka", "wma", "wmv", "avi",
                                                "flv", "spx", "ape", "wv", "ra", "rm", "amr", "3gp", "ts", "mts"]

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("transcripts.json")
        if let data = try? Data(contentsOf: fileURL) {
            if let saved = try? Self.decoder.decode([FileTranscript].self, from: data) {
                transcripts = saved
            } else {
                // Never overwrite transcripts we couldn't read; keep them aside instead.
                let aside = directory.appendingPathComponent("transcripts-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: fileURL, to: aside)
            }
        }
    }

    static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.conforms(to: .audiovisualContent) { return true }
        return ffmpegExtensions.contains(ext)
    }

    /// Where the text will come from, e.g. "Parakeet Unified · English".
    var engineLabel: String {
        let settings = AppSettings.shared
        let language = Locale.current.localizedString(forLanguageCode: settings.language) ?? settings.language
        let model = settings.accuracyModel != .apple && settings.accuracyModel.supports(language: settings.language)
            ? settings.accuracyModel.displayName : "Apple Speech"
        return "\(model) · \(language)"
    }

    /// Queues files (folders are searched for audio and video). Returns the first new job's id.
    @discardableResult
    func add(_ urls: [URL]) -> UUID? {
        var files: [URL] = []
        var skipped = 0
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL {
                    if Self.isMedia(file) { files.append(file) }
                }
            } else if Self.isMedia(url) {
                files.append(url)
            } else {
                skipped += 1
            }
        }
        notice = skipped > 0 ? "\(skipped) item\(skipped == 1 ? " isn't" : "s aren't") audio or video, so \(skipped == 1 ? "it was" : "they were") skipped." : nil
        let new = files.map { Job(url: $0) }
        jobs += new
        for job in new {
            Task {
                let duration = await AudioDecoder.duration(of: job.url)
                if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].duration = duration }
            }
        }
        startWorker()
        return new.first?.id
    }

    func cancel(_ id: UUID) {
        if running?.id == id { running?.task.cancel() }
        jobs.removeAll { $0.id == id }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].failure = nil
        jobs[index].processed = 0
        jobs[index].segments = []
        startWorker()
    }

    func delete(_ transcript: FileTranscript) {
        transcripts.removeAll { $0.id == transcript.id }
        save()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            while let job = jobs.first(where: { !$0.running && $0.failure == nil }) {
                await run(job)
            }
            worker = nil
        }
    }

    private func run(_ job: Job) async {
        update(job.id) { $0.running = true }
        let (engine, label) = await chooseEngine()
        guard jobs.contains(where: { $0.id == job.id }) else { return } // cancelled while the model loaded
        update(job.id) { $0.engine = label }
        let clock = ContinuousClock()
        let started = clock.now

        let task = Task { @MainActor in
            try await FileTranscription.run(job.url, engine: engine, beforeChunk: {
                // Dictation always comes first: pause between chunks while the user is talking.
                while DictationController.shared.phase != .idle { try await Task.sleep(for: .milliseconds(150)) }
            }, onProgress: { [weak self] progress in
                self?.update(job.id) {
                    $0.processed = progress.seconds
                    $0.segments = progress.segments
                }
            })
        }
        running = (job.id, task)
        defer { running = nil }

        do {
            // Your words' spellings and replacements apply to file transcripts too.
            let processor = AppSettings.shared.textProcessor
            let segments = try await task.value.map { segment in
                var segment = segment
                segment.text = TextProcessor(replacements: processor.replacements, vocabulary: processor.vocabulary)
                    .applyVocabularyAndReplacements(segment.text)
                return segment
            }
            let elapsed = clock.now - started
            guard jobs.contains(where: { $0.id == job.id }) else { return } // cancelled
            let duration = await AudioDecoder.duration(of: job.url)
                ?? jobs.first { $0.id == job.id }?.processed ?? segments.last?.end ?? 0
            guard jobs.contains(where: { $0.id == job.id }) else { return } // cancelled meanwhile
            let transcript = FileTranscript(
                id: job.id, fileName: job.url.lastPathComponent, path: job.url.path, created: Date(),
                duration: duration,
                processingSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                engine: label, segments: segments)
            withAnimation(.snappy) {
                jobs.removeAll { $0.id == job.id }
                transcripts.insert(transcript, at: 0)
            }
            save()
        } catch {
            guard jobs.contains(where: { $0.id == job.id }) else { return }
            update(job.id) {
                $0.running = false
                $0.failure = error is CancellationError ? "Cancelled" : error.localizedDescription
            }
        }
    }

    private func chooseEngine() async -> (FileTranscription.Engine, String) {
        let settings = AppSettings.shared
        let language = Locale.current.localizedString(forLanguageCode: settings.language) ?? settings.language
        let parakeet = DictationController.shared.parakeet
        if settings.accuracyModel != .apple, settings.accuracyModel.supports(language: settings.language) {
            // The model may still be loading right after launch.
            while await parakeet.isLoading { try? await Task.sleep(for: .milliseconds(200)) }
            if let model = await parakeet.model, model == settings.accuracyModel {
                return (.parakeet(parakeet, model), "\(model.displayName) · \(language)")
            }
        }
        return (.apple(settings.engineConfig), "Apple Speech · \(language)")
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    /// Waits for pending writes (at quit).
    func flush() { writeQueue.sync {} }

    private func save() {
        let snapshot = transcripts
        let url = fileURL
        writeQueue.async {
            guard let data = try? Self.encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Window

@MainActor
final class FilesWindow {
    static let shared = FilesWindow()
    private var window: NSWindow?
    private let selection = FilesSelection()

    func show(select id: UUID? = nil) {
        if let id { selection.id = id }
        if window == nil {
            let host = NSHostingController(rootView: FilesView(queue: .shared, selection: selection))
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.title = "Transcribe Files"
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 900, height: 600))
            window.setFrameAutosaveName("DriftflowFiles")
            if !window.setFrameUsingName("DriftflowFiles") { window.center() }
            self.window = window
            // The window is kept when closed, so stop any playback explicitly.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                NotificationCenter.default.post(name: TranscriptPlayer.stopAll, object: nil)
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Developer aid (`--snapshot <dir>`): renders the window in each state to PNGs, without
    /// needing Screen Recording permission.
    /// Renders any window's content to a PNG (developer aid).
    static func capture(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The onboarding window. (Settings forms draw through the window server and can't be captured this way.)
    func snapshotSettings(to directory: URL) async {
        let saved = UserDefaults.standard.integer(forKey: "onboardingStep")
        for step in 0...6 {
            DictationController.shared.resetOnboardingWindow()
            UserDefaults.standard.set(step, forKey: "onboardingStep")
            DictationController.shared.showOnboarding()
            try? await Task.sleep(for: .seconds(step == 3 ? 2.5 : 1.5))
            Self.capture(DictationController.shared.onboardingWindow, to: directory.appendingPathComponent("onboarding-\(step).png"))
        }
        DictationController.shared.resetOnboardingWindow()
        UserDefaults.standard.set(saved, forKey: "onboardingStep")

        // The Settings window, title bar included (to check the window buttons' placement).
        DictationController.shared.openSettings(.general)
        try? await Task.sleep(for: .seconds(2))
        let settings = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.title == "General" }
        Self.capture(settings, to: directory.appendingPathComponent("settings-general.png"))
        settings?.close()
    }

    func snapshot(to directory: URL) async {
        let states: [(String, UUID?)] = [("empty", UUID()), ("transcript", FileTranscriber.shared.transcripts.first?.id)]
        for (name, id) in states {
            show(select: id)
            try? await Task.sleep(for: .seconds(1.5))
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("files-\(name).png"))
        }
    }
}

final class FilesSelection: ObservableObject {
    @Published var id: UUID?
}

// MARK: - Views

private struct FilesView: View {
    @ObservedObject var queue: FileTranscriber
    @ObservedObject var selection: FilesSelection
    @ObservedObject private var settings = AppSettings.shared
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.id) {
                if !queue.jobs.isEmpty {
                    Section("In Progress") {
                        ForEach(queue.jobs) { job in
                            JobRow(job: job)
                                .tag(job.id)
                                .contextMenu { Button("Cancel") { queue.cancel(job.id) } }
                        }
                    }
                }
                if !queue.transcripts.isEmpty {
                    Section("Transcripts") {
                        ForEach(queue.transcripts) { transcript in
                            TranscriptRow(transcript: transcript)
                                .tag(transcript.id)
                                .contextMenu {
                                    Button("Copy Text") { TextInserter.shared.copy(transcript.text) }
                                    Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([transcript.url]) }
                                    Divider()
                                    Button("Delete Transcript", role: .destructive) { queue.delete(transcript) }
                                }
                        }
                    }
                }
            }
            .overlay {
                if queue.jobs.isEmpty && queue.transcripts.isEmpty {
                    Text("Transcripts appear here")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { importing = true } label: {
                    Label("Add Files…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            Group {
                if let job = queue.jobs.first(where: { $0.id == selection.id }) {
                    JobDetail(job: job, queue: queue)
                } else if let transcript = queue.transcripts.first(where: { $0.id == selection.id }) {
                    TranscriptDetail(transcript: transcript)
                        .id(transcript.id)
                } else {
                    DropZone(importing: $importing, engine: queue.engineLabel)
                }
            }
            .frame(minWidth: 460)
        }
        .navigationTitle("Transcribe Files")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Label("Add Files", systemImage: "plus") }
                    .help("Add audio or video files")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 16))
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .overlay(alignment: .bottom) {
            if let notice = queue.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(in: .capsule)
                    .padding(.bottom, 16)
                    .task(id: notice) { // a newer notice gets its own full 4 s
                        try? await Task.sleep(for: .seconds(4))
                        if queue.notice == notice { queue.notice = nil }
                    }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: allowedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    private var allowedTypes: [UTType] {
        [.audiovisualContent, .folder] + FileTranscriber.ffmpegExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    private func add(_ urls: [URL]) {
        if let id = queue.add(urls) { selection.id = id }
    }
}

private struct JobRow: View {
    let job: FileTranscriber.Job

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: job.fraction ?? 0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: job.fraction)
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(job.failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        if let failure = job.failure { return failure }
        guard job.running else { return "Waiting" }
        if let fraction = job.fraction { return "Transcribing… \(Int(fraction * 100))%" }
        return job.processed > 0 ? "Transcribing… \(FileTranscript.clock(job.processed))" : "Starting…"
    }
}

private struct TranscriptRow: View {
    let transcript: FileTranscript

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isVideo ? "film" : "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.fileName).lineLimit(1).truncationMode(.middle)
                Text("\(FileTranscript.clock(transcript.duration)) · \(transcript.created.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private var isVideo: Bool {
        UTType(filenameExtension: transcript.url.pathExtension)?.conforms(to: .movie) ?? false
    }
}

private struct DropZone: View {
    @Binding var importing: Bool
    let engine: String

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 46, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text("Drop audio or video files")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("MP3, M4A, WAV, AIFF, FLAC, CAF, MP4, MOV and more, or a whole folder.\nTranscribed on this Mac. Nothing is uploaded.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Choose Files…") { importing = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
            .padding(40)
            .frame(maxWidth: 520)
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .foregroundStyle(.quaternary)
            }
            Label(engine, systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
            if AudioDecoder.ffmpegPath == nil {
                Text("Ogg, WebM, MKV and WMA need ffmpeg (brew install ffmpeg).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct JobDetail: View {
    let job: FileTranscriber.Job
    let queue: FileTranscriber

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(job.url.lastPathComponent)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let failure = job.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Try Again") { queue.retry(job.id) }
                        Button("Remove") { queue.cancel(job.id) }
                    }
                } else {
                    if let fraction = job.fraction {
                        ProgressView(value: fraction).animation(.smooth, value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Button("Cancel") { queue.cancel(job.id) }
                    }
                }
            }
            .padding([.horizontal, .top], 24)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(job.segments) { segment in
                            SegmentLine(segment: segment, active: false) {}
                                .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .onChange(of: job.segments.count) {
                    if let last = job.segments.last { withAnimation(.smooth) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private var status: String {
        guard job.running else { return "Waiting for the file ahead of it…" }
        let engine = job.engine.map { " with \($0)" } ?? ""
        if let duration = job.duration {
            return "Transcribing\(engine) · \(FileTranscript.clock(job.processed)) of \(FileTranscript.clock(duration))"
        }
        return "Transcribing\(engine)…"
    }
}

private struct SegmentLine: View {
    let segment: TranscriptSegment
    let active: Bool
    let seek: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button(action: seek) {
                Text(FileTranscript.clock(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 52, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Play from here")
            Text(segment.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(active ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
        .animation(.easeOut(duration: 0.2), value: active)
    }
}

private struct TranscriptDetail: View {
    let transcript: FileTranscript
    @StateObject private var player = TranscriptPlayer()
    @State private var layout: Layout = .paragraphs
    @State private var copied = false

    enum Layout: String, CaseIterable {
        case paragraphs = "Paragraphs"
        case lines = "Timestamps"
    }

    /// Formats only ffmpeg can decode (Ogg, WebM, MKV…) can be transcribed but not played by macOS.
    private var canPlay: Bool {
        !FileTranscriber.ffmpegExtensions.contains(transcript.url.pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if transcript.segments.isEmpty {
                            Text("No speech was found in this file.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 60)
                        } else if layout == .paragraphs {
                            paragraphs
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(transcript.segments) { segment in
                                    SegmentLine(segment: segment, active: segment.id == activeID) { player.play(transcript.url, from: segment.start) }
                                        .id(segment.id)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .onChange(of: activeID) {
                    guard player.playing, let activeID else { return }
                    withAnimation(.smooth) { proxy.scrollTo(activeID, anchor: .center) }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcript.fileName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(details)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button { player.toggle(transcript.url) } label: {
                    Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!FileManager.default.fileExists(atPath: transcript.path) || !canPlay)
                .help(!FileManager.default.fileExists(atPath: transcript.path) ? "The original file was moved or deleted"
                      : canPlay ? "Play the original" : "macOS can't play this format (it was transcribed with ffmpeg)")
                Text("\(FileTranscript.clock(player.time)) / \(FileTranscript.clock(transcript.duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $layout) {
                    ForEach(Layout.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button {
                    TextInserter.shared.copy(transcript.text)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                Menu {
                    ForEach(FileTranscript.Format.allCases) { format in
                        Button(format.label) { export(format) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
            }
        }
        .padding(20)
    }

    private var details: String {
        let words = transcript.wordCount.formatted()
        let speed = transcript.speed >= 1 ? " (\(Int(transcript.speed.rounded()))× real time)" : ""
        let took = transcript.processingSeconds < 60
            ? String(format: "%.1f s", transcript.processingSeconds)
            : FileTranscript.clock(transcript.processingSeconds)
        return "\(FileTranscript.clock(transcript.duration)) · \(words) words · transcribed in \(took)\(speed) · \(transcript.engine)"
    }

    /// The segment under the playhead.
    private var activeID: UUID? {
        guard player.started else { return nil }
        return transcript.segments.last { $0.start <= player.time + 0.05 }?.id
    }

    private var paragraphs: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(FileTranscript.paragraphs(transcript.segments).enumerated()), id: \.offset) { _, paragraph in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Button { player.play(transcript.url, from: paragraph[0].start) } label: {
                        Text(FileTranscript.clock(paragraph[0].start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .help("Play from here")
                    Text(attributed(paragraph))
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(paragraph.first?.id)
            }
        }
    }

    /// The paragraph with the line being played highlighted.
    private func attributed(_ paragraph: [TranscriptSegment]) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in paragraph.enumerated() {
            var piece = AttributedString((index == 0 ? "" : " ") + segment.text)
            if segment.id == activeID {
                piece.backgroundColor = Color.accentColor.opacity(0.18)
            }
            result += piece
        }
        return result
    }

    private func export(_ format: FileTranscript.Format) {
        let panel = NSSavePanel()
        let base = (transcript.fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.directoryURL = transcript.url.deletingLastPathComponent()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? transcript.export(format).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Plays the original file so a transcript can be checked against it.
@MainActor
final class TranscriptPlayer: ObservableObject {
    static let stopAll = Notification.Name("DriftflowStopPlayback")
    @Published private(set) var time: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var started = false
    private var player: AVPlayer?
    private var observer: Any?
    private var stopObserver: Any?

    init() {
        stopObserver = NotificationCenter.default.addObserver(forName: Self.stopAll, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player?.pause()
                self?.playing = false
            }
        }
    }

    func toggle(_ url: URL) {
        if playing {
            player?.pause()
            playing = false
        } else {
            play(url, from: nil)
        }
    }

    func play(_ url: URL, from seconds: Double?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if player == nil {
            let player = AVPlayer(url: url)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.time = time.seconds
                    self.playing = (self.player?.rate ?? 0) > 0
                }
            }
            self.player = player
        }
        if let seconds {
            player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else if let item = player?.currentItem, item.duration.isNumeric, item.currentTime().seconds >= item.duration.seconds - 0.25 {
            player?.seek(to: .zero) // finished: Play starts over
        }
        player?.play()
        playing = true
        started = true
    }

    deinit {
        if let observer { player?.removeTimeObserver(observer) }
        if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
        player?.pause()
    }
}
