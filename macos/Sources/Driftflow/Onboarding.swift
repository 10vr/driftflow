import AppKit
import AVFoundation
import SwiftUI

/// First-run guide: a few short steps with the current phase on the left and the step itself on
/// a card to the right. Remembers where you left off, and returns to Permissions if one is revoked.
@MainActor
final class OnboardingWindow {
    private(set) var window: NSWindow?

    /// Forgets the window so the next `show` builds a fresh one (developer snapshots).
    func reset() {
        window?.close()
        window = nil
    }

    func show(controller: DictationController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar gives the window a full-height title bar, so the close,
        // minimise and zoom buttons sit inset from the corner like other Mac apps' windows.
        let toolbar = NSToolbar(identifier: "onboarding")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 900, height: 580)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(controller: controller, settings: .shared) { [weak window] in
            window?.close()
        })
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private enum OnboardingStep: Int, CaseIterable {
    // The number is saved (where you left off), so a new step takes the next free one; `order` sets
    // where it appears.
    case welcome = 0, permissions = 1, model = 2, microphone = 3, shortcut = 4, tryIt = 5, done = 6, aiModel = 7

    static let order: [OnboardingStep] = [.welcome, .permissions, .model, .microphone, .shortcut, .aiModel, .tryIt, .done]

    var next: OnboardingStep {
        let index = Self.order.firstIndex(of: self) ?? 0
        return Self.order[min(index + 1, Self.order.count - 1)]
    }

    var previous: OnboardingStep {
        let index = Self.order.firstIndex(of: self) ?? 0
        return Self.order[max(index - 1, 0)]
    }

    var phase: Int {
        switch self {
        case .welcome: 0
        case .permissions: 1
        case .model, .microphone, .shortcut, .aiModel: 2
        case .tryIt: 3
        case .done: 4
        }
    }

    static let phases = ["Get started", "Permissions", "Set up", "Try it", "Done"]

    var title: String {
        switch self {
        case .welcome: "Welcome to Driftflow"
        case .permissions: "Two permissions"
        case .model: "Language and model"
        case .microphone: "Check your microphone"
        case .shortcut: "Your dictation key"
        case .aiModel: "AI writing"
        case .tryIt: "Try it"
        case .done: "You're all set"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "Hold a key, speak, let go. Your words appear wherever you're typing, transcribed on this Mac."
        case .permissions: "Driftflow needs to hear you, and to type into the app you're using."
        case .model: Platform.hasAppleSpeech
            ? "Pick the language you speak. English uses Parakeet, the most accurate model we tested; other languages use Apple's built-in models."
            : "Pick the language you speak. Driftflow transcribes it with Parakeet, the most accurate model we tested, right on this Mac."
        case .microphone: "Driftflow uses this microphone for every dictation. You can change it any time from the menu bar."
        case .shortcut: "Hold it while you speak and let go to insert. Tap it once to keep listening hands-free; tap again to finish."
        case .aiModel: "Optional. An AI model on this Mac can tidy what you say into a style (Clean, Professional or Casual) and change selected text when you tell it how. It never sends anything anywhere."
        case .tryIt: "Click in the email below, hold your key and say a sentence. Filler words like “umm” are removed for you."
        case .done: "Driftflow lives in your menu bar. Here's how it's set up."
        }
    }

    var hint: String? {
        switch self {
        case .welcome: nil
        case .permissions: "Both switches are in System Settings › Privacy & Security."
        case .model: Platform.hasAppleSpeech
            ? "You can dictate right away; Apple's model fills in while Parakeet downloads."
            : "On this Mac, dictation needs this model on disk first; it runs fully offline after that."
        case .microphone: "Your mic works if the bars light up when you talk."
        case .shortcut: "Hold the key now: the caps light up."
        case .aiModel: "It downloads in the background, so carry on. Pick a style later in Settings › Styles."
        case .tryIt: "Try: “umm, can we move our call to Thursday at 3?”"
        case .done: nil
        }
    }
}

private struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    let done: () -> Void
    @AppStorage("onboardingStep") private var savedStep = 0
    @State private var step: OnboardingStep = .welcome
    @State private var microphone = Permissions.microphone
    @State private var tryText = ""
    private let poll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var permissionsGranted: Bool { microphone == .authorized && controller.accessibilityGranted }

    private var canContinue: Bool {
        switch step {
        case .permissions: permissionsGranted
        case .tryIt: !tryText.isEmpty
        default: true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PhaseBar(current: step.phase)
                    .padding(.bottom, 36)
                // The old step's words fade out before the new ones fade in, so the two titles
                // never show on top of each other.
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(OnboardingStep.phases[step.phase].uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(Color.accentColor)
                            .padding(.bottom, 8)
                        Text(step.title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .padding(.bottom, 10)
                        Text(step.subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let hint = step.hint {
                            Label(hint, systemImage: "lightbulb")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .padding(.top, 18)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(step)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.12)),
                                            removal: .opacity.animation(.easeIn(duration: 0.12))))
                }
                Spacer()
                HStack {
                    if step != .welcome, step != .done {
                        Button("Back") { go(step.previous) }
                            .glassButtonStyle()
                            .controlSize(.large)
                    }
                    Spacer()
                    if step == .tryIt, tryText.isEmpty {
                        Button("Skip") { go(.done) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    Button(step == .done ? "Start Dictating" : step == .welcome ? "Get Started" : "Continue") {
                        if step == .done { finish() } else { go(step.next) }
                    }
                    .glassProminentButtonStyle()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 32)
            .frame(width: 420)

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.background.secondary)
                    .overlay(
                        // A faint glow in the logo's two end colours, pink from the top, cyan from below.
                        ZStack {
                            RadialGradient(colors: [Brand.pink.opacity(0.10), .clear], center: .topTrailing, startRadius: 10, endRadius: 380)
                            RadialGradient(colors: [Brand.cyan.opacity(0.09), .clear], center: .bottomLeading, startRadius: 10, endRadius: 380)
                        }
                        .clipShape(.rect(cornerRadius: 24))
                    )
                card
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(step)
                    // A short slide within the panel (clipped below), never across the window.
                    .transition(.asymmetric(insertion: .offset(x: 48).combined(with: .opacity),
                                            removal: .offset(x: -48).combined(with: .opacity)))
            }
            .clipShape(.rect(cornerRadius: 24))
            .padding(20)
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 580, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
        .onAppear(perform: resume)
        .onReceive(poll) { _ in
            microphone = Permissions.microphone
            // A permission was revoked since: go back and fix it first.
            if step.rawValue > OnboardingStep.permissions.rawValue, !permissionsGranted { go(.permissions) }
        }
    }

    @ViewBuilder
    private var card: some View {
        switch step {
        case .welcome: WelcomeCard()
        case .permissions: permissionsCard
        case .model: ModelStep(controller: controller, settings: settings, models: .shared)
        case .microphone: MicrophoneCard(settings: settings)
        case .shortcut: ShortcutCard(controller: controller, settings: settings)
        case .aiModel: AIModelStep(settings: settings)
        case .tryIt: TryItCard(text: $tryText, settings: settings)
        case .done: SummaryCard(controller: controller, settings: settings)
        }
    }

    private var permissionsCard: some View {
        VStack(spacing: 12) {
            StepRow(number: 1, title: "Microphone", detail: "So Driftflow can hear you while you hold the key.",
                    done: microphone == .authorized) {
                Task {
                    if microphone == .notDetermined {
                        _ = await Permissions.requestMicrophone()
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                    microphone = Permissions.microphone
                }
            }
            StepRow(number: 2, title: "Accessibility", detail: "To notice the dictation key and type into other apps.",
                    done: controller.accessibilityGranted) {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
            if permissionsGranted {
                Label { Text("Both granted") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.gradient) }
                    .padding(.top, 6)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: permissionsGranted)
    }

    private func resume() {
        let saved = OnboardingStep(rawValue: savedStep) ?? .welcome
        step = saved.rawValue > OnboardingStep.permissions.rawValue && !permissionsGranted ? .permissions : saved
    }

    private func go(_ next: OnboardingStep) {
        step = next
        savedStep = next.rawValue
    }

    private func finish() {
        savedStep = OnboardingStep.done.rawValue
        done()
    }
}

/// Five named phases instead of "step 3 of 7".
/// The logo's gradient runs once across the whole bar, and the finished phases reveal it.
private struct PhaseBar: View {
    let current: Int

    var body: some View {
        segments { _ in AnyShapeStyle(.quaternary) }
            .overlay {
                LinearGradient(colors: [Brand.pink, Brand.violet, Brand.cyan], startPoint: .leading, endPoint: .trailing)
                    .mask(segments { index in AnyShapeStyle(index <= current ? Color.black : Color.clear) })
            }
            .animation(.easeInOut(duration: 0.3), value: current)
    }

    private func segments(_ style: @escaping (Int) -> AnyShapeStyle) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<OnboardingStep.phases.count, id: \.self) { index in
                Capsule().fill(style(index)).frame(height: 5)
            }
        }
    }
}

private struct WelcomeCard: View {
    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Brand.appIcon(points: 110)
                .resizable()
                .interpolation(.high)
                .frame(width: 110, height: 110)
                .shadow(color: Brand.violet.opacity(0.35), radius: 24, y: 8)
            VStack(alignment: .leading, spacing: 16) {
                feature("lock.shield", "Private", "Speech is transcribed on this Mac. Nothing is uploaded.")
                feature("bolt", "Fast", "Text appears about 50 ms after you let go.")
                feature("text.cursor", "Everywhere", "Mail, Slack, Notes, your code editor: any app with a text field.")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A picker and a live 12-bar meter (its own short-lived capture, not a dictation).
private struct MicrophoneCard: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var devices = AudioDevices.shared
    @State private var meter = MeterCapture()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Microphone", selection: $settings.inputDeviceUID) {
                Text("System default (\(devices.defaultInputName))").tag("")
                ForEach(devices.inputs) { Text($0.name).tag($0.uid) }
            }
            TimelineView(.animation) { _ in
                let level = meter.level
                HStack(alignment: .center, spacing: 6) {
                    ForEach(0..<12, id: \.self) { index in
                        let lit = Double(index) / 12 < level
                        RoundedRectangle(cornerRadius: 3)
                            .fill(lit ? AnyShapeStyle(LinearGradient(colors: [Brand.pink, Brand.violet, Brand.cyan],
                                                                     startPoint: .leading, endPoint: .trailing))
                                      : AnyShapeStyle(.quaternary))
                            .frame(height: 16 + CGFloat(index) * 3)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            }
            Text(meter.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .onAppear { meter.start(uid: settings.inputDeviceUID) }
        .onChange(of: settings.inputDeviceUID) { _, uid in meter.start(uid: uid) }
        .onDisappear { meter.stop() }
        // The window is kept when closed, so SwiftUI may not report a disappearance: make sure the
        // microphone goes off on close, and comes back if the window reopens on this step.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow) === DictationController.shared.onboardingWindow { meter.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === DictationController.shared.onboardingWindow, !meter.isRunning {
                meter.start(uid: settings.inputDeviceUID)
            }
        }
    }
}

/// Mic level for the onboarding meter.
@MainActor
@Observable
private final class MeterCapture {
    private var capture: AudioCapture?
    private let pipe = AudioPipe()
    private let store = LevelBox()
    var status = "Say something…"

    var level: Double { Double(store.value) }
    var isRunning: Bool { capture != nil }

    func start(uid: String) {
        stop()
        let capture = AudioCapture()
        capture.preferredDeviceUIDs = [uid]
        let store = self.store
        capture.onLevel = { store.push($0) }
        pipe.attach { _ in }
        do {
            try capture.beginRecording(into: pipe, includePreroll: false)
            self.capture = capture
            status = "Say something…"
        } catch {
            status = "Couldn't open this microphone: \(error.localizedDescription)"
        }
    }

    func stop() {
        capture?.endRecording()
        capture?.cool()
        capture = nil
        pipe.reset()
    }
}

private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Float = 0
    func push(_ level: Float) {
        lock.lock()
        current = level > current ? level : current * 0.85 + level * 0.15
        lock.unlock()
    }
    var value: Float {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

private struct ShortcutCard: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            KeyCaps(capLabels, lit: controller.triggerHeld, scale: 2.2)
                .frame(height: 70)
            Text(controller.triggerHeld ? "Got it. Let go to finish." : "Hold \(settings.trigger.label)")
                .font(.headline)
                .foregroundStyle(controller.triggerHeld ? Color.accentColor : .primary)
            Picker("Dictation key", selection: $settings.trigger) {
                ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
            }
            .frame(maxWidth: 320)
            Toggle("A quick tap keeps listening hands-free", isOn: $settings.tapForHandsFree)
            Spacer()
        }
    }

    private var capLabels: [String] {
        switch settings.trigger {
        case .rightCommand: ["Right ⌘"]
        case .rightOption: ["Right ⌥"]
        case .fn: ["fn 🌐"]
        case .optionSpace: ["⌥", "Space"]
        case .controlOptionSpace: ["⌃", "⌥", "Space"]
        }
    }
}

/// A mock email to dictate into, like a real app would be.
private struct TryItCard: View {
    @Binding var text: String
    @ObservedObject var settings: AppSettings
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 10, height: 10) }
                Spacer()
                Text("New Message").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            Divider()
            Group {
                row("To:", "Sam Rivera")
                row("Subject:", "Our call")
            }
            TextField("", text: $text, prompt: Text("Hold \(settings.trigger.label) and speak…"), axis: .vertical)
                .lineLimit(6, reservesSpace: true)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(14)
                .focused($focused)
            if !text.isEmpty {
                Label { Text("It works") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.gradient) }
                    .padding([.horizontal, .bottom], 14)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .frame(maxHeight: .infinity, alignment: .center)
        .onAppear { focused = true }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: text.isEmpty)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Text(value)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
        }
    }
}

private struct SummaryCard: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject private var devices = AudioDevices.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            summary("cpu", "Model", controller.activeModel)
            summary("sparkles", "AI model", AIRewriter.shared.activeModel.map { "\($0.displayName)\($0 == settings.textModel ? "" : " (until \(settings.textModel.displayName) downloads)")" }
                    ?? (TextModelManager.shared.status(of: settings.textModel) == .notDownloaded ? "None (add one in Settings › AI Model)" : "\(settings.textModel.displayName), downloading"))
            summary("keyboard", "Dictation key", "Hold \(settings.trigger.label)\(settings.tapForHandsFree ? " · tap for hands-free" : "")")
            summary("mic", "Microphone", devices.inputs.first { $0.uid == settings.inputDeviceUID }?.name ?? "System default (\(devices.defaultInputName))")
            if let paste = settings.pasteLastShortcut {
                summary("arrow.uturn.backward", "Paste last dictation", paste.display)
            }
            LaunchAtLoginToggle()
                .toggleStyle(.switch)
                .padding(.horizontal, 14)
            Spacer()
            Text("Change any of this later in Settings (⌘,) or from the menu bar icon.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: .rect(cornerRadius: 14))
    }
}

/// Step 3: which language, and whether the speech model is ready. Parakeet downloads on its own
/// at first launch; until it's done Apple's built-in model writes the text on macOS 26 (on macOS 15
/// dictation waits for it).
struct ModelStep: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelManager
    @State private var catalog: SpeechCatalog?

    private var usesParakeet: Bool {
        settings.accuracyModel != .apple && settings.accuracyModel.supports(language: settings.language)
    }
    private var done: Bool { Platform.hasAppleSpeech ? !usesParakeet || controller.accuracyReady : usesParakeet && controller.accuracyReady }
    private var languageName: String { Locale.current.localizedString(forLanguageCode: settings.language) ?? settings.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(done ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.accentColor))
                Text(status).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if usesParakeet, !controller.accuracyReady, controller.accuracyProgress == nil {
                    Button(models.isDownloaded(settings.accuracyModel) ? "Load" : "Download") { controller.retryModelLoad() }
                        .glassButtonStyle()
                }
            }
            if let progress = controller.accuracyProgress ?? controller.downloadProgress, progress < 1,
               !(controller.downloadProgress == nil && models.isDownloaded(settings.accuracyModel)) {
                ProgressView(value: progress)
                    .animation(.smooth, value: progress)
            }
            HStack(spacing: 12) {
                Picker("Language", selection: $settings.language) {
                    ForEach(languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                }
                .onChange(of: settings.language) {
                    settings.accent = ""
                    controller.matchModelToLanguage()
                }
                if let catalog, catalog.regions(for: settings.language).count > 1 {
                    Picker("Accent", selection: $settings.accent) {
                        let auto = catalog.automaticRegion(for: settings.language)
                        Text("Match my Mac\(auto.map { " (\(Self.regionName($0)))" } ?? "")").tag("")
                        Divider()
                        ForEach(catalog.regions(for: settings.language), id: \.self) { Text(Self.regionName($0)).tag($0) }
                    }
                }
            }
            .controlSize(.small)
            Text(!Platform.hasAppleSpeech
                 ? "\(settings.accuracyModel.displayName) understands every accent of \(languageName) with one model, so there's no accent to choose."
                 : usesParakeet
                 ? "The accent doesn't change the final text: \(settings.accuracyModel.displayName) understands every English accent with one model. It only tunes Apple Speech, used for languages \(settings.accuracyModel.displayName) doesn't cover. Leave it on “Match my Mac”."
                 : "The accent picks Apple's regional model for \(languageName). Choose the one closest to how you speak.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: done)
        .task { catalog = await SpeechCatalog.current() }
    }

    private var status: String {
        guard usesParakeet else {
            return Platform.hasAppleSpeech
                ? "\(languageName) uses Apple Speech, built into macOS. Nothing to download from us."
                : "\(languageName) isn't supported on this Mac. Parakeet speaks English and 24 European languages."
        }
        let waitNote = Platform.hasAppleSpeech ? "You can dictate already: Apple's built-in model fills in until it's done." : "Dictation starts working when it's done."
        let name = settings.accuracyModel.displayName
        if controller.accuracyReady { return "\(name) is ready: the most accurate English model, running on this Mac." }
        if controller.accuracyProgress != nil, models.isDownloaded(settings.accuracyModel) {
            return "Loading \(name) onto the Neural Engine… a few seconds."
        }
        if let progress = controller.accuracyProgress {
            return "Downloading \(name) (\(settings.accuracyModel.downloadSize)), \(Int(progress * 100))%. \(waitNote)"
        }
        if case .failed(let message) = models.status(of: settings.accuracyModel) { return "Download failed: \(message)" }
        return Platform.hasAppleSpeech
            ? "\(name) (\(settings.accuracyModel.downloadSize)) gives the most accurate English. Until it's ready, Apple's built-in model writes the text."
            : "\(name) (\(settings.accuracyModel.downloadSize)) is the speech model Driftflow uses on this Mac. Download it to start dictating."
    }

    private var languages: [String] {
        guard let catalog else { return Self.sortedByName(Platform.parakeetLanguages) }
        let mac = Locale.current.language.languageCode?.identifier
        return catalog.languages.sorted { a, b in
            if a == mac { return true }
            if b == mac { return false }
            return (Locale.current.localizedString(forLanguageCode: a) ?? a)
                .localizedCaseInsensitiveCompare(Locale.current.localizedString(forLanguageCode: b) ?? b) == .orderedAscending
        }
    }

    /// By name, the Mac's language first.
    static func sortedByName(_ codes: [String]) -> [String] {
        let mac = Locale.current.language.languageCode?.identifier
        return codes.sorted { a, b in
            if a == mac { return true }
            if b == mac { return false }
            return (Locale.current.localizedString(forLanguageCode: a) ?? a)
                .localizedCaseInsensitiveCompare(Locale.current.localizedString(forLanguageCode: b) ?? b) == .orderedAscending
        }
    }

    private static func regionName(_ region: String) -> String {
        Locale.current.localizedString(forRegionCode: region) ?? region
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary.opacity(0.18)))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !done {
                Button("Allow", action: action)
                    .glassButtonStyle()
            }
        }
        .padding(14)
        .glassSurface(in: .rect(cornerRadius: 14))
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: done)
    }
}

/// The AI model step: Qwen (or Apple's model on a Mac with 8 GB) is preselected; downloading is
/// optional and happens in the background.
private struct AIModelStep: View {
    @ObservedObject var settings: AppSettings
    /// The download button and progress under the list (the What's New window has its own button).
    var showsStatus = true
    @ObservedObject private var models = TextModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // What you'd get: real results from Qwen in our tests.
            HStack(alignment: .top, spacing: 10) {
                AIExampleCard(title: "Styles", detail: "Professional",
                              before: "yeah that's gonna be kinda tricky cause the client wants like everything done by friday",
                              after: "That will be quite tricky, as the client requires everything to be completed by Friday.")
                AIExampleCard(title: "Edit by voice", detail: "\(settings.editShortcut?.display ?? "⌃⌥E") · “make it more formal”",
                              before: "hey, can u send me the report asap? need it for the meeting tmrw. thx",
                              after: "Hello, could you please send me the report as soon as possible? I need it for the meeting tomorrow. Thank you.")
            }
            .fixedSize(horizontal: false, vertical: true) // the cards' own height, not the whole panel
            .padding(.bottom, 4)
            ForEach(TextModel.allCases) { model in
                Button { withAnimation(.snappy) { settings.textModel = model } } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: settings.textModel == model ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(settings.textModel == model ? Color.accentColor : Color.secondary.opacity(0.5))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(model.displayName).font(.headline)
                                Text(model.badge).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(tagline(model)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(.rect)
                    .glassSurface(in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if showsStatus {
                HStack(spacing: 10) {
                    statusView
                    Spacer()
                }
                .padding(.top, 6)
            }
            if !TextModel.hasComfortableMemory {
                Text("This Mac has \(ProcessInfo.processInfo.physicalMemory >> 30) GB of memory: Qwen and Gemma use about 3 GB while they work, which can slow other apps. Apple Intelligence needs none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.snappy, value: models.status(of: settings.textModel))
    }

    private func tagline(_ model: TextModel) -> String {
        switch model {
        case .qwen: "The most careful with your words. \(model.downloadSize), about \(model.typicalSeconds.formatted()) s a sentence."
        case .gemma: "The fastest, a little less careful. \(model.downloadSize), about \(model.typicalSeconds.formatted()) s a sentence."
        case .apple: TextModel.appleModelUsable ? "Built into macOS. Nothing to download; less reliable with long dictations."
                                                : "Not available on this Mac: \(AIRewriter.appleUnavailableReason)"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        let model = settings.textModel
        switch models.status(of: model) {
        case .downloading(let progress):
            if models.downloadingElsewhere.contains(model) {
                ProgressView().controlSize(.small)
                Text("\(TextModelManager.otherApp ?? "Another app") is downloading it; Driftflow will use the same file.").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView(value: progress).frame(width: 160)
                Text(progress >= 1 ? "Checking…" : "Downloading, \(Int(progress * 100))%").font(.callout).foregroundStyle(.secondary)
            }
        case .notDownloaded, .failed:
            Button("Download \(model.displayName) (\(model.downloadSize))") { models.download(model) }
                .glassButtonStyle()
            if case .failed(let message) = models.status(of: model) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        case .downloaded:
            if model == .apple, !TextModel.appleModelUsable {
                Label("Pick Qwen or Gemma to use AI writing on this Mac.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            } else {
                Label("\(model.displayName) is ready", systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).foregroundStyle(.green)
            }
        }
    }
}

/// One "you said → it wrote" example on the AI writing step.
private struct AIExampleCard: View {
    let title: String
    let detail: String
    let before: String
    let after: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").foregroundStyle(Brand.gradient)
                Text(title).font(.caption.weight(.semibold))
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary)
            Text("“\(before)”")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(after)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) // as tall as the taller card
        .glassSurface(in: .rect(cornerRadius: 12))
    }
}

// MARK: - What's new

/// Once after an update, for people who set up Driftflow before it had its own AI models: what the
/// AI model does, and the choice to download one or not. New installs see the same in setup.
@MainActor
final class WhatsNewWindow {
    static let shared = WhatsNewWindow()
    private(set) var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "What's New in Driftflow"
        let toolbar = NSToolbar(identifier: "whatsNew")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WhatsNewView(settings: .shared) { [weak self] in self?.close() })
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
        window = nil
    }
}

private struct WhatsNewView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var models = TextModelManager.shared
    let done: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("NEW IN DRIFTFLOW")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 8)
                Text("AI writing, on your Mac")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .padding(.bottom, 10)
                Text("Driftflow now has its own AI model. It tidies what you say into a style (Clean, Professional or Casual) and changes selected text when you tell it how, and it's more careful with your words than Apple Intelligence. It's a one-time download; until then, nothing changes.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("It runs on this Mac: nothing you say leaves it. Change it any time in Settings › AI Model.", systemImage: "lock.shield")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack {
                    Button("Not Now", action: done)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(primaryTitle, action: primary)
                        .glassProminentButtonStyle()
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 32)
            .frame(width: 400)

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.background.secondary)
                    .overlay(
                        ZStack {
                            RadialGradient(colors: [Brand.pink.opacity(0.10), .clear], center: .topTrailing, startRadius: 10, endRadius: 380)
                            RadialGradient(colors: [Brand.cyan.opacity(0.09), .clear], center: .bottomLeading, startRadius: 10, endRadius: 380)
                        }
                        .clipShape(.rect(cornerRadius: 24))
                    )
                AIModelStep(settings: settings, showsStatus: false)
                    .padding(28)
            }
            .clipShape(.rect(cornerRadius: 24))
            .padding(20)
        }
        .frame(width: 880, height: 560)
    }

    private var primaryTitle: String {
        let model = settings.textModel
        if model.needsDownload {
            if case .downloading = models.status(of: model) { return "Done" }
            return models.isDownloaded(model) ? "Use \(model.displayName)" : "Download \(model.displayName) (\(model.downloadSize))"
        }
        return TextModel.appleModelUsable ? "Use Apple Intelligence" : "Done"
    }

    private func primary() {
        let model = settings.textModel
        switch models.status(of: model) {
        case .notDownloaded, .failed:
            models.download(model)
            DictationController.shared.showToast(
                HUDToast(icon: "arrow.down.circle", text: "Downloading \(model.displayName) in the background. It takes over when it's ready."), for: 5)
        case .downloading, .downloaded:
            break
        }
        done()
    }
}
