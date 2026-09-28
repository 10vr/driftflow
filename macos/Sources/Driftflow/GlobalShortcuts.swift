import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, e.g. ⌃⌥V. Stored with Carbon modifier bits so it can be registered as a
/// system-wide hot key (which needs no Accessibility permission).
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let pasteLastDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))
    static let editDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(controlKey | optionKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(carbon))
    }

    /// Modifier symbols in Apple's order, then the key.
    var symbols: [String] {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyName(keyCode))
        return parts
    }

    var display: String { symbols.joined() }

    /// Why this combo can't be used, or nil if it's fine.
    var problem: String? {
        let mods = modifiers & UInt32(cmdKey | optionKey | controlKey)
        if mods == 0 { return "Add ⌘, ⌥ or ⌃ so normal typing isn't affected." }
        let cmdOnly = modifiers == UInt32(cmdKey)
        let reserved: Set<Int> = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X,
                                  kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_F,
                                  kVK_ANSI_T, kVK_Tab, kVK_Space, kVK_ANSI_Comma]
        if cmdOnly, reserved.contains(Int(keyCode)) { return "\(display) is a standard macOS shortcut." }
        if modifiers == UInt32(controlKey), keyCode == UInt32(kVK_Space) { return "⌃Space switches input sources." }
        if modifiers == UInt32(cmdKey | shiftKey), [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].contains(Int(keyCode)) {
            return "\(display) takes screenshots."
        }
        if keyCode == UInt32(kVK_Space), modifiers == UInt32(optionKey) || modifiers == UInt32(optionKey | controlKey) {
            return "\(display) can be the dictation key; pick another."
        }
        return nil
    }

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The character the key types on the current keyboard layout (so ⌃⌥V reads right on AZERTY too).
    static func keyName(_ keyCode: UInt32) -> String {
        if let name = special[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = unsafeBitCast(data, to: CFData.self)
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
            UCKeyTranslate(pointer, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// System-wide shortcuts for actions other than the dictation key (Carbon hot keys, signature "DRFS").
@MainActor
final class GlobalShortcuts: ObservableObject {
    static let shared = GlobalShortcuts()
    /// Shortcuts macOS refused to register (another app already owns that combination).
    @Published private(set) var unavailable: Set<Action> = []
    static let signature = OSType(0x4452_4653) // "DRFS"

    enum Action: UInt32, CaseIterable {
        case pasteLast = 1
        case handsFree = 2
        case editSelection = 3
    }

    var handlers: [Action: () -> Void] = [:]
    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    func register(_ combo: KeyCombo?, for action: Action) {
        installHandlerIfNeeded()
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        unavailable.remove(action)
        guard let combo, combo.problem == nil else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        if RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[action] = ref
        } else {
            unavailable.insert(action)
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalShortcuts.signature, let action = Action(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr) // someone else's hot key (the dictation key)
            }
            MainActor.assumeIsolated { GlobalShortcuts.shared.handlers[action]?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }
}
