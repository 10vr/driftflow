import AppKit
import CryptoKit
import Foundation
import llama
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The language model behind AI Styles and editing by voice. The local models run on this Mac's GPU
/// with llama.cpp; Apple's is the one built into macOS 26.
enum TextModel: String, CaseIterable, Identifiable {
    case qwen = "qwen3.5-4b"
    case gemma = "gemma4-e2b"
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen: "Qwen 3.5 4B"
        case .gemma: "Gemma 4 E2B"
        case .apple: "Apple Intelligence"
        }
    }

    var badge: String {
        switch self {
        case .qwen: "Recommended"
        case .gemma: "Fastest"
        case .apple: "Built in"
        }
    }

    var summary: String {
        switch self {
        case .qwen: "The most careful: keeps your meaning, applies your corrections (“ten, no, ten thirty”), keeps other languages as they are and follows edits closely. Alibaba, 4 billion parameters."
        case .gemma: "About twice as fast as Qwen. A little less careful: it sometimes leaves a correction in or translates instead of tidying. Google, 2 billion effective parameters."
        case .apple: "No download. Needs macOS 26 with Apple Intelligence. Fine for short sentences; with long dictations it sometimes turns them into an email, and it can't read long texts."
        }
    }

    // Measured on an M5 MacBook with the same 45 dictations (15 sentences × 3 styles) and 16 voice
    // edits for every model (main.swift --ai-compare). A rewrite counts when it passes the safety
    // check and says what was dictated; an edit when it does what was asked.
    var rewritesKept: Int {
        switch self {
        case .qwen: 42
        case .gemma: 39
        case .apple: 39
        }
    }

    var editsRight: Int {
        switch self {
        case .qwen: 15
        case .gemma: 15
        case .apple: 13
        }
    }

    static let rewriteTests = 45
    static let editTests = 16

    /// Typical time for a one-sentence dictation, key release → rewritten text (M5).
    var typicalSeconds: Double {
        switch self {
        case .qwen: 0.6
        case .gemma: 0.36
        case .apple: 0.45
        }
    }

    var downloadSize: String {
        switch self {
        case .qwen: "2.7 GB"
        case .gemma: "3.3 GB"
        case .apple: "No download"
        }
    }

    /// While loaded: only when you use it, and freed after a few idle minutes.
    var memory: String {
        switch self {
        case .qwen: "3 GB memory while working"
        case .gemma: "3.5 GB memory while working"
        case .apple: "Managed by macOS"
        }
    }

    var needsDownload: Bool { self != .apple }

    /// The file on Hugging Face, pinned to a revision and checked by its SHA-256.
    struct File {
        let repo: String
        let revision: String
        let name: String
        let bytes: Int64
        let sha256: String

        var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(name)")! }
    }

    var file: File? {
        switch self {
        case .qwen: File(repo: "unsloth/Qwen3.5-4B-GGUF", revision: "e87f176479d0855a907a41277aca2f8ee7a09523",
                         name: "Qwen3.5-4B-Q4_K_M.gguf", bytes: 2_740_937_888,
                         sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4")
        case .gemma: File(repo: "google/gemma-4-E2B-it-qat-q4_0-gguf", revision: "675cff42a74c774d6cb76f76d8eacb49b48c9b93",
                          name: "gemma-4-E2B_q4_0-it.gguf", bytes: 3_349_516_256,
                          sha256: "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634")
        case .apple: nil
        }
    }

    /// How a conversation is written out for the model (each was trained on its own format).
    enum Format { case chatML, gemma }

    var format: Format { self == .gemma ? .gemma : .chatML }

    /// Below this much memory a 3 GB model makes the whole Mac swap, so Apple's model is suggested first.
    static let comfortableMemory: UInt64 = 12 << 30

    static var hasComfortableMemory: Bool { ProcessInfo.processInfo.physicalMemory >= comfortableMemory }

    /// What a new install starts with: Qwen, or Apple's model on a Mac with 8 GB that has it.
    static var recommended: TextModel {
        hasComfortableMemory || !appleModelUsable ? .qwen : .apple
    }

    /// Apple's model is on and ready on this Mac.
    static var appleModelUsable: Bool {
        if ProcessInfo.processInfo.environment["DRIFTFLOW_NO_AI"] == "1" { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }
}

// MARK: - Downloads

/// Which local models are on disk; downloads, verifies and deletes them.
///
/// Shared with Driftline (the call recorder), by a convention both apps follow (macos/README.md ›
/// Models shared with Driftline). One copy of each model sits in a folder that belongs to neither app,
/// and both read it in place: macOS then holds it in memory once even when both apps use it at the same
/// time, each adding only its own working memory (about 0.3 GB). A copy or an APFS clone would be a
/// different file to macOS and be loaded twice. Whichever app needs a model first downloads it while
/// holding `<file>.lock`; the other app waits for that download instead of starting its own. Each app
/// marks the models it uses (`<file>.used-by-driftflow`), so deleting one in one app doesn't take it
/// from the other.
@MainActor
final class TextModelManager: ObservableObject {
    static let shared = TextModelManager()

    @Published private(set) var status: [TextModel: ModelManager.Status] = [:]
    /// Posted with the model when a download finishes (here or in the other app, while this one waited).
    static let downloaded = Notification.Name("TextModelDownloaded")
    /// Models the other app is downloading right now (this one waits for it to finish).
    @Published private(set) var downloadingElsewhere: Set<TextModel> = []

    private var downloads: [TextModel: FileDownload] = [:]
    private var locks: [TextModel: DownloadLock] = [:]
    private var waits: [TextModel: Task<Void, Never>] = [:]

    private init() {
        Self.moveFromOldFolders()
        refresh()
    }

    nonisolated static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["DRIFTFLOW_LANGUAGE_MODELS"] { // tests
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent("Drift/Language Models", isDirectory: true)
    }

    nonisolated private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    nonisolated static func fileURL(for model: TextModel) -> URL? {
        model.file.map { folder.appendingPathComponent($0.name) }
    }

    nonisolated private static func sidecar(_ model: TextModel, _ suffix: String) -> URL? {
        model.file.map { folder.appendingPathComponent($0.name + suffix) }
    }

    // MARK: Which app uses what

    /// The apps that share these models, by the name in their marker files.
    nonisolated private static let apps = ["driftflow": "dev.driftflow.app", "driftline": "dev.driftline.app"]
    nonisolated private static let me = "driftflow"
    nonisolated private static let other = "driftline"

    /// The other app's name, if it's installed.
    static var otherApp: String? { isInstalled(other) ? "Driftline" : nil }

    private static func isInstalled(_ app: String) -> Bool {
        apps[app].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } != nil
    }

    /// Notes that Driftflow uses `model` (when it downloads or loads it).
    nonisolated static func markUsed(_ model: TextModel) {
        guard let marker = sidecar(model, ".used-by-\(me)"), !FileManager.default.fileExists(atPath: marker.path) else { return }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    /// Driftline uses `model` too. A marker left by an app that's no longer installed doesn't count, and is removed.
    func usedByOtherApp(_ model: TextModel) -> Bool {
        guard let marker = Self.sidecar(model, ".used-by-\(Self.other)"), FileManager.default.fileExists(atPath: marker.path) else { return false }
        if Self.isInstalled(Self.other) { return true }
        try? FileManager.default.removeItem(at: marker)
        return false
    }

    func usedHere(_ model: TextModel) -> Bool {
        Self.sidecar(model, ".used-by-\(Self.me)").map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    // MARK: State

    func status(of model: TextModel) -> ModelManager.Status {
        model.needsDownload ? status[model] ?? .notDownloaded : .downloaded
    }

    func isDownloaded(_ model: TextModel) -> Bool { status(of: model) == .downloaded }

    /// Re-checks the files (the other app may have downloaded or deleted one).
    func refresh() {
        for model in TextModel.allCases where model.needsDownload {
            if case .downloading = status[model] { continue }
            status[model] = Self.isComplete(model) ? .downloaded : .notDownloaded
        }
    }

    /// A finished copy: the exact size. The checksum is checked once, by whichever app downloads it,
    /// before the file gets its final name.
    nonisolated static func isComplete(_ model: TextModel) -> Bool {
        guard let file = model.file, let url = fileURL(for: model),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(size) == file.bytes
    }

    /// Moves a model downloaded before the apps shared them (Driftflow 0.2.23 kept them in its own
    /// folder) into the shared folder: a rename on the same disk, so it's instant, and a running app
    /// keeps working. From the other app's old folder only a complete file is moved, only when the
    /// shared folder lacks it, and only when that app isn't installed (an older copy of it would look for
    /// the file there); nothing else there is touched.
    private static func moveFromOldFolders() {
        guard ProcessInfo.processInfo.environment["DRIFTFLOW_LANGUAGE_MODELS"] == nil else { return }
        let manager = FileManager.default
        let mine = applicationSupport.appendingPathComponent("Driftflow/Language Models", isDirectory: true)
        let theirs = applicationSupport.appendingPathComponent("Driftline/Models/Language Models", isDirectory: true)
        let folders = isInstalled(other) ? [(mine, true)] : [(mine, true), (theirs, false)]
        for model in TextModel.allCases {
            guard let file = model.file, let target = fileURL(for: model) else { continue }
            for (folder, own) in folders {
                let old = folder.appendingPathComponent(file.name)
                guard let size = try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
                if isComplete(model) {
                    if own { try? manager.removeItem(at: old); markUsed(model) }
                } else if Int64(size) == file.bytes {
                    try? manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                    try? manager.removeItem(at: target)
                    if (try? manager.moveItem(at: old, to: target)) != nil {
                        AppLog.info("\(model.displayName): moved into the shared models folder")
                        if own { markUsed(model) }
                    }
                }
            }
        }
        if (try? manager.contentsOfDirectory(atPath: mine.path))?.isEmpty == true { try? manager.removeItem(at: mine) }
    }

    // MARK: Downloading

    func download(_ model: TextModel) {
        guard let file = model.file, let lockURL = Self.sidecar(model, ".lock"), let partial = Self.sidecar(model, ".download"),
              downloads[model] == nil, waits[model] == nil else { return }
        guard !Self.isComplete(model) else {
            Self.markUsed(model)
            status[model] = .downloaded
            return
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        switch DownloadLock.acquire(lockURL) {
        case .busy:
            waitForOtherApp(model, lock: lockURL)
            return
        case .acquired(let lock):
            locks[model] = lock
        case .unavailable:
            break // can't lock (unusual permissions): download anyway
        }
        try? FileManager.default.removeItem(at: partial) // only the lock holder writes it: a leftover
        status[model] = .downloading(0)
        AppLog.info("\(model.displayName): downloading \(file.name)")
        let download = FileDownload(url: file.url, keepAt: partial) { [weak self] written, total in
            Task { @MainActor in
                guard let self, self.downloads[model] != nil else { return }
                self.locks[model]?.write("\(written) \(total)\n") // for the other app's progress bar
                self.status[model] = .downloading(Double(written) / Double(max(total, 1)))
            }
        } completion: { [weak self] result in
            Task { @MainActor in await self?.finish(model, result) }
        }
        downloads[model] = download
        download.start()
    }

    /// The other app is downloading `model`: show its progress and use its file, instead of
    /// downloading it twice. If it stops without finishing (cancelled, or quit), download it here.
    private func waitForOtherApp(_ model: TextModel, lock: URL) {
        AppLog.info("\(model.displayName): the other app is downloading it; waiting for that")
        status[model] = .downloading(0)
        downloadingElsewhere.insert(model)
        waits[model] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let complete = Self.isComplete(model)
                var stopped = false
                if !complete, case .acquired = DownloadLock.acquire(lock) { stopped = true } // released at once
                guard complete || stopped else {
                    if let progress = DownloadLock.progress(lock) { self.status[model] = .downloading(progress) }
                    continue
                }
                self.waits[model] = nil
                self.downloadingElsewhere.remove(model)
                if complete {
                    AppLog.info("\(model.displayName): the other app finished downloading it")
                    Self.markUsed(model)
                    self.status[model] = .downloaded
                    NotificationCenter.default.post(name: Self.downloaded, object: model)
                } else {
                    self.status[model] = .notDownloaded
                    self.download(model)
                }
                return
            }
        }
    }

    private func finish(_ model: TextModel, _ result: Result<URL, Error>) async {
        guard downloads[model] != nil, let file = model.file, let target = Self.fileURL(for: model) else { return }
        defer {
            downloads[model] = nil
            locks[model] = nil // releases the lock: the other app sees the file, or may download it itself
        }
        switch result {
        case .failure(let error):
            AppLog.error("\(model.displayName): download failed: \(error.localizedDescription)")
            status[model] = .failed(error.localizedDescription)
        case .success(let partial):
            status[model] = .downloading(1)
            let verified = await Task.detached(priority: .utility) { () -> Bool in
                guard (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.bytes else { return false }
                return Self.sha256(of: partial) == file.sha256
            }.value
            guard verified else {
                try? FileManager.default.removeItem(at: partial)
                AppLog.error("\(model.displayName): downloaded file didn't match its checksum")
                status[model] = .failed("The download was damaged. Try again.")
                return
            }
            do {
                // Readable by the other app, and given its final name only now, in one step, so neither
                // app ever sees half a model.
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: partial.path)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: partial, to: target)
                Self.markUsed(model)
                AppLog.info("\(model.displayName): downloaded and verified")
                status[model] = .downloaded
                NotificationCenter.default.post(name: Self.downloaded, object: model)
            } catch {
                status[model] = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload(_ model: TextModel) {
        if let wait = waits[model] {
            wait.cancel()
            waits[model] = nil
            downloadingElsewhere.remove(model)
        }
        downloads[model]?.cancel()
        downloads[model] = nil
        if locks[model] != nil, let partial = Self.sidecar(model, ".download") { try? FileManager.default.removeItem(at: partial) }
        locks[model] = nil
        status[model] = Self.isComplete(model) ? .downloaded : .notDownloaded
    }

    /// Stops Driftflow using `model`. The file itself goes only when Driftline doesn't use it either;
    /// otherwise it stays for Driftline (returns false).
    @discardableResult
    func delete(_ model: TextModel) -> Bool {
        guard let url = Self.fileURL(for: model) else { return false }
        LocalLLM.shared.unload(model)
        if let marker = Self.sidecar(model, ".used-by-\(Self.me)") { try? FileManager.default.removeItem(at: marker) }
        guard !usedByOtherApp(model) else {
            AppLog.info("\(model.displayName): no longer used by Driftflow; kept for Driftline")
            objectWillChange.send()
            return false
        }
        // If Driftline has it loaded right now, it keeps working until it frees it; macOS frees the space then.
        try? FileManager.default.removeItem(at: url)
        status[model] = .notDownloaded
        return true
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// `<file>.lock`, held with flock while an app downloads that model. The system releases it if the
/// app quits or crashes, so a stopped download never blocks the other app. The file itself stays
/// (removing a file someone may hold a lock on would break the lock); the holder writes its progress
/// in it as "<bytes written> <total bytes>", for the other app to show.
private final class DownloadLock {
    enum Outcome {
        case acquired(DownloadLock)
        /// Another app holds it.
        case busy
        case unavailable
    }

    private let descriptor: Int32

    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(_ url: URL) -> Outcome {
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return .unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return .busy
        }
        return .acquired(DownloadLock(descriptor))
    }

    /// The holder's progress, 0…1.
    static func progress(_ url: URL) -> Double? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let numbers = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard numbers.count == 2, numbers[1] > 0 else { return nil }
        return min(numbers[0] / numbers[1], 1)
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        ftruncate(descriptor, 0)
        _ = pwrite(descriptor, bytes, bytes.count, 0)
    }

    deinit {
        ftruncate(descriptor, 0)
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// One file download with progress. The finished file is moved to `keepAt` (`<file>.download`)
/// for the caller to check and rename.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let keepAt: URL
    private let progress: (Int64, Int64) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var lastReport = Date.distantPast

    init(url: URL, keepAt: URL, progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.url = url
        self.keepAt = keepAt
        self.progress = progress
        self.completion = completion
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, Date().timeIntervalSince(lastReport) > 0.5 else { return }
        lastReport = Date()
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so it's moved now.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            completion(.failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The server answered \(status)."])))
            return
        }
        do {
            try? FileManager.default.removeItem(at: keepAt)
            try FileManager.default.moveItem(at: location, to: keepAt)
            completion(.success(keepAt))
        } catch {
            completion(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        completion(.failure(error))
    }
}

// MARK: - Running a model

/// Runs a downloaded model with llama.cpp on the GPU, one at a time. All llama.cpp calls happen on
/// one serial queue. The model is loaded when first needed and freed after a few idle minutes (or
/// at once when macOS runs short of memory), so it costs nothing while you aren't using it.
final class LocalLLM: @unchecked Sendable {
    static let shared = LocalLLM()

    /// Freed after this long unused.
    static let idleUnload: TimeInterval = 5 * 60

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// One part of a prompt. Template markup is read as the model's special tokens; your text never
    /// is, so a selection that happens to contain "<|im_end|>" stays plain text.
    struct Part {
        let text: String
        let markup: Bool
    }

    private let queue = DispatchQueue(label: "dev.driftflow.llm", qos: .userInitiated)
    // Only touched on `queue`:
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loaded: TextModel?
    /// Exactly what the context's memory holds, so the next prompt can reuse a shared start.
    private var memory: [llama_token] = []
    private var idleTimer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    private var exitHookInstalled = false

    private init() {
        queue.async { [self] in
            llama_log_set({ _, _, _ in }, nil) // llama.cpp is chatty on stderr
            llama_backend_init()
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, self.loaded != nil else { return }
                AppLog.info("Memory is short: freeing the language model")
                self.free()
            }
            source.resume()
            pressure = source
        }
    }

    /// Loads `model` and reads `prefix` (a style's instructions and examples) while you're still talking.
    func prepare(_ model: TextModel, prefix: [Part]) {
        queue.async { [self] in
            do {
                try load(model)
                // Memory ends up holding exactly the prefix (the last dictation's text and answer dropped).
                let tokens = tokenize(prefix)
                try ensureRoom(for: Self.usualContext) // back to the usual size after a long request
                let shared = sharedStart(tokens)
                if shared < tokens.count || memory.count > tokens.count {
                    try reuse(shared)
                    try decode(Array(tokens[memory.count...]))
                }
            } catch {
                AppLog.error("\(model.displayName): couldn't prepare: \(error.localizedDescription)")
            }
            scheduleUnload()
        }
    }

    /// The model's reply to `prompt` (greedy: the same answer every time), or nil when it runs past `limit`.
    func generate(_ model: TextModel, prompt: [Part], maxTokens: Int, limit: TimeInterval) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                defer { scheduleUnload() }
                do {
                    let deadline = Date().addingTimeInterval(limit)
                    try load(model)
                    continuation.resume(returning: try run(tokenize(prompt), maxTokens: maxTokens, deadline: deadline))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Frees `model` if it's the one loaded (it's being deleted).
    func unload(_ model: TextModel) {
        queue.sync { if loaded == model { free() } }
    }

    private func freeForExit() {
        queue.sync { free() }
    }

    // MARK: On the queue

    private func load(_ wanted: TextModel) throws {
        if loaded == wanted, context != nil { return }
        free()
        guard let url = TextModelManager.fileURL(for: wanted), TextModelManager.isComplete(wanted) else {
            throw Failure(errorDescription: "\(wanted.displayName) isn't downloaded. Download it in Settings › AI Model.")
        }
        let started = Date()
        var params = llama_model_default_params()
        params.n_gpu_layers = 999 // all of it on the GPU
        guard let model = llama_model_load_from_file(url.path, params) else {
            throw Failure(errorDescription: "\(wanted.displayName) couldn't be loaded. Delete it in Settings › AI Model and download it again.")
        }
        guard let context = Self.makeContext(model, size: Self.usualContext) else {
            llama_model_free(model)
            throw Failure(errorDescription: "Not enough memory for \(wanted.displayName) right now.")
        }
        self.model = model
        self.context = context
        loaded = wanted
        TextModelManager.markUsed(wanted) // Driftline then knows Driftflow uses this file
        memory = []
        if !exitHookInstalled {
            // llama.cpp's GPU code asserts at exit if a model is still loaded (a crash report on every
            // quit). Registered after the first load, so it runs before llama.cpp's own clean-up.
            exitHookInstalled = true
            atexit { LocalLLM.shared.freeForExit() }
        }
        AppLog.info("\(wanted.displayName): loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    /// Room for the instructions, your text and the answer, in tokens. The usual size fits a dictation
    /// or a selection of up to about 2,000 characters; a longer one gets a larger context for that
    /// request only (up to the 5,000-character limit). Measured with Qwen: 4,096 tokens keep about 370 MB
    /// of working memory, 8,192 about 500 MB, at the same speed.
    static let usualContext = 4096
    static let largestContext = 8192

    private static func makeContext(_ model: OpaquePointer, size: Int) -> OpaquePointer? {
        var params = llama_context_default_params()
        params.n_ctx = UInt32(size)
        params.n_batch = 512
        params.n_ubatch = 512
        params.n_seq_max = 1
        params.no_perf = true
        return llama_init_from_model(model, params)
    }

    /// A context with room for `tokens`: the usual size when that's enough (shrinking back after a
    /// long request), otherwise a larger one.
    private func ensureRoom(for tokens: Int) throws {
        guard let model, let context else { return }
        guard tokens <= Self.largestContext else { throw Failure(errorDescription: "That text is too long for the model.") }
        let size = tokens <= Self.usualContext ? Self.usualContext : min(Self.largestContext, (tokens + 1023) / 1024 * 1024)
        guard Int(llama_n_ctx(context)) != size else { return }
        llama_free(context)
        self.context = nil
        memory = []
        guard let resized = Self.makeContext(model, size: size) else {
            free()
            throw Failure(errorDescription: "Not enough memory for the model right now.")
        }
        self.context = resized
    }

    private func free() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        if let loaded { AppLog.info("\(loaded.displayName): freed") }
        loaded = nil
        memory = []
    }

    private func scheduleUnload() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleUnload)
        timer.setEventHandler { [weak self] in self?.free() }
        timer.resume()
        idleTimer = timer
    }

    private func tokenize(_ parts: [Part]) -> [llama_token] {
        guard let model else { return [] }
        let vocab = llama_model_get_vocab(model)
        var tokens: [llama_token] = []
        for part in parts where !part.text.isEmpty {
            let utf8 = Array(part.text.utf8CString) // null-terminated
            let length = Int32(utf8.count - 1)
            var buffer = [llama_token](repeating: 0, count: Int(length) + 8)
            var count = llama_tokenize(vocab, utf8, length, &buffer, Int32(buffer.count), false, part.markup)
            if count < 0 {
                buffer = [llama_token](repeating: 0, count: Int(-count))
                count = llama_tokenize(vocab, utf8, length, &buffer, Int32(buffer.count), false, part.markup)
            }
            tokens += buffer.prefix(Int(max(count, 0)))
        }
        return tokens
    }

    /// How many leading tokens of `tokens` the memory already holds.
    private func sharedStart(_ tokens: [llama_token]) -> Int {
        var count = 0
        while count < min(tokens.count, memory.count), tokens[count] == memory[count] { count += 1 }
        return count
    }

    /// Keeps the first `count` tokens of memory. Some models (Qwen's recurrent layers) can't drop
    /// part of it, so they start over.
    private func reuse(_ count: Int) throws {
        guard let context, count < memory.count else { return }
        let state = llama_get_memory(context)
        if count > 0, llama_memory_seq_rm(state, 0, llama_pos(count), -1) {
            memory.removeLast(memory.count - count)
        } else {
            llama_memory_clear(state, true)
            memory = []
        }
    }

    private func decode(_ tokens: [llama_token]) throws {
        guard let context, !tokens.isEmpty else { return }
        var start = 0
        while start < tokens.count {
            var chunk = Array(tokens[start..<min(start + Int(llama_n_batch(context)), tokens.count)])
            let result = chunk.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            guard result == 0 else {
                llama_memory_clear(llama_get_memory(context), true)
                memory = []
                throw Failure(errorDescription: result == 1 ? "That text is too long for the model." : "The model stopped with an error (\(result)).")
            }
            memory += chunk
            start += chunk.count
        }
    }

    private func run(_ prompt: [llama_token], maxTokens: Int, deadline: Date) throws -> String? {
        guard model != nil, context != nil, !prompt.isEmpty else { return nil }
        try ensureRoom(for: prompt.count + maxTokens)
        guard let model, let context else { return nil }
        let vocab = llama_model_get_vocab(model)
        // The last prompt token is always read again, to get what comes after it.
        try reuse(min(sharedStart(prompt), prompt.count - 1))
        try decode(Array(prompt[memory.count...]))

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer { llama_sampler_free(sampler) }

        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxTokens {
            if Date() > deadline { return nil }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let special = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, true)
            if special > 0, Self.endMarks.contains(String(decoding: piece.prefix(Int(special)).map(UInt8.init(bitPattern:)), as: UTF8.self)) { break }
            let count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if count > 0 { bytes += piece.prefix(Int(count)).map(UInt8.init(bitPattern:)) }
            try decode([token])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// End-of-turn markers, in case a model file doesn't list them as end tokens.
    private static let endMarks: Set<String> = ["<|im_end|>", "<|endoftext|>", "<turn|>", "<|turn>", "<end_of_turn>"]
}

extension LocalLLM {
    /// A conversation in `model`'s own format: instructions, earlier turns, then (when given) the new
    /// message, ready for the reply. Without `message` it's the shared start of every such prompt.
    static func prompt(for model: TextModel, system: String, turns: [(String, String)], message: String?) -> [Part] {
        var parts: [Part] = []
        func markup(_ text: String) { parts.append(Part(text: text, markup: true)) }
        func text(_ text: String) { parts.append(Part(text: text, markup: false)) }
        switch model.format {
        case .chatML:
            markup("<|im_start|>system\n"); text(system); markup("<|im_end|>\n")
            for (said, reply) in turns {
                markup("<|im_start|>user\n"); text(said); markup("<|im_end|>\n<|im_start|>assistant\n"); text(reply); markup("<|im_end|>\n")
            }
            if let message {
                // Thinking off: the reply starts straight away.
                markup("<|im_start|>user\n"); text(message); markup("<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
            }
        case .gemma:
            markup("<bos><|turn>system\n"); text(system); markup("<turn|>\n")
            for (said, reply) in turns {
                markup("<|turn>user\n"); text(said); markup("<turn|>\n<|turn>model\n"); text(reply); markup("<turn|>\n")
            }
            if let message {
                markup("<|turn>user\n"); text(message); markup("<turn|>\n<|turn>model\n")
            }
        }
        return parts
    }
}
