import AppKit

enum TriggerKey: String, CaseIterable, Identifiable {
    case rightCommand
    case rightOption
    case fn
    case optionSpace
    case controlOptionSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightCommand: "Right Command ⌘"
        case .rightOption: "Right Option ⌥"
        case .fn: "Fn / 🌐"
        case .optionSpace: "⌥ Space"
        case .controlOptionSpace: "⌃⌥ Space"
        }
    }

    /// As shown next to a menu command.
    var shortLabel: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .fn: "fn"
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        }
    }

    /// Modifier-only triggers are watched through NSEvent monitors; key combos use a Carbon hot key.
    var isModifierOnly: Bool {
        switch self {
        case .rightOption, .rightCommand, .fn: true
        case .optionSpace, .controlOptionSpace: false
        }
    }

    /// The modifier a single-key trigger is (none for key combos).
    var modifier: NSEvent.ModifierFlags? {
        switch self {
        case .rightCommand: .command
        case .rightOption: .option
        case .fn: .function
        case .optionSpace, .controlOptionSpace: nil
        }
    }
}

/// The key held with the dictation key to send that dictation to the stack (either side's).
enum StackKey: String, CaseIterable, Identifiable {
    case control
    case option
    case shift
    case command
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .shift: "⇧ Shift"
        case .command: "⌘ Command"
        case .off: "Off"
        }
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .off: ""
        }
    }

    var modifier: NSEvent.ModifierFlags? {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        case .off: nil
        }
    }

    /// What to watch for with this dictation key: nothing for key combos (⌥ Space) or when it's
    /// the dictation key's own modifier (⌘ with Right ⌘).
    func modifier(with trigger: TriggerKey) -> NSEvent.ModifierFlags? {
        guard let modifier, let own = trigger.modifier, modifier != own else { return nil }
        return modifier
    }
}

enum ModelPreference: String, CaseIterable, Identifiable {
    /// SpeechTranscriber when the language supports it, otherwise DictationTranscriber.
    case automatic
    /// Always use DictationTranscriber (the model behind macOS Dictation; more languages).
    case dictation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Best available"
        case .dictation: "Dictation model"
        }
    }
}

enum LivePreviewSource: String, CaseIterable, Identifiable {
    /// Apple Speech streams the live text (Parakeet only shows the first words).
    case apple
    /// The selected final-text model shows the live text too.
    case finalModel

    var id: String { rawValue }
}

enum MicMode: String, CaseIterable, Identifiable {
    /// Mic opens on key-down and closes after dictating.
    case onDemand
    /// Mic stays warm for 30 s after a dictation, so follow-ups start instantly with pre-roll.
    case linger
    /// Mic always warm: zero start latency, and the half-second before the key press is captured.
    case alwaysReady

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDemand: "Only while dictating"
        case .linger: "Keep warm for 30 s after dictating"
        case .alwaysReady: "Always ready (instant, captures pre-roll)"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var trigger: TriggerKey {
        didSet {
            defaults.set(trigger.rawValue, forKey: "trigger")
            // Right ⌘ can't be held with ⌘ to mean something else.
            if stackKey.modifier == trigger.modifier { stackKey = .control }
        }
    }
    /// Dictation language (ISO 639 code, e.g. "en"). Defaults to the Mac's language.
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// Accent/region for that language ("GB", "US"…); "" matches the Mac.
    @Published var accent: String { didSet { defaults.set(accent, forKey: "accent") } }
    @Published var modelPreference: ModelPreference { didSet { defaults.set(modelPreference.rawValue, forKey: "modelPreference") } }
    @Published var tapForHandsFree: Bool { didSet { defaults.set(tapForHandsFree, forKey: "tapForHandsFree") } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    @Published var insertionMethod: InsertionMethod { didSet { defaults.set(insertionMethod.rawValue, forKey: "insertionMethod") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var smartSpacing: Bool { didSet { defaults.set(smartSpacing, forKey: "smartSpacing") } }
    @Published var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }
    @Published var spokenCommands: Bool { didSet { defaults.set(spokenCommands, forKey: "spokenCommands") } }
    @Published var livePreview: LivePreviewSource { didSet { defaults.set(livePreview.rawValue, forKey: "livePreview") } }
    @Published var accuracyModel: AccuracyModel { didSet { defaults.set(accuracyModel.rawValue, forKey: "accuracyModel") } }
    @Published var soundStyle: SoundStyle { didSet { defaults.set(soundStyle.rawValue, forKey: "soundStyle") } }
    @Published var historyRetention: HistoryRetention { didSet { defaults.set(historyRetention.rawValue, forKey: "historyRetention") } }
    @Published var micMode: MicMode { didSet { defaults.set(micMode.rawValue, forKey: "micMode") } }
    @Published var hudPosition: HUDPosition { didSet { defaults.set(hudPosition.rawValue, forKey: "hudPosition") } }
    /// "spoken => written" pairs, one per line.
    @Published var replacements: String { didSet { defaults.set(replacements, forKey: "replacements") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var showHUD: Bool { didSet { defaults.set(showHUD, forKey: "showHUD") } }
    /// One term per line: names, jargon, product names the model should favour.
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    /// Dock icon and ⌘-Tab entry (macOS ties the two together). Off = menu bar only.
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }
    /// Types your last dictation again (default ⌃⌥V).
    @Published var pasteLastShortcut: KeyCombo? { didSet { store(pasteLastShortcut, "pasteLastShortcut") } }
    /// Starts/finishes hands-free dictation without holding anything (optional).
    @Published var handsFreeShortcut: KeyCombo? { didSet { store(handsFreeShortcut, "handsFreeShortcut") } }
    /// Turn other audio (music, videos) down while dictating.
    @Published var duckAudio: Bool { didSet { defaults.set(duckAudio, forKey: "duckAudio") } }
    /// Keep the audio of a failed dictation (for 24 hours) so it can be retried.
    @Published var keepFailedAudio: Bool { didSet { defaults.set(keepFailedAudio, forKey: "keepFailedAudio") } }
    /// Keep a thin pill on screen between dictations; hover to see the key, click to start.
    @Published var showIdlePill: Bool { didSet { defaults.set(showIdlePill, forKey: "showIdlePill") } }
    /// How the stack's tab shows at the bottom right of the screen while it holds dictations.
    @Published var stackTab: StackTabStyle { didSet { defaults.set(stackTab.rawValue, forKey: "stackTab") } }
    /// Every dictation goes into the stack instead of being pasted.
    @Published var stackMode: Bool { didSet { defaults.set(stackMode, forKey: "stackMode") } }
    /// What Paste (and dragging the stack's tab) puts in: the stack, pinned lines, or both.
    @Published var stackPaste: StackPasteChoice { didSet { defaults.set(stackPaste.rawValue, forKey: "stackPaste") } }
    /// Lines each stack holds; a new one past that pushes the oldest out (default 20).
    @Published var stackCapacity: Int { didSet { defaults.set(stackCapacity, forKey: "stackCapacity") } }
    static let stackCapacityRange = 5...200
    /// Held with the dictation key, sends that dictation to the stack (default ⌃ Control).
    @Published var stackKey: StackKey { didSet { defaults.set(stackKey.rawValue, forKey: "stackKey") } }
    /// Microphones in order of preference: Driftflow records from the first one that's connected.
    /// "System default" (uid "") is an entry too, always available, so it can be ranked anywhere.
    @Published var micPriority: [MicPreference] {
        didSet { defaults.set((try? JSONEncoder().encode(micPriority)) ?? Data(), forKey: "micPriority") }
    }

    /// How Apple's on-device model rewrites dictations (Original: not at all).
    @Published var aiStyle: AIStyle { didSet { defaults.set(aiStyle.rawValue, forKey: "aiStyle") } }
    /// Per-app and per-website overrides.
    @Published var appRules: [AppRule] { didSet { defaults.set((try? JSONEncoder().encode(appRules)) ?? Data(), forKey: "appRules") } }
    /// Spoken phrases that insert saved text.
    @Published var snippets: [Snippet] { didSet { defaults.set((try? JSONEncoder().encode(snippets)) ?? Data(), forKey: "snippets") } }
    /// Select text, press this and say how to change it (default ⌃⌥E).
    @Published var editShortcut: KeyCombo? { didSet { store(editShortcut, "editShortcut") } }
    /// Offer to add a word to Vocabulary when you correct it right after dictating.
    @Published var learnCorrections: Bool { didSet { defaults.set(learnCorrections, forKey: "learnCorrections") } }

    /// The first choice (what the menu bar and setup pickers show and set). Picking a mic moves it
    /// to the top of the list; the rest keep their order as fallbacks.
    var inputDeviceUID: String {
        get { micPriority.first?.uid ?? "" }
        set {
            guard newValue != inputDeviceUID else { return }
            let name = micPriority.first { $0.uid == newValue }?.name
                ?? AudioDevices.shared.inputs.first { $0.uid == newValue }?.name ?? "Microphone"
            micPriority = [MicPreference(uid: newValue, name: name)] + micPriority.filter { $0.uid != newValue }
        }
    }

    private init() {
        defaults.register(defaults: [
            "trigger": TriggerKey.rightCommand.rawValue,
            "language": Locale.current.language.languageCode?.identifier ?? "en",
            "accent": "",
            "modelPreference": ModelPreference.automatic.rawValue,
            "tapForHandsFree": true,
            "autoPaste": true,
            "insertionMethod": InsertionMethod.paste.rawValue,
            "restoreClipboard": true,
            "smartSpacing": true,
            "removeFillers": true,
            "spokenCommands": true,
            "micMode": MicMode.onDemand.rawValue,
            "historyRetention": HistoryRetention.month.rawValue,
            "soundStyle": SoundStyle.bells.rawValue,
            "accuracyModel": AccuracyModel.parakeetUnified.rawValue,
            "livePreview": LivePreviewSource.finalModel.rawValue,
            "hudPosition": HUDPosition.bottom.rawValue,
            "replacements": "",
            "playSounds": true,
            "showHUD": true,
            "vocabulary": "",
            "showInDock": true,
            "inputDeviceUID": "",
            "showIdlePill": false,
            "stackTab": StackTabStyle.faded.rawValue,
            "stackMode": false,
            "stackPaste": StackPasteChoice.stack.rawValue,
            "stackKey": StackKey.control.rawValue,
            "stackCapacity": 20,
            "keepFailedAudio": true,
            "duckAudio": true,
            "aiStyle": AIStyle.literal.rawValue,
            "learnCorrections": true,
        ])
        stackKey = StackKey(rawValue: defaults.string(forKey: "stackKey") ?? "") ?? .control
        stackCapacity = min(max(defaults.integer(forKey: "stackCapacity"), Self.stackCapacityRange.lowerBound),
                            Self.stackCapacityRange.upperBound)
        trigger = TriggerKey(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .rightCommand
        // Migrate the old single "localeID" ("en-GB") setting.
        if let old = defaults.string(forKey: "localeID"), !old.isEmpty {
            let parts = old.split(separator: "-").map(String.init)
            defaults.set(parts[0], forKey: "language")
            defaults.set(parts.count > 1 ? parts[1] : "", forKey: "accent")
            defaults.removeObject(forKey: "localeID")
        }
        showInDock = defaults.bool(forKey: "showInDock")
        if let data = defaults.data(forKey: "micPriority"), let saved = try? JSONDecoder().decode([MicPreference].self, from: data),
           !saved.isEmpty {
            micPriority = saved.contains(where: \.isSystemDefault) ? saved : saved + [.systemDefault]
        } else {
            // From the single "Microphone" setting: that mic first, then the system default.
            let old = defaults.string(forKey: "inputDeviceUID") ?? ""
            let name = AudioDevices.shared.inputs.first { $0.uid == old }?.name ?? "Microphone"
            micPriority = old.isEmpty ? [.systemDefault] : [MicPreference(uid: old, name: name), .systemDefault]
        }
        aiStyle = AIStyle(rawValue: defaults.string(forKey: "aiStyle") ?? "") ?? .literal
        appRules = defaults.data(forKey: "appRules").flatMap { try? JSONDecoder().decode([AppRule].self, from: $0) } ?? []
        snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        editShortcut = defaults.object(forKey: "editShortcut") == nil ? .editDefault : Self.combo(defaults, "editShortcut")
        learnCorrections = defaults.bool(forKey: "learnCorrections")
        showIdlePill = defaults.bool(forKey: "showIdlePill")
        stackTab = StackTabStyle(rawValue: defaults.string(forKey: "stackTab") ?? "") ?? .faded
        stackMode = defaults.bool(forKey: "stackMode")
        stackPaste = StackPasteChoice(rawValue: defaults.string(forKey: "stackPaste") ?? "") ?? .stack
        keepFailedAudio = defaults.bool(forKey: "keepFailedAudio")
        duckAudio = defaults.bool(forKey: "duckAudio")
        pasteLastShortcut = defaults.object(forKey: "pasteLastShortcut") == nil ? .pasteLastDefault : Self.combo(defaults, "pasteLastShortcut")
        handsFreeShortcut = Self.combo(defaults, "handsFreeShortcut")
        language = defaults.string(forKey: "language") ?? "en"
        accent = defaults.string(forKey: "accent") ?? ""
        modelPreference = ModelPreference(rawValue: defaults.string(forKey: "modelPreference") ?? "") ?? .automatic
        tapForHandsFree = defaults.bool(forKey: "tapForHandsFree")
        autoPaste = defaults.bool(forKey: "autoPaste")
        insertionMethod = InsertionMethod(rawValue: defaults.string(forKey: "insertionMethod") ?? "") ?? .paste
        restoreClipboard = defaults.bool(forKey: "restoreClipboard")
        smartSpacing = defaults.bool(forKey: "smartSpacing")
        removeFillers = defaults.bool(forKey: "removeFillers")
        spokenCommands = defaults.bool(forKey: "spokenCommands")
        // The preview now comes from the same NVIDIA model as the final text by default: switch
        // copies that kept the old Apple Speech default over once.
        if !defaults.bool(forKey: "livePreviewParakeetDefault") {
            defaults.set(true, forKey: "livePreviewParakeetDefault")
            defaults.set(LivePreviewSource.finalModel.rawValue, forKey: "livePreview")
        }
        livePreview = LivePreviewSource(rawValue: defaults.string(forKey: "livePreview") ?? "") ?? .finalModel
        accuracyModel = AccuracyModel(rawValue: defaults.string(forKey: "accuracyModel") ?? "") ?? .parakeetUnified
        // "handyPop" was the earlier Pop set (Handy's sounds), now Driftflow's own.
        let savedSound = defaults.string(forKey: "soundStyle") ?? ""
        soundStyle = SoundStyle(rawValue: savedSound == "handyPop" ? "pop" : savedSound) ?? .bells
        historyRetention = HistoryRetention(rawValue: defaults.string(forKey: "historyRetention") ?? "") ?? .month
        micMode = MicMode(rawValue: defaults.string(forKey: "micMode") ?? "") ?? .onDemand
        hudPosition = HUDPosition(rawValue: defaults.string(forKey: "hudPosition") ?? "") ?? .bottom
        replacements = defaults.string(forKey: "replacements") ?? ""
        playSounds = defaults.bool(forKey: "playSounds")
        showHUD = defaults.bool(forKey: "showHUD")
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
    }

    /// Stored as JSON; an empty value means "no shortcut" (distinct from never set).
    private func store(_ combo: KeyCombo?, _ key: String) {
        defaults.set(combo.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    private static func combo(_ defaults: UserDefaults, _ key: String) -> KeyCombo? {
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    var vocabularyTerms: [String] {
        vocabulary
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Your terms plus the app's own name, so "drift flow", "Drift-Flow" or "DriftFlow" is always
    /// written "Driftflow". (Spelling only: the name isn't added to recognition boosting, which
    /// would make everyone download its helper model.)
    var spellingTerms: [String] {
        let terms = vocabularyTerms
        return terms.contains { $0.caseInsensitiveCompare("Driftflow") == .orderedSame } ? terms : terms + ["Driftflow"]
    }

    var textProcessor: TextProcessor {
        let pairs = replacements.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces))
        }
        return TextProcessor(removeFillers: removeFillers, spokenCommands: spokenCommands, replacements: pairs, vocabulary: spellingTerms)
    }

    var engineConfig: SpeechConfig {
        SpeechConfig(language: language, accent: accent, model: modelPreference, vocabulary: vocabularyTerms)
    }
}

/// One entry in the microphone priority list. The name is remembered so a disconnected mic can
/// still be shown and ranked.
struct MicPreference: Codable, Equatable, Hashable, Identifiable {
    var uid: String
    var name: String

    var id: String { uid }
    var isSystemDefault: Bool { uid.isEmpty }
    static let systemDefault = MicPreference(uid: "", name: "System default")
}
