import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Which section of the main window is showing, so the menu can open it at History, Files or Models.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var pane: SettingsView.Pane? = .general
}

struct SettingsView: View {
    // Not observed here: the controller changes many times a second while you dictate, and the
    // whole window redrew with it. Each section observes what it shows.
    let controller: DictationController
    let settings: AppSettings
    @ObservedObject private var router = SettingsRouter.shared

    enum Pane: String, CaseIterable, Identifiable {
        /// Your dictations and transcribed files, above the settings.
        case history, stacks, files
        case general, shortcuts, models, output, styles, vocabulary, permissions

        static let content: [Pane] = [.history, .stacks, .files]
        static let settings: [Pane] = [.general, .shortcuts, .models, .output, .styles, .vocabulary, .permissions]

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .models: "Models"
            case .output: "Output"
            case .styles: "Styles"
            case .vocabulary: "Vocabulary"
            case .history: "History"
            case .files: "Files"
            case .stacks: "Stacks"
            case .permissions: "Permissions"
            }
        }

        /// One line under the page title.
        var subtitle: String {
            switch self {
            case .general: "Microphone, sounds and the on-screen pill"
            case .shortcuts: "Keys for dictation, hands-free and paste-last"
            case .models: "Which speech models write your words, and your language"
            case .output: "How text is cleaned up and inserted"
            case .styles: "On-device AI rewriting, and rules for each app or website"
            case .vocabulary: "Names, jargon, replacements and snippets"
            case .history: "Everything you've dictated, kept on this Mac"
            case .files: "Transcripts of audio and video files, made on this Mac"
            case .stacks: "Your stacks of dictations, and which one is in use"
            case .permissions: "What Driftflow needs, and why"
            }
        }

        var icon: String {
            switch self {
            case .general: "switch.2"
            case .shortcuts: "keyboard"
            case .models: "cpu"
            case .output: "text.cursor"
            case .styles: "wand.and.sparkles"
            case .vocabulary: "character.book.closed"
            case .history: "clock.arrow.circlepath"
            case .files: "waveform"
            case .stacks: "rectangle.stack"
            case .permissions: "lock.shield"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $router.pane) {
                Section {
                    ForEach(Pane.content) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                Section("Settings") {
                    ForEach(Pane.settings) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Group {
                switch router.pane ?? .general {
                case .general: GeneralPane(controller: controller, settings: settings)
                case .shortcuts: ShortcutsPane(controller: controller, settings: settings)
                case .models: ModelsPane(controller: controller, settings: settings)
                case .output: OutputPane(settings: settings)
                case .styles: StylesPane(settings: settings)
                case .vocabulary: VocabularyPane(settings: settings)
                case .history: HistoryPane(settings: settings)
                case .files: FilesPane()
                case .stacks: StacksPane()
                case .permissions: PermissionsPane(controller: controller)
                }
            }
            .formStyle(.grouped)
            .navigationTitle((router.pane ?? .general).title)
            .navigationSubtitle((router.pane ?? .general).subtitle)
        }
        // Files and Stacks have a list and a detail side by side, so the window widens for them.
        .frame(minWidth: router.pane == .files || router.pane == .stacks ? 950 : 780, idealWidth: 780, minHeight: 600, idealHeight: 600)
        .background(StandardWindowButtons())
    }
}

/// Gives the window it's placed in working minimise and zoom buttons (SwiftUI's Settings window
/// comes without them) and a unified toolbar. SwiftUI gives Settings windows the old
/// preferences-style toolbar, which on macOS 26 leaves the window buttons on the corner, over the
/// sidebar's edge, instead of inside the sidebar like System Settings.
private struct StandardWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert([.miniaturizable, .resizable])
            window.toolbarStyle = .unified
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct GeneralPane: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject private var devices = AudioDevices.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    StatTile(value: controller.lastLatencyMs.map { "\($0) ms" } ?? "–", caption: "Release → text")
                    StatTile(value: "\(HistoryStore.shared.todayCount)", caption: "Dictations today")
                    StatTile(value: "On-device", caption: controller.activeModel)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            MicPrioritySection(settings: settings, devices: devices)

            Section {
                Picker("Keep microphone ready", selection: $settings.micMode) {
                    ForEach(MicMode.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A warm microphone starts instantly and keeps the half-second before you pressed the key, so your first word is never clipped. macOS shows the mic indicator while it's warm.")
                    if let ms = controller.lastMicColdStartMs {
                        Text("Your microphone's last cold start took \(ms) ms. Recording begins on key-down either way; this is how long until the first sound arrives.")
                    }
                }
                .foregroundStyle(.secondary)
            }

            Section {
                LaunchAtLoginToggle()
                Toggle("Show in Dock and app switcher", isOn: $settings.showInDock)
            } header: {
                Text("App")
            } footer: {
                Text("macOS keeps the Dock and ⌘-Tab together: an app appears in both or in neither. When hidden, Driftflow lives in the menu bar only.")
                    .foregroundStyle(.secondary)
            }

            UpdatesSection()

            Section {
                LabeledContent("Log") {
                    HStack {
                        Button("Copy Log") { AppLog.copyToClipboard() }
                        Button("Save Report…") { AppLog.saveReport() }
                        Button("Show in Finder") { AppLog.showInFinder() }
                    }
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("If something goes wrong, Copy Log and paste it into your message (also in the menu bar menu): it includes past sessions and any recent crash reports. Save Report… writes everything to a file. The log records what Driftflow did, never what you dictated.")
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle("Show live transcript", isOn: $settings.showHUD)
                Picker("Position", selection: $settings.hudPosition) {
                    ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.showHUD)
                Toggle("Keep a small pill on screen between dictations", isOn: $settings.showIdlePill)
                    .help("Hover it to see your dictation key; click it to start hands-free.")
                Toggle("Play start and stop sounds", isOn: $settings.playSounds)
                Toggle("Lower other audio while dictating", isOn: $settings.duckAudio)
                    .help("Music and videos drop to 30% volume while you speak and come back when you finish.")
            }

            Section {
                Toggle("Stack Mode: keep every dictation in the stack instead of pasting it",
                       isOn: Binding(get: { settings.stackMode }, set: { if $0 != settings.stackMode { controller.toggleStackMode() } }))
                Picker("Show the stack", selection: $settings.stackTab) {
                    ForEach(StackTabStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Paste puts in", selection: $settings.stackPaste) {
                    ForEach(StackPasteChoice.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Stack")
            } footer: {
                Text("Dictations you add with the stack button on the pill, every dictation in Stack Mode, and any that had no text box to go into wait at the bottom right of the screen, in order, until you use them. Point at the stack's tab to see them: click one to paste it, drag it into a text box, or pin it to keep it after pasting. Click the tab to turn Stack Mode on or off, drag it to drop the whole stack, or right-click it to hide it. When the stack is empty and Stack Mode is off, the tab fades away; Open Stack or Stack Mode in the menu bar menu brings it back.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(SoundStyle.allCases) { style in
                    HStack(spacing: 12) {
                        Image(systemName: settings.soundStyle == style ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(settings.soundStyle == style ? Color.accentColor : Color.secondary.opacity(0.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.name)
                            Text(style.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            controller.sounds.preview(style)
                        } label: {
                            Label("Preview", systemImage: "play.fill")
                                .labelStyle(.iconOnly)
                        }
                        .glassButtonStyle()
                        .help("Hear the start and stop sounds")
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.snappy) { settings.soundStyle = style }
                        controller.sounds.preview(style)
                    }
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Click a sound to hear it and choose it. Each plays a start sound and then a stop sound.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.playSounds)
        }
    }
}

private struct StatTile: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassSurface(in: .rect(cornerRadius: 14))
    }
}

private struct ModelsPane: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject private var models = ModelManager.shared
    @State private var catalog: SpeechCatalog?
    @State private var pendingDelete: AccuracyModel?

    private var languageCode: String? { settings.language }

    private var languageName: String {
        Locale.current.localizedString(forLanguageCode: settings.language) ?? settings.language
    }

    private func regionName(_ region: String) -> String {
        Locale.current.localizedString(forRegionCode: region) ?? region
    }

    /// Languages sorted by name, the Mac's language first.
    private var languageOptions: [String] {
        guard let catalog else { return Platform.hasAppleSpeech ? [settings.language] : ModelStep.sortedByName(Platform.parakeetLanguages) }
        let mac = Locale.current.language.languageCode?.identifier
        return catalog.languages.sorted { a, b in
            if a == mac { return true }
            if b == mac { return false }
            return (Locale.current.localizedString(forLanguageCode: a) ?? a)
                .localizedCaseInsensitiveCompare(Locale.current.localizedString(forLanguageCode: b) ?? b) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    RoleTile(icon: "waveform", title: "While you speak",
                             detail: previewFromModel
                                 ? "\(effectiveModel.displayName) shows your words live, exactly as they'll be typed."
                                 : "Apple Speech shows your words live. Built in, instant, light on battery.")
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    RoleTile(icon: "text.cursor", title: "When you release",
                             detail: "\(effectiveModel.displayName) writes the final text that gets typed.")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Picker("Language", selection: $settings.language) {
                    ForEach(languageOptions, id: \.self) { code in
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
                        Text("Match my Mac\(auto.map { " (\(regionName($0)))" } ?? "")").tag("")
                        Divider()
                        ForEach(catalog.regions(for: settings.language), id: \.self) { region in
                            Text(regionName(region)).tag(region)
                        }
                    }
                }
                if !Platform.hasAppleSpeech, !settings.accuracyModel.supports(language: languageCode) {
                    Label("\(settings.accuracyModel.displayName) doesn't support \(languageName)\(AccuracyModel.parakeetV3.supports(language: languageCode) ? ". Select Parakeet TDT v3 below." : ".")",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if settings.accuracyModel != .apple, !settings.accuracyModel.supports(language: languageCode) {
                    Label("\(settings.accuracyModel.displayName) doesn't support \(languageName), so Apple Speech writes the final text\(AccuracyModel.parakeetV3.supports(language: languageCode) ? ". Parakeet TDT v3 supports it." : ".")",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Language")
            } footer: {
                Text(!Platform.hasAppleSpeech
                     ? "\(settings.accuracyModel.displayName) understands every accent of a language with one model. Languages other than English need Parakeet TDT v3."
                     : settings.accuracyModel.supports(language: languageCode) && settings.accuracyModel != .apple
                     ? "\(settings.accuracyModel.displayName) understands all English accents with one model; the accent only tunes Apple Speech (other languages, or Apple's live preview under Advanced)."
                     : "The accent picks Apple's regional model for this language.")
                    .foregroundStyle(.secondary)
            }


            Section {
                ForEach(AccuracyModel.allCases.filter { $0 != .apple || Platform.hasAppleSpeech }) { model in
                    ModelRow(model: model,
                             selected: settings.accuracyModel == model,
                             status: models.status(of: model),
                             loaded: settings.accuracyModel == model && (controller.accuracyReady || model == .apple),
                             select: { select(model) },
                             download: { models.download(model) },
                             cancel: { models.cancelDownload(model) },
                             delete: { pendingDelete = model })
                }
            } header: {
                Text("Final-text model")
            } footer: {
                Text("Accuracy is the share of words transcribed correctly, and speed is the time to turn a typical dictation into text, both measured on this Mac with 300 recorded English sentences (5,603 words), clean and noisy. Also tested and left out: Nemotron Streaming (96.1% accurate, slowest to show text) and Parakeet Ultra (97.0%, no gain over Unified).")
                    .foregroundStyle(.secondary)
            }

            if Platform.hasAppleSpeech {
            Section {
                Picker("Live preview", selection: $settings.livePreview) {
                    Text("Same as final-text model").tag(LivePreviewSource.finalModel)
                    Text("Apple Speech").tag(LivePreviewSource.apple)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Same as final-text model (default): the preview comes from the NVIDIA model that writes the final text, so what you see is exactly what gets typed. It updates about 3 times a second and uses about 13% of one CPU core while you talk. Apple Speech: lighter on battery (about 1–2%), but the text may change slightly when the final model takes over. Languages the final model doesn't cover always preview with Apple Speech.")
                    .foregroundStyle(.secondary)
            }
            }
        }
        .task { catalog = await SpeechCatalog.current() }
        .onAppear { models.refresh() }
        .confirmationDialog("Delete \(pendingDelete?.displayName ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let model = pendingDelete { models.delete(model) }
                pendingDelete = nil
            }
        } message: {
            Text("Frees \(pendingDelete?.downloadSize ?? "") of disk space. You can download it again any time."
                 + (pendingDelete.map(ModelManager.isShared) == true
                    ? " This download is shared with other apps built on FluidAudio, such as FluidVoice: they'd need to download it again." : ""))
        }
    }

    private var previewFromModel: Bool {
        (settings.livePreview == .finalModel || !Platform.hasAppleSpeech) && effectiveModel != .apple
    }

    /// The model that will actually write the final text for the chosen language.
    private var effectiveModel: AccuracyModel {
        settings.accuracyModel.supports(language: languageCode) ? settings.accuracyModel : .apple
    }

    private func select(_ model: AccuracyModel) {
        if !models.isDownloaded(model) { models.download(model) }
        withAnimation(.snappy) { settings.accuracyModel = model }
    }
}

private struct RoleTile: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassSurface(in: .rect(cornerRadius: 14))
    }
}

private struct ModelRow: View {
    let model: AccuracyModel
    let selected: Bool
    let status: ModelManager.Status
    let loaded: Bool
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.displayName).font(.headline)
                    Text(model.badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.18), in: .capsule)
                        .foregroundStyle(badgeColor)
                }
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Stat(icon: "target", text: String(format: "%.1f%% accurate", model.accuracy))
                    Stat(icon: "bolt.fill", text: "\(model.medianMilliseconds) ms to text")
                    Stat(icon: "globe", text: model.languagesLabel)
                    Stat(icon: "internaldrive", text: model.downloadSize)
                }
            }

            Spacer(minLength: 8)
            trailing
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { if !selected { select() } }
        .animation(.snappy, value: status)
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("\(Int(progress * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel download")
            }
        case .notDownloaded, .failed:
            VStack(alignment: .trailing, spacing: 2) {
                Button("Download", action: download)
                    .glassButtonStyle()
                if case .failed(let message) = status {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
        case .downloaded:
            if selected {
                Label(loaded ? "In use" : "Loading…", systemImage: loaded ? "checkmark.seal.fill" : "hourglass")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(loaded ? Color.green : Color.secondary)
            } else {
                HStack(spacing: 6) {
                    Button("Use", action: select)
                        .glassButtonStyle()
                    if model.needsDownload {
                        Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Delete from disk")
                    }
                }
            }
        }
    }

    private var badgeColor: Color {
        switch model {
        case .parakeetUnified: .green
        case .parakeetV2: .orange
        case .parakeetV3: .blue
        case .apple: .gray
        }
    }
}

private struct Stat: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

private struct OutputPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Insert into the active app", isOn: $settings.autoPaste)
            } footer: {
                Text("When off, your text is copied to the clipboard instead.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Smart spacing", isOn: $settings.smartSpacing)
                Toggle("Remove filler words (um, uh…)", isOn: $settings.removeFillers)
                Toggle("Voice commands", isOn: $settings.spokenCommands)
            } header: {
                Text("Cleanup")
            } footer: {
                Text("Say “new line” or “new paragraph” to break lines. Say “scratch that” to delete the sentence you just said, or, at the start of a dictation, to remove your previous dictation from the app.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Method", selection: $settings.insertionMethod) {
                    ForEach(InsertionMethod.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.autoPaste)
                Toggle("Restore the clipboard afterwards", isOn: $settings.restoreClipboard)
                    .disabled(!settings.autoPaste || settings.insertionMethod == .type)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Paste restores your clipboard the moment the app has read the text. Use “Type characters” for apps that mangle pastes.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShortcutsPane: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $settings.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Quick tap starts hands-free mode", isOn: $settings.tapForHandsFree)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hold the key while you speak and release to insert. A quick tap keeps listening until you tap again. Esc cancels.")
                    if settings.trigger == .fn {
                        Text("For Fn, set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”.")
                    }
                }
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Hands-free on/off") {
                    ShortcutRecorder(combo: $settings.handsFreeShortcut, placeholder: "Not set", action: .handsFree,
                                     taken: [(settings.pasteLastShortcut, "Paste last dictation"), (settings.editShortcut, "Edit selection by voice")])
                }
                LabeledContent("Paste last dictation") {
                    ShortcutRecorder(combo: $settings.pasteLastShortcut, placeholder: "Not set", action: .pasteLast,
                                     taken: [(settings.handsFreeShortcut, "Hands-free on/off"), (settings.editShortcut, "Edit selection by voice")])
                }
                LabeledContent("Edit selection by voice") {
                    ShortcutRecorder(combo: $settings.editShortcut, placeholder: "Not set", action: .editSelection,
                                     taken: [(settings.handsFreeShortcut, "Hands-free on/off"), (settings.pasteLastShortcut, "Paste last dictation")])
                }
                LabeledContent("Cancel dictation") {
                    KeyCaps(["⎋"]).opacity(0.8)
                }
                LabeledContent("Dictate into the stack") {
                    if let modifier = controller.stackModifier {
                        KeyCaps([settings.trigger.shortLabel, modifier == .command ? "⌘" : "⌥"]).opacity(0.8)
                    } else {
                        Text("Needs a single-key dictation key").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("More shortcuts")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hands-free on/off starts listening with one press and finishes with the next, no holding. Paste last dictation types your most recent dictation again at the cursor, handy when it landed in the wrong place. Esc cancels while listening.")
                    Text("Dictate into the stack: hold \(controller.stackModifier == .command ? "⌘ Command" : "⌥ Option") together with your dictation key (before or while you speak) and that dictation goes into your stack instead of being pasted.")
                    Text("Edit selection by voice: select some text, press the shortcut, say what to change (“make this shorter”, “turn this into bullet points”, “fix the grammar”) and press it again. The selection is replaced. Uses Apple Intelligence on this Mac.")
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows a shortcut as key caps; click to record a new one, ⌫ to clear, ⎋ to cancel.
private struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    let placeholder: String
    let action: GlobalShortcuts.Action
    /// Driftflow's other shortcuts, so two can't share keys (one would silently never fire).
    let taken: [(KeyCombo?, String)]
    @ObservedObject private var shortcuts = GlobalShortcuts.shared
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Group {
                        if recording {
                            Text("Press keys…").foregroundStyle(Color.accentColor)
                        } else if let combo {
                            KeyCaps(combo.symbols)
                        } else {
                            Text(placeholder).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 110, minHeight: 24)
                }
                .glassButtonStyle()
                .help(recording ? "Press the new shortcut; ⎋ cancels, ⌫ clears" : "Click to record a new shortcut")
                if combo != nil, !recording {
                    Button { combo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Remove this shortcut")
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if combo != nil, shortcuts.unavailable.contains(action) {
                Text("Another app already uses this shortcut. Pick another.").font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                combo = nil
                stop()
            default:
                guard let new = KeyCombo(event: event) else { return nil }
                if let issue = new.problem {
                    problem = issue
                } else if let owner = taken.first(where: { $0.0 == new })?.1 {
                    problem = "\(new.display) is already used for \(owner)."
                } else {
                    combo = new
                    stop()
                }
            }
            return nil // swallow while recording
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Keys drawn as little caps, e.g. ⌃ ⌥ V.
struct KeyCaps: View {
    let keys: [String]
    var lit = false

    init(_ keys: [String], lit: Bool = false) {
        self.keys = keys
        self.lit = lit
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, key.count > 1 ? 6 : 0)
                    .background(lit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                in: .rect(cornerRadius: 6))
                    .foregroundStyle(lit ? .white : .primary)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(lit ? 0.35 : 0.08)))
                    .shadow(color: lit ? Color.accentColor.opacity(0.45) : .clear, radius: 6)
            }
        }
        .animation(.easeOut(duration: 0.12), value: lit)
    }
}

private struct VocabularyPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var controller = DictationController.shared
    @State private var newWord = ""
    @State private var rows: [ReplacementRow] = []
    @State private var sample = ""

    struct ReplacementRow: Identifiable, Equatable {
        let id = UUID()
        var spoken: String
        var written: String
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("", text: $newWord, prompt: Text("Add a word or name, e.g. Kubernetes"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addWords)
                    Button("Add", action: addWords)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if settings.vocabularyTerms.isEmpty {
                    Text("No words yet. Add names, brands and jargon the model might not know.")
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(settings.vocabularyTerms, id: \.self) { term in
                            HStack(spacing: 4) {
                                Text(term)
                                Button { remove(term) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove \(term)")
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 6)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12), in: .capsule)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Toggle("Offer to add words you correct", isOn: $settings.learnCorrections)
            } header: {
                Text("Words and names")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Driftflow listens for these and always spells them exactly as you wrote them: “drift flow” → Driftflow. Separate several with commas.")
                    if !controller.vocabularyStatus.isEmpty {
                        Label(controller.vocabularyStatus, systemImage: "checkmark.seal")
                    }
                    if !settings.vocabularyTerms.isEmpty {
                        Text("Listening for your words adds about 0.1 s after you release the key.")
                    }
                    Text("When you fix a name or term right after dictating it (“cooper netties” → Kubernetes), Driftflow offers to add it here. It reads only that text field, for a minute and a half, and keeps nothing else.")
                }
                .foregroundStyle(.secondary)
            }

            Section {
                if !rows.isEmpty {
                    HStack {
                        Text("When you say").frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 20)
                        Text("Driftflow types").frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 20)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                ForEach($rows) { $row in
                    HStack {
                        TextField("", text: $row.spoken, prompt: Text("my email"))
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).frame(width: 20)
                        TextField("", text: $row.written, prompt: Text("name@example.com"))
                            .textFieldStyle(.roundedBorder)
                        Button { rows.removeAll { $0.id == row.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 20)
                        .help("Remove this replacement")
                    }
                }
                Button {
                    rows.append(ReplacementRow(spoken: "", written: ""))
                } label: {
                    Label("Add Replacement", systemImage: "plus")
                }
            } header: {
                Text("Replacements")
            } footer: {
                Text("Say a short phrase, get something longer typed: your email, address or sign-off. Matches whole words in any capitalization.")
                    .foregroundStyle(.secondary)
            }

            SnippetsSection(settings: settings)

            Section {
                TextField("", text: $sample, prompt: Text("Type what you might say, e.g. um send it to my email new line thanks"))
                    .textFieldStyle(.roundedBorder)
                if !sample.isEmpty {
                    LabeledContent("Driftflow types") {
                        Text(Snippet.match(sample, in: settings.snippets)?.expanded() ?? settings.textProcessor.process(sample))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Try it")
            } footer: {
                Text("Shows your snippets, spellings and replacements, plus filler removal and “new line” / “new paragraph” from Output settings. AI Styles aren't applied here.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: loadRows)
        .onChange(of: rows) { saveRows() }
    }

    private func addWords() {
        let existing = Set(settings.vocabularyTerms.map { $0.lowercased() })
        let words = newWord.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !existing.contains($0.lowercased()) }
        guard !words.isEmpty else { newWord = ""; return }
        withAnimation(.snappy) {
            settings.vocabulary = (settings.vocabularyTerms + words).joined(separator: "\n")
        }
        newWord = ""
    }

    private func remove(_ term: String) {
        withAnimation(.snappy) {
            settings.vocabulary = settings.vocabularyTerms.filter { $0 != term }.joined(separator: "\n")
        }
    }

    private func loadRows() {
        rows = settings.replacements.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            return ReplacementRow(spoken: parts[0].trimmingCharacters(in: .whitespaces), written: parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Rows still being typed (one side empty) stay on screen but aren't used yet.
    private func saveRows() {
        settings.replacements = rows
            .filter { !$0.spoken.trimmingCharacters(in: .whitespaces).isEmpty && !$0.written.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.spoken.trimmingCharacters(in: .whitespaces)) => \($0.written.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")
    }
}

/// Lays chips out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct HistoryPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var store = HistoryStore.shared
    @State private var query = ""
    @State private var confirmClear = false
    /// How many dictations are shown; "Show More" adds a page. Laying out thousands of rows at
    /// once froze the window for over a minute.
    @State private var shown = HistoryPane.pageSize
    static let pageSize = 50

    private var matches: [HistoryEntry] {
        query.isEmpty ? store.entries : store.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// The shown entries grouped under "Today", "Yesterday", or a date.
    private func groups(_ entries: ArraySlice<HistoryEntry>) -> [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var result: [(String, [HistoryEntry])] = []
        for entry in entries {
            let title = calendar.isDateInToday(entry.date) ? "Today"
                : calendar.isDateInYesterday(entry.date) ? "Yesterday"
                : entry.date.formatted(.dateTime.weekday(.wide).month().day())
            if result.last?.0 == title { result[result.count - 1].1.append(entry) } else { result.append((title, [entry])) }
        }
        return result
    }

    var body: some View {
        let matches = matches
        Form {
            if !store.entries.isEmpty {
                Section {
                    HStack(spacing: 16) {
                        StatTile(value: store.stats.totalWords.formatted(), caption: "Words dictated")
                        StatTile(value: store.stats.wordsThisWeek.formatted(), caption: "This week")
                        StatTile(value: store.stats.dictations.formatted(), caption: "Dictations")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                Picker("Keep history", selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Keep audio of failed dictations for 24 hours", isOn: $settings.keepFailedAudio)
                if !store.entries.isEmpty {
                    LabeledContent("All \(store.entries.count) dictations") {
                        Button("Clear History…", role: .destructive) { confirmClear = true }
                    }
                }
            } footer: {
                Text("Stored only on this Mac and kept across restarts and updates. Never uploaded. Audio is never kept for dictations that worked; for one that fails, it's kept so you can press Retry, then deleted after the retry or 24 hours. Stacks follow the same period, counted from their last change (clearing History leaves them alone, and pinned lines are kept until you remove them).")
                    .foregroundStyle(.secondary)
            }

            if store.entries.isEmpty {
                Section {
                    ContentUnavailableView("No dictations yet", systemImage: "waveform",
                                           description: Text("Everything you dictate shows up here."))
                }
            } else if matches.isEmpty {
                Section {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                ForEach(groups(matches.prefix(shown)), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in HistoryRow(entry: entry) }
                    }
                }
                if matches.count > shown {
                    Section {
                        HStack {
                            Text("Showing \(shown.formatted()) of \(matches.count.formatted())")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Show \(min(Self.pageSize, matches.count - shown)) More") { shown += Self.pageSize }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search dictations")
        .onChange(of: query) { shown = Self.pageSize }
        .confirmationDialog("Delete all \(store.entries.count) dictations?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { withAnimation { store.clear() } }
        } message: {
            Text("This also deletes any saved audio of failed dictations. It can't be undone.")
        }
    }
}

/// One dictation in History. Hover, copy and expand state live here, so hovering a row
/// redraws only that row.
private struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var hovered = false
    @State private var copied = false
    @State private var expanded = false
    @State private var retrying = false
    @State private var retryFailed = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if entry.status == .failed {
                    HStack(spacing: 8) {
                        Label("Couldn't transcribe", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.12), in: .capsule)
                        if entry.audioFile != nil {
                            Button(retrying ? "Retrying…" : "Retry") {
                                retrying = true
                                Task {
                                    let ok = await DictationController.shared.retry(entry)
                                    retrying = false
                                    if !ok { retryFailed = true }
                                }
                            }
                            .glassButtonStyle()
                            .controlSize(.small)
                            .disabled(retrying)
                        } else {
                            Text("Audio no longer kept").font(.caption).foregroundStyle(.secondary)
                        }
                        if retryFailed {
                            Text("Still nothing: the recording may be silent.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(entry.text)
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.text.count > 240 {
                        Button(expanded ? "Show less" : "Show more") {
                            withAnimation(.snappy) { expanded.toggle() }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                HStack(spacing: 10) {
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                    if let app = entry.appName { Label(app, systemImage: "app") }
                    if let ms = entry.latencyMs { Label("\(ms) ms", systemImage: "bolt.fill") }
                    if entry.status == nil { Text("\(entry.wordCount) words") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            HStack(spacing: 10) {
                // Delete shows on hover; its space is always kept so the row never shifts.
                Button { withAnimation(.snappy) { HistoryStore.shared.delete(entry) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(entry.audioFile != nil ? "Delete (and its saved audio)" : "Delete")
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
                if !entry.text.isEmpty {
                    Button {
                        TextInserter.shared.copy(entry.text)
                        withAnimation(.snappy) { copied = true }
                        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation(.snappy) { copied = false } }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside } }
        .contextMenu {
            if !entry.text.isEmpty { Button("Copy") { TextInserter.shared.copy(entry.text) } }
            Button("Delete", role: .destructive) { withAnimation { HistoryStore.shared.delete(entry) } }
        }
    }
}

private struct PermissionsPane: View {
    @ObservedObject var controller: DictationController
    @State private var microphone = Permissions.microphone

    var body: some View {
        Form {
            Section {
                LabeledContent("Microphone") {
                    if microphone == .authorized {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Settings") { Permissions.openMicrophoneSettings() }
                    }
                }
                LabeledContent("Accessibility") {
                    if controller.accessibilityGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            Permissions.promptAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                    }
                }
            } footer: {
                Text("Accessibility access lets Driftflow see the dictation key and insert text. Ad hoc–signed builds get a new identity on every rebuild, so remove Driftflow from the Accessibility list and add it again afterwards.")
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Speech is transcribed entirely on this Mac. No audio or text ever leaves it. History is stored locally and can be turned off under History.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { microphone = Permissions.microphone }
    }
}

/// Sparkle's own settings (it stores them itself), so they stay in step with the update prompts.
private struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
            Toggle("Download and install updates automatically", isOn: Binding(get: { updater.automaticallyInstalls }, set: { updater.automaticallyInstalls = $0 }))
                .disabled(!updater.automaticallyChecks)
            LabeledContent("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")") {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("New versions install when Driftflow quits or restarts. Updates are signed, and Driftflow refuses any that aren't.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Reads the real login-item state from macOS each time it appears, so it stays right if you
/// change it in System Settings › General › Login Items. Asking macOS is a slow round trip (it
/// held up opening the window), so it's done in the background.
struct LaunchAtLoginToggle: View {
    @State private var status: SMAppService.Status?

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { status == .enabled }, set: { value in
            status = value ? .enabled : .notRegistered
            Task {
                await Task.detached { LoginItem.set(value) }.value
                await refresh()
            }
        }))
        .disabled(status == nil)
        .task { await refresh() }
        if status == .requiresApproval {
            Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                .buttonStyle(.link)
        }
    }

    private func refresh() async {
        status = await Task.detached { SMAppService.mainApp.status }.value
    }
}

/// Microphones in order of preference: Driftflow uses the highest-ranked one that's connected and
/// moves down the list (and back up) as devices come and go.
private struct MicPrioritySection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var devices: AudioDevices

    /// The microphone Driftflow would record from right now.
    private var inUseUID: String? {
        AudioDevices.deviceID(forPriority: settings.micPriority.map(\.uid)).flatMap(AudioDevices.uid(of:))
    }
    private var unlisted: [AudioDevices.Device] {
        devices.inputs.filter { device in !settings.micPriority.contains { $0.uid == device.uid } }
    }
    /// Entries below "System default" are never reached: it's always available.
    private var defaultIndex: Int { settings.micPriority.firstIndex(where: \.isSystemDefault) ?? settings.micPriority.count }

    var body: some View {
        Section {
            ForEach(Array(settings.micPriority.enumerated()), id: \.element.id) { index, mic in
                row(mic, index: index)
            }
            if !unlisted.isEmpty {
                Menu("Add Microphone") {
                    ForEach(unlisted) { device in
                        Button(device.name) {
                            // New mics go above "System default", so they're actually used.
                            var list = settings.micPriority
                            list.insert(MicPreference(uid: device.uid, name: device.name), at: defaultIndex)
                            settings.micPriority = list
                        }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
        } header: {
            Text("Microphones")
        } footer: {
            Text("Driftflow records from the highest one that's connected. Unplug it and the next takes over; plug it back in and it's used again, even between dictations. With the lid closed, the built-in mic is skipped.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ mic: MicPreference, index: Int) -> some View {
        let connected = mic.isSystemDefault || devices.inputs.contains { $0.uid == mic.uid }
        // System default is in use when no microphone ranked above it is connected.
        let inUse = mic.isSystemDefault
            ? !settings.micPriority[..<index].contains { entry in devices.inputs.contains { $0.uid == entry.uid } }
            : mic.uid == inUseUID
        let unreachable = index > defaultIndex
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(mic.isSystemDefault ? "System default (\(devices.defaultInputName))" : mic.name)
                    .foregroundStyle(connected && !unreachable ? .primary : .secondary)
                if inUse {
                    Text("In use").font(.caption).foregroundStyle(Color.accentColor)
                } else if unreachable {
                    Text("Not used: System default is above it").font(.caption).foregroundStyle(.secondary)
                } else if !connected {
                    Text("Not connected").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Move up")
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == settings.micPriority.count - 1)
                    .help("Move down")
                Button { settings.micPriority.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .opacity(mic.isSystemDefault ? 0 : 1)
                    .disabled(mic.isSystemDefault)
                    .help("Remove from the list")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var list = settings.micPriority
        list.swapAt(index, index + offset)
        withAnimation(.snappy) { settings.micPriority = list }
    }
}
