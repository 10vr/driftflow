import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InsertionMethod: String, CaseIterable, Identifiable {
    /// Clipboard paste with a lazily-provided item: fastest and works almost everywhere.
    case paste
    /// Synthesized Unicode keystrokes: never touches the clipboard; for apps that mangle pastes.
    case type

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paste: "Paste (fastest)"
        case .type: "Type characters"
        }
    }
}

/// Inserts text into the focused app with no fixed sleeps on the critical path.
///
/// Paste mode puts a *promised* item on the clipboard and sends ⌘V straight away. The target app
/// pulls the text through `pasteboard(_:item:provideDataForType:)`, which tells us the paste has
/// landed, so the user's clipboard is restored right after, instead of guessing with a timer.
@MainActor
final class TextInserter: NSObject, NSPasteboardItemDataProvider {
    static let shared = TextInserter()

    enum Outcome {
        case inserted
        /// No Accessibility access, so the text was left on the clipboard for the user to paste.
        case copiedOnly
    }

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let pasteboard = NSPasteboard.general
    private var promisedText = ""
    private var savedItems: [NSPasteboardItem]?
    private var promiseChangeCount = 0
    private var restoreWork: DispatchWorkItem?
    /// `--scratch-test` only: deliver keystrokes to this process instead of the focused app.
    var testTargetPID: pid_t?

    func insert(_ text: String, method: InsertionMethod, restoreClipboard: Bool) -> Outcome {
        guard Permissions.accessibilityGranted else {
            copy(text)
            return .copiedOnly
        }
        switch method {
        case .paste: paste(text, restoreClipboard: restoreClipboard)
        case .type: type(text)
        }
        return .inserted
    }

    // MARK: Remove ("scratch that")

    /// Deletes `text`, typed at `insertedAt`, from the focused field, only when that's provably
    /// safe. Where the app exposes its text (most do), the text right before the caret must still
    /// be exactly what was typed; it's selected and deleted in one keystroke. Where it doesn't,
    /// nothing may have been typed or clicked since, and it's removed with backspaces.
    func remove(_ text: String, insertedAt: Date) -> Bool {
        let length = text.utf16.count
        guard length > 0, Permissions.accessibilityGranted else { return false }
        let delete = CGKeyCode(kVK_Delete)
        switch Self.focusedCaret() {
        case .selection:
            return false // something is selected (e.g. an autocompletion): a Delete would hit that
        case .unavailable:
            break
        case .caret(let element, let caret):
            guard caret >= length else { return false }
            var range = CFRange(location: caret - length, length: length)
            guard let request = AXValueCreate(.cfRange, &range) else { return false }
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          request, &result) == .success, let before = result as? String {
                guard before == text,
                      AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, request) == .success
                else { return false }
                postShortcut(key: delete, flags: [])
                return true
            }
        }
        // The app doesn't expose its text: fall back to backspaces, but only if you haven't typed
        // or clicked in another app since it was inserted (the dictation key itself doesn't count).
        guard !InputActivity.hasActivity(since: insertedAt), text.count <= 500, !text.contains("\n") else { return false }
        for _ in 0..<text.count { postShortcut(key: delete, flags: []) }
        return true
    }

    private enum Caret {
        case caret(AXUIElement, Int)
        case selection
        case unavailable
    }

    /// The focused text element and its caret position.
    private static func focusedCaret() -> Caret {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unavailable }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return .unavailable }
        var selection = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &selection) else { return .unavailable }
        return selection.length == 0 ? .caret(element, selection.location) : .selection
    }

    func copy(_ text: String) {
        restoreNow()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Paste

    private func paste(_ text: String, restoreClipboard: Bool) {
        restoreNow() // a previous paste still waiting to restore gives the clipboard back first

        if restoreClipboard {
            savedItems = snapshot()
            promisedText = text
            let item = NSPasteboardItem()
            item.setDataProvider(self, forTypes: [.string])
            // Well-behaved clipboard managers skip these, so they don't read (and trigger) the promise.
            item.setString("", forType: Self.transientType)
            item.setString("", forType: Self.concealedType)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            promiseChangeCount = pasteboard.changeCount
            // Safety net if the app never asks for the data (focus on a non-text element). Generous,
            // because a busy app (Electron, remote desktop) may read the clipboard late.
            scheduleRestore(after: 8.0)
        } else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        postShortcut(key: Self.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let provide = {
            MainActor.assumeIsolated {
                item.setString(self.promisedText, forType: type)
                // The app has the text. It may ask for more representations within the same paste,
                // so give it a moment before handing the clipboard back.
                self.scheduleRestore(after: 0.12)
            }
        }
        if Thread.isMainThread { provide() } else { DispatchQueue.main.sync(execute: provide) }
    }

    private func scheduleRestore(after delay: TimeInterval) {
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreNow() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func restoreNow() {
        restoreWork?.cancel()
        restoreWork = nil
        guard let saved = savedItems else { return }
        savedItems = nil
        // Leave the clipboard alone if the user copied something else in the meantime.
        guard pasteboard.changeCount == promiseChangeCount else { return }
        pasteboard.clearContents()
        // A password (marked concealed/transient by password managers) isn't put back: they clear
        // it on a timer, and writing it again would look like a fresh copy and keep it around.
        let secret = saved.contains { $0.types.contains(Self.concealedType) || $0.types.contains(Self.transientType) }
        if !saved.isEmpty, !secret { pasteboard.writeObjects(saved) }
    }

    private func snapshot() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    // MARK: Keystrokes

    /// ⌘C in the focused app (voice editing reads the selection this way when Accessibility can't).
    func sendCopy() {
        guard Permissions.accessibilityGranted else { return }
        postShortcut(key: Self.keyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    }

    /// Return, to send a message (per-app rule). Queued after the paste's ⌘V, so it lands after the text.
    func pressReturn() {
        guard Permissions.accessibilityGranted else { return }
        postShortcut(key: CGKeyCode(kVK_Return), flags: [])
    }

    /// Apps where Return sends the message: there a spoken "new line" must be Shift+Return.
    private static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord", "net.whatsapp.WhatsApp",
        "desktop.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.microsoft.teams2", "com.microsoft.teams",
        "org.whispersystems.signal-desktop", "com.facebook.archon", "com.openai.chat", "com.anthropic.claudefordesktop",
        "us.zoom.xos", "jp.naver.line.mac", "im.riot.app", "com.mattermost.desktop",
        // Browsers: web chats (ChatGPT, Slack, WhatsApp Web…) send on Return too; Shift+Return is
        // a plain line break in ordinary web text fields.
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    private func type(_ text: String) {
        let inChat = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(Self.chatApps.contains) ?? false
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { postShortcut(key: CGKeyCode(kVK_Return), flags: inChat ? .maskShift : []) }
            typeLine(line)
        }
    }

    private func typeLine(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .privateState)
        // Apps reliably accept up to 20 UTF-16 units per synthesized event. Chunk on character
        // boundaries so emoji and combined characters are never split.
        var chunks: [[UniChar]] = [[]]
        for character in text {
            let units = Array(String(character).utf16)
            if chunks[chunks.count - 1].count + units.count > 20 { chunks.append([]) }
            chunks[chunks.count - 1] += units
        }
        for var chunk in chunks where !chunk.isEmpty {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                post(event)
            }
        }
    }

    private func postShortcut(key: CGKeyCode, flags: CGEventFlags) {
        // A private event source ignores keys the user is physically holding (e.g. the trigger key),
        // so the target sees exactly ⌘V.
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            if let event { post(event) }
        }
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: InputActivity.ownEventMarker)
        if let testTargetPID { event.postToPid(testTargetPID) } else { event.post(tap: .cghidEventTap) }
    }

    /// Finds the key that types `character` in the current layout, so ⌘V works on Dvorak, AZERTY, etc.
    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let target = String(character)

        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                // With ⌘ held: layouts like "Dvorak – QWERTY ⌘" switch to QWERTY for shortcuts.
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
                )
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}

/// Keys typed and clicks made in other apps, so "scratch that" knows whether you've touched the
/// text since it was inserted. Driftflow's own synthetic keystrokes are marked and ignored, and
/// hot keys and clicks on the pill never reach a global monitor.
@MainActor
enum InputActivity {
    nonisolated static let ownEventMarker: Int64 = 0x44524654 // "DRFT"
    private static var lastActivity: Date?
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ownEventMarker { return }
            MainActor.assumeIsolated { lastActivity = Date() }
        }
    }

    /// True if anything happened since `date`, or if we can't tell (monitor not running).
    static func hasActivity(since date: Date) -> Bool {
        guard monitor != nil else { return true }
        return (lastActivity ?? .distantPast) > date
    }
}
