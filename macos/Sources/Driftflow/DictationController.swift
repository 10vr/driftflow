import AppKit
import Carbon.HIToolbox
import Combine

/// Orchestrates one dictation: trigger → mic (with pre-roll) → streaming on-device model → insert.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case listening
        case finishing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var finalizedText = ""
    @Published private(set) var volatileText = ""
    @Published private(set) var handsFree = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var activeModel = "Loading…"
    @Published private(set) var hudVisible = false
    /// Bumped after each successful insert; drives the checkmark animation.
    @Published private(set) var completedCount = 0
    @Published private(set) var cancelled = false
    /// The most recent dictation went into the stack instead of being pasted (the pill shows a stack).
    @Published private(set) var lastWentToStack = false
    /// The stack button on the pill finished this dictation: keep it rather than paste it.
    private var toStack = false
    /// ✓ on the pill in Stack Mode: paste this one after all.
    private var pasteNow = false
    /// Key release → text handed to the target app, for the most recent dictation.
    @Published private(set) var lastLatencyMs: Int?
    /// Time the microphone took to deliver audio on its most recent cold start.
    @Published private(set) var lastMicColdStartMs: Int?
    /// Parakeet download/load progress (0...1), or nil when idle.
    @Published private(set) var accuracyProgress: Double?
    @Published private(set) var accuracyReady = false
    /// The dictation key is physically down (onboarding lights up its key caps).
    @Published private(set) var triggerHeld = false
    /// A message under the pill, e.g. "No audio from AirPods" with a button to fix it.
    @Published private(set) var toast: HUDToast?
    private var toastWork: DispatchWorkItem?
    private var sessionWork: [DispatchWorkItem] = []
    /// When recording started, to tell a real attempt from an accidental tap.
    private var recordingStartedAt: ContinuousClock.Instant?
    /// Hands-free dictations stop on their own after this long (a forgotten tap shouldn't record all day).
    private let handsFreeLimit: TimeInterval = 10 * 60
    /// What the word list is doing right now, for the Vocabulary pane.
    @Published private(set) var vocabularyStatus = ""

    let settings = AppSettings.shared
    /// Apple's speech engine (macOS 26). Stored untyped because the type doesn't exist on macOS 15,
    /// where Parakeet alone writes the live preview and the final text.
    private let appleEngineStorage: AnyObject? = {
        if #available(macOS 26.0, *), !SpeechEngine.disabledForTesting { return SpeechEngine() }
        return nil
    }()
    @available(macOS 26.0, *)
    private var appleEngine: SpeechEngine? { appleEngineStorage as? SpeechEngine }
    /// False on macOS 15: no Apple speech model, so dictation needs a downloaded Parakeet model.
    var hasAppleSpeech: Bool { appleEngineStorage != nil }

    /// macOS 15: the chosen language decides the model (Unified for English, TDT v3 for the rest),
    /// since there's no Apple model to cover languages Parakeet Unified doesn't speak.
    func matchModelToLanguage() {
        guard !hasAppleSpeech else { return }
        let wanted: AccuracyModel = settings.language == "en" ? (settings.accuracyModel == .parakeetV2 ? .parakeetV2 : .parakeetUnified) : .parakeetV3
        if settings.accuracyModel != wanted, wanted.supports(language: settings.language) { settings.accuracyModel = wanted }
    }
    private let pauseDetector = PauseDetector()
    let parakeet = ParakeetEngine()
    private let audio = AudioCapture()
    private let pipe = AudioPipe()
    private let hotkeys = HotKeyMonitor()
    private let hud = HUDController()
    private let inserter = TextInserter.shared
    private let onboarding = OnboardingWindow()
    private var microphoneAuthorized = Permissions.microphone == .authorized
    private let clock = ContinuousClock()
    private var session: SpeechSession?
    private var finalizer: SegmentedFinalizer?
    private let parakeetPreview = ParakeetPreview()
    /// True while the selected model (not Apple) is driving the live text.
    private var previewFromModel = false
    /// True once Apple's stream has produced any text for this dictation.
    private var appleHasText = false
    private var earlyText: String?
    /// Bumped on every start and abort; async work from an older dictation checks it and bails.
    private var generation = 0
    /// Trigger pressed while the previous dictation was still finishing.
    private var pendingPress = false
    /// When that queued press happened, so hold-vs-tap is judged from the real key-down.
    private var pendingPressAt: TimeInterval?
    private var startTask: Task<Void, Never>?
    private var caretTask: Task<CaretContext, Never>?
    /// The app that was frontmost when dictation started (where the text will land).
    private var targetAppName: String?
    /// That app and, in a browser with website rules, the page's domain (for per-app rules).
    private var targetTask: Task<DictationTarget, Never>?
    /// Voice editing: the text that was selected when you pressed the edit shortcut.
    private var editSelection: String?
    /// True while dictating an instruction for the selected text (the pill says so).
    @Published private(set) var editing = false
    private let corrections = CorrectionWatcher()
    /// `systemUptime` when the key went down (nil when started from the menu).
    private var pressedAt: TimeInterval?
    private var feedbackWork: DispatchWorkItem?
    private var feedbackGiven = false
    private var lingerWork: DispatchWorkItem?
    private var hudHideWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var permissionTimer: Timer?
    let sounds = Sounds()
    private let ducker = AudioDucker()

    /// Holding the trigger for less than this counts as a tap.
    private let tapThreshold: TimeInterval = 0.3
    private let lingerSeconds: TimeInterval = 30

    private init() {}

    func launch() {
        AppLog.noteHowLastSessionEnded()
        let micAccess = switch Permissions.microphone {
        case .authorized: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
        AppLog.info("Started · \(AppLog.systemSummary) · microphone access \(micAccess) · "
            + "accessibility \(AXIsProcessTrusted() ? "on" : "off") · model \(settings.modelPreference.rawValue)")
        if #available(macOS 26.0, *) {
            appleEngine?.onDownloadProgress = { [weak self] progress in
                self?.downloadProgress = progress
                self?.statusMessage = progress.map { "Downloading speech model… \(Int($0 * 100))%" }
            }
        }
        audio.onLevel = { LevelStore.shared.push($0) }
        audio.onColdStart = { [weak self] ms in self?.lastMicColdStartMs = ms }
        audio.onFailure = { [weak self] error in
            // Keep what was said before the device vanished, and say why we stopped.
            guard let self, self.phase == .listening else { return }
            self.stop(commit: true)
            self.show(error: "Microphone disconnected: \(error.localizedDescription)")
        }
        hotkeys.onPress = { [weak self] time in
            self?.triggerHeld = true
            self?.handle(.triggerDown(at: time))
        }
        hotkeys.onRelease = { [weak self] time in
            self?.triggerHeld = false
            self?.handle(.triggerUp(at: time))
        }
        hotkeys.onKeyDown = { [weak self] code in self?.otherKeyDown(code) }
        hotkeys.install(settings.trigger)

        settings.$trigger
            .dropFirst()
            .sink { [weak self] trigger in self?.hotkeys.install(trigger) }
            .store(in: &cancellables)
        settings.$accuracyModel
            .dropFirst()
            .sink { [weak self] model in self?.loadAccuracyModel(model) }
            .store(in: &cancellables)
        settings.$historyRetention
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { _ in HistoryStore.shared.prune() }
            .store(in: &cancellables)
        settings.$vocabulary
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applyVocabulary() }
            .store(in: &cancellables)
        settings.$keepFailedAudio
            .dropFirst()
            .filter { !$0 }
            .sink { _ in HistoryStore.shared.discardRescueAudio() }
            .store(in: &cancellables)
        AudioDucker.restoreAfterCrash()
        HistoryStore.shared.expireRescueAudio()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            onMainThread { HistoryStore.shared.expireRescueAudio() }
        }
        GlobalShortcuts.shared.handlers[.pasteLast] = { [weak self] in self?.pasteLastDictation(fromShortcut: true) }
        GlobalShortcuts.shared.handlers[.handsFree] = { [weak self] in self?.toggleFromMenu() }
        GlobalShortcuts.shared.register(settings.pasteLastShortcut, for: .pasteLast)
        GlobalShortcuts.shared.register(settings.handsFreeShortcut, for: .handsFree)
        GlobalShortcuts.shared.handlers[.editSelection] = { [weak self] in self?.editSelectionByVoice() }
        GlobalShortcuts.shared.register(settings.editShortcut, for: .editSelection)
        settings.$editShortcut.dropFirst()
            .sink { GlobalShortcuts.shared.register($0, for: .editSelection) }
            .store(in: &cancellables)
        settings.$pasteLastShortcut.dropFirst()
            .sink { GlobalShortcuts.shared.register($0, for: .pasteLast) }
            .store(in: &cancellables)
        settings.$handsFreeShortcut.dropFirst()
            .sink { GlobalShortcuts.shared.register($0, for: .handsFree) }
            .store(in: &cancellables)
        settings.$showIdlePill
            .dropFirst()
            .sink { [weak self] show in
                guard let self, self.phase == .idle, !self.hudVisible else { return }
                if show { self.hud.show(self, position: self.settings.hudPosition) } else { self.hud.hide() }
            }
            .store(in: &cancellables)
        if settings.showIdlePill { DispatchQueue.main.async { [self] in hud.show(self, position: settings.hudPosition) } }
        audio.preferredDeviceUIDs = settings.micPriority.map(\.uid)
        settings.$micPriority
            .dropFirst()
            .map { $0.map(\.uid) }
            .removeDuplicates()
            .sink { [weak self] uids in self?.switchMicrophone(to: uids) }
            .store(in: &cancellables)
        settings.$micMode
            .dropFirst()
            .sink { [weak self] mode in self?.applyMicMode(mode) }
            .store(in: &cancellables)
        // A warm mic follows device changes between dictations: your chosen mic reconnecting,
        // the system default changing.
        Publishers.CombineLatest(AudioDevices.shared.$inputs, AudioDevices.shared.$defaultInputName)
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.phase == .idle, self.audio.isRunning, !self.audio.isOnPreferredDevice else { return }
                self.audio.cool()
                try? self.audio.warm()
            }
            .store(in: &cancellables)
        // @Published emits before the value is stored, so debounce and read settings afterwards.
        Publishers.CombineLatest4(settings.$language, settings.$accent, settings.$modelPreference, settings.$vocabulary)
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.prewarm() }
            .store(in: &cancellables)

        watchAccessibility()
        sounds.preload(settings.soundStyle)

        if microphoneAuthorized { applyMicMode(settings.micMode) }
        if !microphoneAuthorized || !accessibilityGranted { showOnboarding() }
        prewarm()
        loadAccuracyModel(settings.accuracyModel)
        // A Mac language with no on-device speech model falls back to English.
        if #available(macOS 26.0, *), hasAppleSpeech {
            Task {
                if await SpeechEngine.resolve(settings.engineConfig) == nil { settings.language = "en" }
            }
        } else {
            // macOS 15: only Parakeet, so only its languages, and never the Apple-only model.
            if !AccuracyModel.allCases.contains(where: { $0 != .apple && $0.supports(language: settings.language) }) {
                settings.language = "en"
            }
            if settings.accuracyModel == .apple { settings.accuracyModel = .parakeetUnified }
            matchModelToLanguage()
        }
    }

    var onboardingWindow: NSWindow? { onboarding.window }
    func resetOnboardingWindow() { onboarding.reset() }

    func showOnboarding() {
        onboarding.show(controller: self)
    }

    private func applyVocabulary() {
        let terms = settings.vocabularyTerms
        vocabularyStatus = terms.isEmpty ? "" : "Getting ready…"
        Task {
            await parakeet.setVocabulary(terms)
            await refreshVocabularyStatus()
        }
    }

    private func refreshVocabularyStatus() async {
        let terms = settings.vocabularyTerms
        guard !terms.isEmpty else { vocabularyStatus = ""; return }
        let count = "\(terms.count) word\(terms.count == 1 ? "" : "s")"
        if let error = await parakeet.vocabularyError {
            vocabularyStatus = "Couldn't prepare word spotting: \(error)"
        } else if await parakeet.boostingActive {
            vocabularyStatus = "\(count) active in Parakeet Unified and Apple Speech"
        } else if settings.accuracyModel == .parakeetUnified {
            vocabularyStatus = "Getting ready…"
        } else {
            vocabularyStatus = "\(count) active in Apple Speech. \(settings.accuracyModel.displayName) fixes spelling only; switch to Parakeet Unified to recognize them by sound."
        }
    }

    /// Onboarding's "Download" button: (re)loads the chosen model, downloading it if needed.
    func retryModelLoad() {
        loadAccuracyModel(settings.accuracyModel)
    }

    /// Why the last model load failed (macOS 15 has nothing else to dictate with, so say so).
    private var accuracyLoadError: String?

    private func loadAccuracyModel(_ model: AccuracyModel) {
        accuracyReady = false
        accuracyLoadError = nil
        Task {
            await parakeet.setVocabulary(settings.vocabularyTerms)
            do {
                try await parakeet.load(model) { progress in
                    Task { @MainActor [weak self] in
                        self?.accuracyProgress = progress
                        ModelManager.shared.reportProgress(model, progress)
                    }
                }
                ModelManager.shared.refresh()
                accuracyReady = await parakeet.isReady
                await refreshVocabularyStatus()
            } catch {
                accuracyReady = false
                accuracyLoadError = error.localizedDescription
            }
            await refreshModelLabel()
        }
    }

    func prewarm() {
        guard phase == .idle else { return }
        if #available(macOS 26.0, *) { appleEngine?.prewarm(settings.engineConfig) }
        Task { await refreshModelLabel() }
    }

    private func refreshModelLabel() async {
        guard #available(macOS 26.0, *), hasAppleSpeech else {
            let language = Locale.current.localizedString(forLanguageCode: settings.language) ?? settings.language
            activeModel = accuracyReady ? "\(language) · \(settings.accuracyModel.displayName)"
                                        : "\(language) · \(settings.accuracyModel.displayName) (getting ready…)"
            return
        }
        guard let (locale, model) = await SpeechEngine.resolve(settings.engineConfig) else {
            activeModel = "Language not supported on this Mac"
            return
        }
        let id = locale.identifier(.bcp47)
        let language = SpeechCatalog.displayName(for: id)
        if accuracyReady, settings.accuracyModel != .apple,
           settings.accuracyModel.supports(language: locale.language.languageCode?.identifier) {
            activeModel = "\(language) · \(settings.accuracyModel.displayName) + Apple live preview"
        } else {
            activeModel = "\(language) · \(model.displayName)"
        }
    }

    private func applyMicMode(_ mode: MicMode) {
        guard phase == .idle else { return }
        lingerWork?.cancel()
        switch mode {
        case .alwaysReady: try? audio.warm()
        case .onDemand, .linger: audio.cool()
        }
    }

    private func watchAccessibility() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            onMainThread {
                guard let self else { return }
                let microphone = Permissions.microphone == .authorized
                if microphone != self.microphoneAuthorized {
                    self.microphoneAuthorized = microphone
                    if microphone { self.applyMicMode(self.settings.micMode) }
                }
                let granted = Permissions.accessibilityGranted
                guard granted != self.accessibilityGranted else { return }
                self.accessibilityGranted = granted
                // Event monitors installed before access was granted never fire; reinstall them.
                if granted { self.hotkeys.install(self.settings.trigger) }
            }
        }
    }

    // MARK: Trigger

    private func otherKeyDown(_ keyCode: UInt16) {
        handle(.otherKey(isEscape: keyCode == UInt16(kVK_Escape), triggerHeld: hotkeys.isDown))
    }

    /// All key decisions come from `TriggerLogic` (unit-tested); this only carries them out.
    private func handle(_ event: TriggerLogic.Event) {
        let state = TriggerLogic.State(
            phase: phase == .idle ? .idle : phase == .listening ? .listening : .finishing,
            handsFree: handsFree,
            pressedAt: pressedAt
        )
        let config = TriggerLogic.Config(
            tapThreshold: tapThreshold,
            tapLocksHandsFree: settings.tapForHandsFree,
            modifierOnlyTrigger: settings.trigger.isModifierOnly
        )
        switch TriggerLogic.decide(event, state: state, config: config) {
        case .none:
            break
        case .start:
            if case .triggerDown(let time) = event { pressedAt = time }
            start(handsFree: false)
        case .commit:
            stop(commit: true)
        case .cancel:
            stop(commit: false)
        case .lockHandsFree:
            handsFree = true
            giveStartFeedback() // a tap can beat the feedback delay
        case .queuePress:
            pendingPress = true
            if case .triggerDown(let time) = event { pendingPressAt = time }
        case .abort:
            abort()
        case .dropQueuedPress:
            pendingPress = false
        }
    }

    /// Uses the new microphone from the next dictation; a warm mic restarts on it right away.
    private func switchMicrophone(to priority: [String]) {
        audio.preferredDeviceUIDs = priority
        guard phase == .idle, audio.isRunning, !audio.isOnPreferredDevice else { return }
        audio.cool()
        try? audio.warm()
    }

    /// Types the most recent dictation again where the cursor is (after the menu has closed).
    func pasteLastDictation(fromShortcut: Bool = false) {
        guard let last = HistoryStore.shared.entries.first(where: { !$0.text.isEmpty }) else { return }
        Task {
            if fromShortcut {
                // Wait for the shortcut's own keys to come up, or ⌃⌥ would ride along with ⌘V.
                for _ in 0..<40 where !NSEvent.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            } else {
                try? await Task.sleep(for: .milliseconds(250)) // let the menu close first
            }
            if inserter.insert(last.text, method: settings.insertionMethod, restoreClipboard: settings.restoreClipboard) == .inserted {
                DictationStack.shared.remove(text: last.text)
            }
        }
    }

    /// A line clicked in the stack: pasted where your cursor is, then out of the stack.
    func paste(fromStack item: StackItem) {
        pasteFromStack(item.text, ids: [item.id])
    }

    /// Paste All: the whole stack at your cursor, top to bottom.
    func pasteAllFromStack() {
        let items = DictationStack.shared.items
        guard !items.isEmpty else { return }
        pasteFromStack(DictationStack.shared.joined, ids: items.map(\.id))
    }

    private func pasteFromStack(_ text: String, ids: [UUID]) {
        Task {
            if await nothingToPasteInto() {
                showToast(HUDToast(icon: "character.cursor.ibeam", text: "Click into a text box first, then choose it again."), for: 3)
                return
            }
            let context = settings.smartSpacing && accessibilityGranted ? await CaretContext.capture() : .unknown
            if deliver(text, context: context) { DictationStack.shared.remove(ids) }
        }
    }

    /// Stack Mode in the menu: every dictation goes into the stack until it's turned off.
    func toggleStackMode() {
        settings.stackMode.toggle()
        if settings.stackMode { DictationStack.shared.show() }
        // Say it plainly: with the mode on by mistake, nothing would paste.
        showToast(HUDToast(icon: "rectangle.stack", text: settings.stackMode
            ? "Stack Mode on: your dictations go into the stack."
            : "Stack Mode off: your dictations paste again."), for: 2.5)
    }

    /// True only when the app you're in clearly has no text box selected (see `TextBoxCheck`).
    private func nothingToPasteInto() async -> Bool {
        guard accessibilityGranted, !TextInserter.frontmostIsRemoteDesktop,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return false }
        return await Task.detached(priority: .userInitiated) { TextBoxCheck.check(pid: pid) == .noTextBox }.value
    }

    /// Keeps a failed dictation's audio so it can be retried from History (if allowed).
    private func rescue(_ session: SpeechSession) {
        // Only kept when there's a history entry to retry it from.
        let file = settings.keepFailedAudio && settings.historyRetention != .off ? RescueAudio.save(session.recorder.take()) : nil
        HistoryStore.shared.addFailed(audioFile: file, appName: targetAppName)
        showToast(HUDToast(icon: "exclamationmark.arrow.triangle.2.circlepath",
                           text: file == nil ? "That dictation couldn't be transcribed." : "That dictation couldn't be transcribed. Its audio is saved so you can retry.",
                           action: file == nil ? nil : .openHistory), for: 8)
    }

    /// Transcribes a failed dictation's saved audio again; on success the entry gets its text,
    /// the audio is deleted and the text is copied to the clipboard.
    func retry(_ entry: HistoryEntry) async -> Bool {
        guard let file = entry.audioFile else { return false }
        let url = RescueAudio.url(file)
        var text = ""
        if accuracyReady, settings.accuracyModel != .apple, settings.accuracyModel.supports(language: settings.language),
           let reader = try? await AudioDecoder.open(url) {
            var samples: [Float] = []
            while let block = try? await reader.nextBlock() { samples += block }
            text = (try? await parakeet.transcribe(samples)) ?? ""
        }
        if text.isEmpty, hasAppleSpeech,
           let segments = try? await FileTranscription.run(url, engine: .apple(settings.engineConfig), onProgress: { _ in }) {
            text = segments.map(\.text).joined(separator: " ")
        }
        text = settings.textProcessor.process(text, english: settings.language == "en")
        guard !text.isEmpty else { return false }
        var updated = entry
        updated.text = text
        updated.status = nil
        updated.audioFile = nil
        HistoryStore.shared.update(updated)
        RescueAudio.delete(file)
        inserter.copy(text)
        return true
    }

    /// Called when the app quits: never leave other audio turned down.
    func restoreAudioOnQuit() {
        ducker.restore()
    }

    /// ✕ on the pill.
    func cancelFromHUD() {
        stop(commit: false)
    }

    func showToast(_ toast: HUDToast, for seconds: TimeInterval = 5) {
        // Vocabulary toasts quote a dictated word, so only their kind is logged.
        AppLog.info("Notice: " + (toast.icon == "character.book.closed" || toast.text.contains("Vocabulary") ? "vocabulary suggestion" : toast.text))
        toastWork?.cancel()
        self.toast = toast
        if !hud.isVisible { hud.show(self, position: settings.hudPosition) }
        let work = DispatchWorkItem { [weak self] in self?.dismissToast() }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismissToast() {
        toastWork?.cancel()
        toast = nil
        if phase == .idle, !hudVisible, !settings.showIdlePill {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.toast == nil, !self.hudVisible else { return }
                self.hud.hide()
            }
        }
    }

    func performToastAction() {
        guard let action = toast?.action else { return }
        dismissToast()
        switch action {
        case .chooseMicrophone: openSettings(.general)
        case .openHistory: openSettings(.history)
        case .installUpdate: Updater.shared.installNow()
        case .addToVocabulary(let term):
            let terms = settings.vocabularyTerms
            if !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                settings.vocabulary = (terms + [term]).joined(separator: "\n")
            }
            showToast(HUDToast(icon: "checkmark", text: "Added “\(term)” to your Vocabulary."), for: 2)
        }
    }

    func openSettings(_ pane: SettingsView.Pane) {
        SettingsRouter.shared.pane = pane
        NSApp.activate()
        let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "," }
        if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }

    /// The microphone actually in use (the highest-ranked connected one).
    private var microphoneName: String {
        let uid = AudioDevices.deviceID(forPriority: settings.micPriority.map(\.uid)).flatMap(AudioDevices.uid(of:))
        return AudioDevices.shared.inputs.first { $0.uid == uid }?.name ?? AudioDevices.shared.defaultInputName
    }

    /// Watches the first seconds of a dictation: a Bluetooth/iPhone mic still connecting, a mic
    /// that delivers pure silence, and hands-free dictations left running.
    private func scheduleSessionChecks(generation: Int) {
        sessionWork.forEach { $0.cancel() }
        func after(_ seconds: TimeInterval, _ body: @escaping () -> Void) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == generation, self.phase == .listening else { return }
                body()
            }
            sessionWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        after(0.35) { [self] in
            guard !audio.isDelivering else { return }
            let message = "Connecting to \(microphoneName)…"
            statusMessage = message
            Task { @MainActor [weak self] in
                while let self, self.generation == generation, self.phase == .listening, !self.audio.isDelivering {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let self, self.statusMessage == message { self.statusMessage = nil }
            }
        }
        after(2.0) { [self] in
            guard audio.isDelivering, audio.peakDecibels < -90 else { return }
            showToast(HUDToast(icon: "mic.slash", text: "No audio from “\(microphoneName)”. Is it muted?", action: .chooseMicrophone), for: 8)
        }
        after(handsFreeLimit - 60) { [self] in
            guard handsFree else { return }
            showToast(HUDToast(icon: "timer", text: "Dictation will stop in 1 minute."), for: 10)
        }
        after(handsFreeLimit) { [self] in
            guard handsFree else { return }
            stop(commit: true)
        }
    }

    /// The stack button on the pill: finish now and keep the text in the stack.
    func finishIntoStack() {
        guard phase == .listening, editSelection == nil else { return }
        toStack = true
        stop(commit: true)
    }

    /// ✓ on the pill: finish and paste (in Stack Mode too).
    func finishAndPaste() {
        guard phase == .listening else { return }
        pasteNow = true
        stop(commit: true)
    }

    func toggleFromMenu() {
        switch phase {
        case .idle:
            pressedAt = nil
            start(handsFree: true)
        case .listening:
            stop(commit: true)
        case .finishing:
            break
        }
    }

    // MARK: Session

    private func start(handsFree: Bool) {
        guard phase == .idle else { return }
        if [.denied, .restricted].contains(Permissions.microphone) {
            show(error: "Microphone access is off. Turn it on in System Settings.")
            Permissions.openMicrophoneSettings()
            return
        }

        lingerWork?.cancel()
        generation += 1
        let generation = generation
        pendingPress = false
        cancelled = false
        lastWentToStack = false
        toStack = false
        pasteNow = false
        appleHasText = false
        earlyText = nil
        phase = .listening
        self.handsFree = handsFree
        finalizedText = ""
        volatileText = ""
        statusMessage = nil
        lastError = nil
        LevelStore.shared.reset()

        // Capture starts before the model is ready; the pipe buffers audio until the session attaches.
        // The microphone switches on in the background (a cold start takes 70–160 ms), so the pill
        // and the start sound don't wait for it.
        pipe.reset()
        audio.beginRecording(into: pipe, includePreroll: true) { [weak self] error in
            guard let self, let error else { return }
            self.microphoneFailed(error, generation: generation)
        }

        recordingStartedAt = clock.now
        dismissToast()
        scheduleSessionChecks(generation: generation)
        caretTask = settings.smartSpacing && accessibilityGranted ? Task { await CaretContext.capture() } : nil
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        AppLog.info("Dictation started (\(handsFree ? "hands-free" : "hold") · microphone \(microphoneName) · in \(targetAppName ?? "unknown app"))")
        corrections.stop()
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let readHost = accessibilityGranted && bundleID.map(DictationTarget.browsers.contains) == true
            && settings.appRules.contains(where: \.isWebsite)
        targetTask = Task { DictationTarget(bundleID: bundleID, host: readHost ? await DictationTarget.currentHost() : nil) }
        if editSelection == nil, settings.language == "en" {
            // Load the style's model while you talk (a website rule may still change it at the end).
            let likely = EffectiveRules.resolve(settings.appRules, target: DictationTarget(bundleID: bundleID), defaultStyle: settings.aiStyle)
            AIRewriter.shared.prepare(likely.style)
        }

        // Recording is already running. For a modifier key (Right ⌘ doubles as the shortcut key),
        // hold the sound and overlay back 150 ms: if ⌘C/⌘V follows, we cancel silently.
        feedbackGiven = false
        feedbackWork?.cancel()
        if settings.trigger.isModifierOnly, !handsFree {
            let work = DispatchWorkItem { [weak self] in self?.giveStartFeedback() }
            feedbackWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else {
            giveStartFeedback()
        }

        let config = settings.engineConfig
        startTask = Task {
            do {
                let session: SpeechSession
                if #available(macOS 26.0, *), let engine = appleEngine {
                    session = try await engine.begin(config) { [weak self] finalized, volatile in
                        // A previous dictation's session can still be finalizing: ignore its text.
                        guard let self, self.phase == .listening, self.generation == generation else { return }
                        self.appleHasText = true
                        if self.previewFromModel { return } // the selected model owns the live text
                        // Hand over from the early Parakeet preview only once Apple has caught up,
                        // so the live text never shrinks.
                        if let early = self.earlyText {
                            let appleWords = (finalized + volatile).split(separator: " ").count
                            guard appleWords >= early.split(separator: " ").count else { return }
                            self.earlyText = nil
                        }
                        self.finalizedText = finalized
                        self.volatileText = volatile
                    }
                } else {
                    try requireParakeet(for: config.language)
                    session = RecordingSession(language: config.language)
                }
                guard generation == self.generation else {
                    await session.cancel() // aborted while the model was loading
                    return
                }
                self.session = session
                if settings.accuracyModel != .apple, accuracyReady,
                   settings.accuracyModel.supports(language: session.languageCode) {
                    let finalizer = SegmentedFinalizer(parakeet: parakeet, recorder: session.recorder)
                    session.onPhraseEnd = { finalizer.phraseEnded(at: $0) }
                    self.finalizer = finalizer
                    if session is RecordingSession, phase == .listening {
                        pauseDetector.start(recorder: session.recorder) { [weak session] in session?.onPhraseEnd?($0) }
                    }
                    // Skip the preview if the key was already released while the model loaded.
                    // Without Apple's model (macOS 15), Parakeet always drives the live text.
                    let continuous = settings.livePreview == .finalModel || session is RecordingSession
                    previewFromModel = continuous
                    if phase == .listening {
                        parakeetPreview.start(
                            mode: continuous ? .continuous : .early,
                            parakeet: parakeet, recorder: session.recorder, finalizer: continuous ? finalizer : nil,
                            appleHasText: { [weak self] in self?.appleHasText ?? true },
                            show: { [weak self] settled, live in
                                guard let self, self.phase == .listening else { return }
                                if continuous {
                                    let full = SegmentedFinalizer.join([settled, live])
                                    self.finalizedText = String(full.prefix(settled.count))
                                    self.volatileText = String(full.dropFirst(settled.count))
                                } else {
                                    self.earlyText = live
                                    self.volatileText = live
                                }
                            })
                    }
                } else {
                    finalizer = nil
                    previewFromModel = false
                }
                pipe.attach { buffer in session.feed(buffer) }
            } catch {
                guard generation == self.generation else { return }
                audio.endRecording()
                releaseMic()
                parakeetPreview.stop()
                pauseDetector.stop()
                ducker.restore() // the duck may already have happened while the model was loading
                show(error: error.localizedDescription)
                finishUp(hideAfter: 0)
            }
        }
    }

    private func stop(commit: Bool) {
        guard phase == .listening else { return }
        guard commit else {
            abort()
            return
        }
        let releasedAt = clock.now
        parakeetPreview.stop()
        pauseDetector.stop()
        audio.endRecording()
        releaseMic()
        phase = .finishing
        ducker.restore()
        if settings.playSounds { sounds.play(.stop, style: settings.soundStyle) }

        let startTask = startTask
        let generation = generation
        Task {
            await startTask?.value
            // nil session: start failed and already reported; generation changed: aborted.
            guard generation == self.generation, let session else { return }
            self.session = nil

            var inserted = false
            var failed = false
            do {
                let english = session.languageCode == "en"
                let raw = try await finalText(from: session)
                guard generation == self.generation else { return }
                if let selection = editSelection {
                    // An edit that fails isn't a lost dictation: say why, keep no audio.
                    do {
                        inserted = try await applyEdit(to: selection, instruction: raw, english: english, generation: generation)
                    } catch {
                        if generation == self.generation { show(error: error.localizedDescription) }
                    }
                    guard generation == self.generation else { return }
                    finishUp(hideAfter: inserted ? 0.5 : 0)
                    if inserted { completedCount += 1 }
                    return
                }
                let (spoken, undoPrevious) = english ? settings.textProcessor.applyScratch(raw) : (raw, false)
                let target = await targetTask?.value ?? DictationTarget()
                let rules = EffectiveRules.resolve(settings.appRules, target: target, defaultStyle: settings.aiStyle)
                var text: String
                let snippet = Snippet.match(spoken, in: settings.snippets)
                if let snippet {
                    text = snippet.expanded() // inserted exactly as saved
                } else {
                    text = settings.textProcessor.process(spoken, english: english)
                    // AI Styles: English only (the prompts are English, and a rewrite must never translate).
                    if english, rules.style != .literal, !text.isEmpty,
                       let polished = await AIRewriter.shared.rewrite(text, style: rules.style) {
                        guard generation == self.generation else { return }
                        text = settings.textProcessor.applyVocabularyAndReplacements(polished)
                    }
                    if rules.plainText { text = TextProcessor.plain(text, vocabulary: settings.spellingTerms) }
                }
                var context = await caretTask?.value ?? .unknown
                guard generation == self.generation else { return } // Esc while we waited
                if undoPrevious {
                    // Only a scratch: report the result; with more text after it, the pill's checkmark does.
                    if scratchLastInsertion() {
                        // Let the app apply the deletion before reading what's left before the caret.
                        try? await Task.sleep(for: .milliseconds(120))
                        context = await CaretContext.capture()
                        guard generation == self.generation else { return }
                        if text.isEmpty { showToast(HUDToast(icon: "arrow.uturn.backward", text: "Removed your last dictation."), for: 2) }
                    } else {
                        showToast(HUDToast(icon: "arrow.uturn.backward",
                                           text: "Couldn't remove your last dictation: the text has changed since, or it's in another app."), for: 4)
                    }
                }
                // Into the stack when you asked for it (the pill's button, Stack Mode), or when there's
                // clearly no text box to paste into.
                let stacking = !text.isEmpty && !pasteNow && (toStack || settings.stackMode)
                var noTextBox = false
                if !stacking, !text.isEmpty, settings.autoPaste { noTextBox = await nothingToPasteInto() }
                guard generation == self.generation else { return }
                let stacked = stacking || (!text.isEmpty && noTextBox)
                if stacked {
                    DictationStack.shared.add(text)
                    lastWentToStack = true
                    if noTextBox {
                        showToast(HUDToast(icon: "rectangle.stack", text: settings.stackTab == .hidden
                            ? "No text box here, so it's in your stack (in the menu bar)."
                            : "No text box here, so it's in your stack."), for: 3)
                    }
                } else {
                    inserted = deliver(text, context: context)
                }
                let latency = Self.milliseconds(clock.now - releasedAt)
                // Length and timing only: what was said is never logged.
                AppLog.info("Dictation finished: \(text.split(whereSeparator: \.isWhitespace).count) words, "
                    + "\(stacked ? (noTextBox ? "put in the stack (no text box)" : "put in the stack") : inserted ? "inserted" : "not inserted") \(latency) ms after release")
                if inserted {
                    lastLatencyMs = latency
                    if rules.pressReturn {
                        try? await Task.sleep(for: .milliseconds(80)) // after the paste has landed
                        inserter.pressReturn()
                    } else if snippet == nil {
                        learnFromCorrections(to: text)
                    }
                }
                if !text.isEmpty { HistoryStore.shared.add(text, appName: targetAppName, latencyMs: inserted ? latency : nil) }
                let spokeFor = recordingStartedAt.map { releasedAt - $0 } ?? .zero
                if text.isEmpty, !undoPrevious, spokeFor > .milliseconds(800) {
                    // Loud, long audio that produced nothing is a failure worth keeping; quiet audio just had no speech.
                    if audio.peakDecibels > -35, spokeFor > .milliseconds(1500) {
                        failed = true
                    } else {
                        showToast(HUDToast(icon: "waveform.slash", text: "No speech detected. Try speaking a little louder or closer."), for: 4)
                    }
                }
            } catch {
                guard generation == self.generation else { return } // aborted: nothing to report
                failed = true
                show(error: error.localizedDescription)
            }
            if failed { rescue(session) }
            finishUp(hideAfter: inserted || lastWentToStack ? 0.5 : 0)
            if inserted || lastWentToStack { completedCount += 1 }
        }
    }

    /// The microphone couldn't be opened for the dictation that just started: end it and say why.
    private func microphoneFailed(_ error: Error, generation: Int) {
        guard generation == self.generation, phase == .listening else { return }
        self.generation += 1 // the session that was starting up is abandoned
        feedbackWork?.cancel()
        feedbackWork = nil
        parakeetPreview.stop()
        pauseDetector.stop()
        audio.endRecording()
        releaseMic()
        startTask?.cancel()
        finalizer?.cancel()
        finalizer = nil
        if let session { Task { await session.cancel() } }
        session = nil
        ducker.restore()
        show(error: error.localizedDescription)
        finishUp(hideAfter: 0)
    }

    /// Cancels the current dictation immediately, even if the model is still loading.
    private func abort() {
        guard phase != .idle else { return }
        AppLog.info("Dictation cancelled")
        feedbackWork?.cancel()
        feedbackWork = nil
        generation += 1
        parakeetPreview.stop()
        pauseDetector.stop()
        audio.endRecording()
        releaseMic()
        startTask?.cancel()
        finalizer?.cancel()
        finalizer = nil
        if let session {
            Task { await session.cancel() }
        }
        session = nil
        ducker.restore()
        if feedbackGiven, settings.playSounds { sounds.play(.cancel, style: settings.soundStyle) }
        cancelled = true
        finishUp(hideAfter: 0)
    }

    private func finishUp(hideAfter delay: TimeInterval) {
        sessionWork.forEach { $0.cancel() }
        sessionWork = []
        pipe.reset()
        caretTask = nil
        targetTask = nil
        editSelection = nil
        editing = false
        phase = .idle
        handsFree = false
        if lastError == nil { hideHUD(after: delay) }
        prewarm()
        // The trigger went down while we were finishing and is still held: start right away.
        if pendingPress {
            pendingPress = false
            if hotkeys.isDown {
                pressedAt = pendingPressAt ?? ProcessInfo.processInfo.systemUptime
                start(handsFree: false)
            }
        }
    }

    /// macOS 15 has no Apple model to fall back on: dictation waits for Parakeet.
    private func requireParakeet(for language: String) throws {
        struct NotReady: LocalizedError { let errorDescription: String? }
        if settings.accuracyModel == .apple || !settings.accuracyModel.supports(language: language) {
            throw NotReady(errorDescription: "\(settings.accuracyModel.displayName) doesn't support this language. Choose another model or language in Settings › Models.")
        }
        if !accuracyReady, let accuracyLoadError {
            throw NotReady(errorDescription: "The speech model couldn't load (\(accuracyLoadError)). Retry from Settings › Models.")
        }
        guard accuracyReady else {
            let progress = accuracyProgress.map { " (\(Int($0 * 100))%)" } ?? ""
            throw NotReady(errorDescription: "The speech model is still getting ready\(progress). Dictation works as soon as it's done.")
        }
    }

    /// Parakeet over the whole utterance when available (more accurate); Apple's streamed result
    /// finalizes in parallel and is used as the fallback.
    private func finalText(from session: SpeechSession) async throws -> String {
        let apple = Task { try await session.finish() }
        let finalizer = self.finalizer
        self.finalizer = nil
        if let finalizer, let text = await finalizer.finish(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return try await apple.value
    }

    /// The last text typed into an app, so "scratch that" can take it back.
    private var lastInsertion: (text: String, pid: pid_t, at: Date)?

    /// Removes the previous dictation from the app it went into, if you're still there and it's
    /// unchanged (see `TextInserter.remove`). Works once per dictation, within 10 minutes.
    private func scratchLastInsertion() -> Bool {
        guard let last = lastInsertion, Date().timeIntervalSince(last.at) < 600,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == last.pid else { return false }
        lastInsertion = nil
        return inserter.remove(last.text, insertedAt: last.at)
    }

    // MARK: Voice editing and learning

    /// The edit shortcut: select text, press it, say how to change it ("make this shorter"), and
    /// press it again (or your dictation key). The selection is replaced with the result.
    func editSelectionByVoice() {
        if phase == .listening, editing { return stop(commit: true) }
        guard phase == .idle else { return }
        if case .unavailable(let reason) = AIRewriter.shared.availability {
            return showToast(HUDToast(icon: "wand.and.sparkles", text: "Editing by voice needs Apple Intelligence. \(reason)"), for: 5)
        }
        guard accessibilityGranted else { return show(error: "Allow Accessibility access to edit text by voice.") }
        Task {
            let selection = await SelectionReader.read()
            guard phase == .idle else { return }
            guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let key = settings.editShortcut?.display ?? "the edit shortcut"
                return showToast(HUDToast(icon: "text.cursor", text: "Select the text you want to change first, then press \(key)."), for: 4)
            }
            editSelection = selection
            editing = true
            pressedAt = nil
            start(handsFree: true)
            if phase != .listening {
                editSelection = nil
                editing = false
            }
        }
    }

    /// Rewrites `selection` as the spoken `instruction` says and puts the result in its place.
    private func applyEdit(to selection: String, instruction raw: String, english: Bool, generation: Int) async throws -> Bool {
        let instruction = settings.textProcessor.process(raw, english: english)
        guard !instruction.isEmpty else {
            showToast(HUDToast(icon: "waveform.slash", text: "No instruction heard, so the selection wasn't changed."), for: 4)
            return false
        }
        let result = try await AIRewriter.shared.edit(selection, instruction: instruction)
        guard generation == self.generation else { return false }
        let inserted = deliver(result, context: .unknown, exact: true)
        if inserted { HistoryStore.shared.add(result, appName: targetAppName, latencyMs: nil) }
        return inserted
    }

    /// After a dictation: if you correct a word in it into a name or term, offer to add it to Vocabulary.
    private func learnFromCorrections(to text: String) {
        guard settings.learnCorrections, accessibilityGranted else { return }
        corrections.watch(inserted: text, vocabulary: settings.spellingTerms) { [weak self] term in
            guard let self, self.phase == .idle else { return }
            self.showToast(HUDToast(icon: "character.book.closed", text: "Add “\(term)” to your Vocabulary?",
                                    action: .addToVocabulary(term)), for: 8)
        }
    }

    /// Returns true if text was handed to the target app. `exact`: no spacing added (voice edits
    /// replace a selection).
    private func deliver(_ text: String, context: CaretContext, exact: Bool = false) -> Bool {
        guard !text.isEmpty else { return false }

        guard settings.autoPaste else {
            inserter.copy(text)
            return false
        }
        var output = text
        if settings.smartSpacing, !exact {
            // With a readable caret we add exactly the space needed before; otherwise one after.
            output = context.precedingText == nil ? text + " " : context.leadingSpace(for: text) + text
        }
        switch inserter.insert(output, method: settings.insertionMethod, restoreClipboard: settings.restoreClipboard) {
        case .inserted:
            if let app = NSWorkspace.shared.frontmostApplication {
                lastInsertion = (output, app.processIdentifier, Date())
            }
            InputActivity.start()
            return true
        case .copiedOnly:
            show(error: "Copied to clipboard. Allow Accessibility access to paste automatically.")
            return false
        }
    }

    private func releaseMic() {
        switch settings.micMode {
        case .onDemand:
            audio.cool()
        case .linger:
            lingerWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .idle else { return }
                self.audio.cool()
            }
            lingerWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + lingerSeconds, execute: work)
        case .alwaysReady:
            break
        }
    }

    // MARK: Demo

    /// `Driftflow --demo`: plays the HUD's full lifecycle with simulated speech, for design review.
    /// Developer aid (`--tap-test`): a quick tap of the dictation key through the real controller
    /// (no hot keys installed), then reports whether hands-free locked. Discards the recording.
    func runTapTest() async {
        func state(_ label: String) {
            print("\(label): phase=\(phase) handsFree=\(handsFree) error=\(lastError ?? "-") toast=\(toast?.text ?? "-")")
        }
        let now = { ProcessInfo.processInfo.systemUptime }
        let down = now()
        handle(.triggerDown(at: down))
        print(String(format: "start() kept the main thread busy for %.0f ms", (now() - down) * 1000))
        state("after key down")
        try? await Task.sleep(for: .milliseconds(120))
        handle(.triggerUp(at: down + 0.12)) // the key event's own time, as HotKeyMonitor now reports
        state("after key up (0.12 s tap)")
        for second in 1...4 {
            try? await Task.sleep(for: .seconds(1))
            state("after \(second) s")
        }
        abort()
        state("after abort")
    }

    func runDemo() async {
        let words = "Hi team, quick update on the campaign. The client approved the storyboard, so we can start the shoot on Monday.".split(separator: " ")
        while true {
            finalizedText = ""
            volatileText = ""
            cancelled = false
            lastError = nil
            phase = .listening
            showHUD()
            try? await Task.sleep(for: .milliseconds(700))
            for (index, word) in words.enumerated() {
                LevelStore.shared.push(Float.random(in: 0.45...0.95))
                volatileText += (volatileText.isEmpty ? "" : " ") + word
                if word.hasSuffix(",") || word.hasSuffix(".") || index == words.count - 1 {
                    finalizedText += (finalizedText.isEmpty ? "" : " ") + volatileText
                    volatileText = ""
                }
                try? await Task.sleep(for: .milliseconds(170))
                LevelStore.shared.push(Float.random(in: 0.05...0.3))
                try? await Task.sleep(for: .milliseconds(60))
            }
            phase = .finishing
            try? await Task.sleep(for: .milliseconds(120))
            phase = .idle
            completedCount += 1
            hideHUD(after: 0.6)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// `Driftflow --hud-demo <dir>`: the hands-free pill over a black, then white backdrop, with
    /// the ✕/✓ buttons hidden and shown. Captures the screen around the pill (the app may capture
    /// its own windows without Screen Recording access) at fixed times, including the first frames
    /// after the pill appears, where the old adaptive glass flipped. Quits when done.
    func runHUDDemo(to directory: URL) async {
        // The screen the pill will appear on (the one you're working on).
        let screen = HUDController.activeScreen() ?? NSScreen.main ?? NSScreen.screens[0]
        let backdrop = NSWindow(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 320),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.isReleasedWhenClosed = false
        handsFree = true
        finalizedText = "Hi team, quick update on the campaign."
        LevelStore.shared.set(0.3)
        // Region around the bottom-centre pill, in global top-left coordinates.
        let visible = screen.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let region = CGRect(x: screen.frame.midX - 360, y: primaryHeight - visible.minY - 12 - 120, width: 720, height: 120)
        for dark in [true, false] {
            backdrop.backgroundColor = dark ? .black : .white
            backdrop.orderFrontRegardless()
            HUDHover.shared.forced = false
            phase = .listening
            try? await Task.sleep(for: .milliseconds(400))
            showHUD()
            let name = dark ? "black" : "white"
            var elapsed = 0
            for ms in [30, 80, 150, 300, 1000] {
                try? await Task.sleep(for: .milliseconds(ms - elapsed))
                elapsed = ms
                Self.capture(region, to: directory.appendingPathComponent("\(name)-start-\(ms)ms.png"))
            }
            HUDHover.shared.forced = true
            elapsed = 0
            for ms in [60, 150, 400] {
                try? await Task.sleep(for: .milliseconds(ms - elapsed))
                elapsed = ms
                Self.capture(region, to: directory.appendingPathComponent("\(name)-buttons-\(ms)ms.png"))
            }
            HUDHover.shared.forced = false
            try? await Task.sleep(for: .milliseconds(150))
            Self.capture(region, to: directory.appendingPathComponent("\(name)-hiding-150ms.png"))
            let short = finalizedText
            finalizedText = "Hi team, quick update on the campaign. The client approved the storyboard, so we can start the shoot on Monday."
            try? await Task.sleep(for: .milliseconds(500))
            Self.capture(region, to: directory.appendingPathComponent("\(name)-long.png"))
            finalizedText = short
            try? await Task.sleep(for: .milliseconds(500))
            phase = .idle
            hud.hide()
            hudVisible = false
        }
        NSApp.terminate(nil)
    }

    /// `CGWindowListCreateImage` is unavailable to Swift on macOS 15+, but still works for an app's
    /// own windows; looked up at run time for this developer aid only.
    static func capture(_ rect: CGRect, to url: URL) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: Fn.self)
        guard let image = create(rect, 1 /* onScreenOnly */, 0, 0)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: HUD & feedback

    private func giveStartFeedback() {
        feedbackWork?.cancel()
        feedbackWork = nil
        guard phase == .listening, !feedbackGiven else { return }
        feedbackGiven = true
        if settings.playSounds { sounds.play(.start, style: settings.soundStyle) }
        showHUD()
        if settings.duckAudio {
            let generation = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + (settings.playSounds ? 0.35 : 0)) { [weak self] in
                guard let self, self.generation == generation, self.phase == .listening else { return }
                self.ducker.duck()
            }
        }
    }

    private func showHUD() {
        guard settings.showHUD else { return }
        hudHideWork?.cancel()
        hud.show(self, position: settings.hudPosition)
        hudVisible = true
    }

    private func hideHUD(after delay: TimeInterval) {
        hudHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hudVisible = false
            // Let the SwiftUI exit transition finish before removing the panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !self.hudVisible, !self.settings.showIdlePill, self.toast == nil { self.hud.hide() }
            }
        }
        hudHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func show(error message: String) {
        AppLog.error(message)
        lastError = message
        statusMessage = message
        showHUD()
        hideHUD(after: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { [weak self] in
            guard let self, self.statusMessage == message else { return }
            self.statusMessage = nil
        }
    }


    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
