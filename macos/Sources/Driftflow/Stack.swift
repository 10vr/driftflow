import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Whether the app you're in has a text box selected, so a dictation isn't pasted into nothing.
/// Only a clear "no" counts: apps that don't say (or answer oddly) are treated as a text box, and
/// the dictation is pasted as usual.
enum TextBoxCheck {
    enum Result: Equatable {
        case textBox
        case noTextBox
        case unknown
    }

    /// Roles that are never typed into: lists, buttons, a page you're reading, the Finder desktop.
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXScrollArea", "AXRow", "AXCell", "AXColumn",
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
        "AXSlider", "AXImage", "AXLink", "AXStaticText", "AXTabGroup", "AXToolbar", "AXSplitGroup",
        "AXWindow", "AXSheet", "AXWebArea", "AXSegmentedControl",
    ]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// The focused element of app `pid` (the frontmost one when dictation ends).
    static func check(pid: pid_t) -> Result { inspect(pid: pid).result }

    static func inspect(pid: pid_t) -> (result: Result, detail: String) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1) // a hung app must not hold up the paste
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (.unknown, "no focused element (AX error \(error.rawValue))")
        }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        let role = string(element, kAXRoleAttribute) ?? "?"
        let subrole = string(element, kAXSubroleAttribute) ?? "-"
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let hasCaret = has(element, kAXSelectedTextRangeAttribute)
        let editable = has(element, "AXEditableAncestor") // web: inside a text box or editable page
        let detail = "\(role)/\(subrole) valueSettable=\(settable.boolValue) caret=\(hasCaret) editableAncestor=\(editable)"
        if textRoles.contains(role) || textRoles.contains(subrole) || editable || (settable.boolValue && hasCaret) {
            return (.textBox, detail)
        }
        // Anything that shows a caret might take text after all.
        return (nonTextRoles.contains(role) && !hasCaret && !settable.boolValue ? .noTextBox : .unknown, detail)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func has(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success && value != nil
    }
}

// MARK: - The stack

enum StackTabStyle: String, CaseIterable, Identifiable {
    case visible
    case faded
    case hidden

    var id: String { rawValue }
    var label: String {
        switch self {
        case .visible: "Always visible"
        case .faded: "Faded until you point at it"
        case .hidden: "Hidden (in the menu bar only)"
        }
    }
}

struct StackItem: Identifiable, Equatable, Codable {
    var id = UUID()
    let text: String
    let added: Date
}

/// Dictations waiting to be pasted, in the order you said them: ones added from the pill, all of
/// them in Stack Mode, and ones that had no text box to go into. They stay until you use or remove
/// them (an 11th pushes the oldest out), across restarts too: kept on this Mac next to History, and
/// only in memory when History is off.
@MainActor
final class DictationStack: ObservableObject {
    static let shared = DictationStack()
    static let capacity = 10

    /// Oldest first: pasting them all goes top to bottom.
    @Published private(set) var items: [StackItem] = [] { didSet { save() } }
    /// Put away with Hide: kept, just not on screen (Open Stack brings it back).
    @Published private(set) var hidden: Bool { didSet { UserDefaults.standard.set(hidden, forKey: "stackHidden") } }
    /// Counts additions, so the tab can bounce when something goes in.
    @Published private(set) var addedCount = 0
    private let fileURL = AppData.directory.appendingPathComponent("stack.json")

    private init() {
        hidden = UserDefaults.standard.bool(forKey: "stackHidden")
        guard AppSettings.shared.historyRetention != .off, let data = try? Data(contentsOf: fileURL) else { return }
        items = (try? JSONDecoder().decode([StackItem].self, from: data)) ?? []
    }

    /// Everything, in order, as one text (for Paste All and dragging the tab).
    var joined: String { items.map(\.text).joined(separator: " ") }

    func add(_ text: String) {
        items.append(StackItem(text: text, added: Date()))
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        hidden = false // something new went in: show where it went
        addedCount += 1
        StackPanel.shared.itemAdded()
    }

    func remove(_ ids: [UUID]) {
        items.removeAll { ids.contains($0.id) }
    }

    /// After Paste Last Dictation used the newest dictation, it's no longer waiting.
    func remove(text: String) {
        guard let item = items.last(where: { $0.text == text }) else { return }
        remove([item.id])
    }

    func clear() { items = [] }

    /// Hide: off the screen and out of Stack Mode, with everything kept.
    func hide() {
        hidden = true
        AppSettings.shared.stackMode = false
    }

    func show() { hidden = false }

    /// An empty stack opened from the menu: your last dictations, to paste again.
    func refillFromHistory() {
        items = HistoryStore.shared.entries.filter { $0.status == nil && !$0.text.isEmpty }
            .prefix(3)
            .reversed()
            .map { StackItem(text: $0.text, added: $0.date) }
    }

    private func save() {
        guard AppSettings.shared.historyRetention != .off, !items.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? FileManager.default.createDirectory(at: AppData.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: fileURL, options: [.atomic])
    }

    /// "just now", "5 min ago", "yesterday"…
    static func age(of item: StackItem, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(item.added) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes) min ago"
        case ..<(24 * 60): return "\(minutes / 60) hr ago"
        case ..<(48 * 60): return "yesterday"
        default: return "\(minutes / (24 * 60)) days ago"
        }
    }
}

// MARK: - Panel

@MainActor
final class StackPanelState: ObservableObject {
    @Published var expanded = false
    @Published var hovered: UUID?
    /// Full strength for a moment after something goes in, even when the tab is faded.
    @Published var peeking = false
    /// Kept open (a click on the tab, or Open Stack in the menu) until you click elsewhere.
    @Published var pinned = false
    /// Frames in the panel, reported by SwiftUI: each line (for hover) and the tab.
    var rowFrames: [UUID: CGRect] = [:]
    var tabRect: CGRect = .zero
    /// `--stack-demo`: open or closed regardless of the pointer.
    var forced: Bool?
}

/// The stack's tab at the bottom right of the screen and the list that grows out of it. Like the
/// pill, a transparent non-activating panel: clicks pass through everywhere except the tab and the
/// list, and using it never takes the focus away from the text box you're in.
///
/// It opens when the pointer rests on the tab (not when it brushes past), stays open a second
/// after the pointer leaves (small slips don't count), and closes at once when you click elsewhere.
@MainActor
final class StackPanel {
    static let shared = StackPanel()
    let state = StackPanelState()
    private var panel: NSPanel?
    private let canvas = NSSize(width: 410, height: 660)
    private var hitRect: CGRect = .zero
    private var timer: Timer?
    private var leftAt: Date?
    private var onTabSince: Date?
    private var wasPressed = false
    private var pressStartedInside = false
    private var peekWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    private static let openAfter: TimeInterval = 0.15
    private static let closeAfter: TimeInterval = 1.0

    func start() {
        guard cancellables.isEmpty else { return }
        let stack = DictationStack.shared, settings = AppSettings.shared
        stack.$items.map(\.isEmpty).removeDuplicates().map { _ in () }
            .merge(with: stack.$hidden.removeDuplicates().map { _ in () },
                   settings.$stackMode.removeDuplicates().map { _ in () },
                   settings.$stackTab.removeDuplicates().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place(on: nil) }
            .store(in: &cancellables)
    }

    /// Something just went in: bring the tab to the screen you're working on and show it clearly.
    func itemAdded() {
        refresh()
        place(on: nil)
        peekWork?.cancel()
        state.peeking = true
        let work = DispatchWorkItem { [weak self] in self?.state.peeking = false }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Open Stack in the menu: back on screen and open (with your last dictations if it's empty).
    func open() {
        let stack = DictationStack.shared
        stack.show()
        if stack.items.isEmpty { stack.refillFromHistory() }
        guard !stack.items.isEmpty || AppSettings.shared.stackMode else { return }
        state.pinned = true
        refresh()
        place(on: nil)
    }

    /// A click on the tab keeps the list open (or lets it close again).
    func toggleTabPin() {
        state.pinned.toggle()
        if state.pinned { state.expanded = true }
    }

    func hide() {
        state.pinned = false
        DictationStack.shared.hide()
    }

    private var wanted: Bool {
        let stack = DictationStack.shared, settings = AppSettings.shared
        guard !stack.hidden, !stack.items.isEmpty || settings.stackMode else { return false }
        return settings.stackTab != .hidden || state.pinned
    }

    private func refresh() {
        guard wanted else {
            state.pinned = false
            state.expanded = false
            panel?.orderOut(nil)
            timer?.invalidate()
            timer = nil
            return
        }
        guard panel?.isVisible != true else {
            if state.pinned { track(fast: true) }
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        place(on: nil)
        panel.appearance = HUDController.systemAppearance
        panel.orderFrontRegardless()
        track(fast: state.pinned)
    }

    func place(on screen: NSScreen?) {
        guard let panel, let screen = screen ?? HUDController.activeScreen() else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - canvas.width, y: visible.minY))
    }

    /// 20 times a second while closed (only to notice the pointer arriving), every frame while open.
    private func track(fast: Bool) {
        let interval = fast ? 1.0 / 60 : 0.05
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            onMainThread { self?.tick() }
        }
        timer.tolerance = fast ? 0 : 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y) // SwiftUI: top-left origin
        let now = Date()
        let overTab = state.tabRect.insetBy(dx: -4, dy: -4).contains(local)
        var open = state.expanded
        if let forced = state.forced {
            open = forced
        } else {
            // Small slips past the edge don't count while it's open.
            let inside = hitRect.insetBy(dx: open ? -24 : -4, dy: open ? -24 : -4).contains(local)
            let pressed = NSEvent.pressedMouseButtons != 0
            if pressed, !wasPressed { pressStartedInside = inside }
            wasPressed = pressed
            if open {
                if inside { leftAt = nil } else if leftAt == nil { leftAt = now }
                if pressed, !pressStartedInside {
                    // A click somewhere else: close now.
                    state.pinned = false
                    open = false
                } else {
                    // Dragging a line (or the tab) out keeps it open until the drop.
                    open = state.pinned || inside || pressed || now.timeIntervalSince(leftAt ?? now) < Self.closeAfter
                }
            } else {
                onTabSince = overTab ? (onTabSince ?? now) : nil
                open = state.pinned || onTabSince.map { now.timeIntervalSince($0) >= Self.openAfter } ?? false
            }
            if !open { leftAt = nil }
        }
        // Clicks reach the tab even before the list opens.
        let takesClicks = open || overTab
        if panel.ignoresMouseEvents == takesClicks { panel.ignoresMouseEvents = !takesClicks }
        if state.expanded != open {
            state.expanded = open
            track(fast: open)
            if !open, AppSettings.shared.stackTab == .hidden { refresh() } // opened from the menu only
        }
        guard state.forced == nil else { return }
        let row = open ? state.rowFrames.first(where: { $0.value.contains(local) })?.key : nil
        if state.hovered != row { state.hovered = row }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: StackView(stack: .shared, state: state, settings: .shared) { [weak self] rect in
            self?.hitRect = rect
        })
        host.frame = NSRect(origin: .zero, size: canvas)
        panel.contentView = host
        return panel
    }

    // MARK: Demo

    /// `--stack-demo <folder>`: the tab and the open list over black and white, captured to PNGs.
    /// Run with DRIFTFLOW_DATA_DIR set, so the demo's lines don't land in your real stack.
    func runDemo(to directory: URL) async {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let settings = AppSettings.shared
        let saved = (settings.stackTab, settings.stackMode, DictationStack.shared.hidden)
        let backdrop = NSWindow(contentRect: NSRect(x: visible.maxX - canvas.width - 20, y: visible.minY, width: canvas.width + 20, height: canvas.height),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.isReleasedWhenClosed = false
        DictationStack.shared.clear()
        for text in ["Hi Sarah, just following up on the shoot schedule for tomorrow.",
                     "Can we move the Thursday call to ten? The studio is booked until nine thirty, so the crew can set up after that and we still finish the interviews before lunch.",
                     "Also remind me to send the invoice to Daniel before Friday."] {
            DictationStack.shared.add(text)
        }
        start()
        place(on: screen)
        // The capture region in global top-left coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let region = CGRect(x: visible.maxX - canvas.width, y: primaryHeight - visible.minY - canvas.height,
                            width: canvas.width, height: canvas.height)
        for dark in [true, false] {
            backdrop.backgroundColor = dark ? .black : .white
            backdrop.orderFrontRegardless()
            panel?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let name = dark ? "black" : "white"
            settings.stackMode = false
            for style in [StackTabStyle.faded, .visible] {
                settings.stackTab = style
                state.forced = false
                state.peeking = false
                try? await Task.sleep(for: .milliseconds(600))
                DictationController.capture(region, to: directory.appendingPathComponent("\(name)-tab-\(style.rawValue).png"))
                // What the pointer is tested against: both must be real rectangles.
                print("tab \(state.tabRect) · clickable area \(hitRect)")
            }
            state.forced = true
            try? await Task.sleep(for: .milliseconds(700))
            DictationController.capture(region, to: directory.appendingPathComponent("\(name)-open.png"))
            state.hovered = DictationStack.shared.items.dropFirst().first?.id
            try? await Task.sleep(for: .milliseconds(400))
            DictationController.capture(region, to: directory.appendingPathComponent("\(name)-hover.png"))
            state.hovered = nil
            settings.stackMode = true
            state.forced = false
            try? await Task.sleep(for: .milliseconds(600))
            DictationController.capture(region, to: directory.appendingPathComponent("\(name)-tab-stacking.png"))
        }
        settings.stackTab = saved.0
        settings.stackMode = saved.1
        if saved.2 { DictationStack.shared.hide() }
        NSApp.terminate(nil)
    }
}

// MARK: - Views

private struct StackHitRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        value = value == .zero ? next : (next == .zero ? value : value.union(next))
    }
}

private struct StackTabRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    // Views without the tab (the list, the backgrounds) report .zero: they mustn't wipe it out.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct StackRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct StackView: View {
    @ObservedObject var stack: DictationStack
    @ObservedObject var state: StackPanelState
    @ObservedObject var settings: AppSettings
    let reportHitRect: (CGRect) -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            VStack(alignment: .trailing, spacing: 8) {
                if state.expanded {
                    card.transition(.scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity))
                }
                tab
            }
            .background(frame(StackHitRectKey.self))
            .padding(.trailing, 14)
            .padding(.bottom, 12)
        }
        .coordinateSpace(name: "stack")
        .onPreferenceChange(StackHitRectKey.self) { reportHitRect($0) }
        .onPreferenceChange(StackTabRectKey.self) { state.tabRect = $0 }
        .onPreferenceChange(StackRowFramesKey.self) { state.rowFrames = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: state.expanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: stack.items)
        .animation(.easeOut(duration: 0.12), value: state.hovered)
        .animation(.easeInOut(duration: 0.2), value: state.peeking)
    }

    private var faded: Bool { settings.stackTab == .faded && !state.expanded && !state.peeking && !settings.stackMode }

    private var tab: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(Brand.violet)
                .symbolEffect(.bounce, value: stack.addedCount)
            Group {
                if settings.stackMode {
                    Text(stack.items.isEmpty ? "Stacking" : "Stacking · \(stack.items.count)")
                } else {
                    Text("\(stack.items.count)")
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 13)
        .frame(height: 30)
        .modifier(Capsule().surface(tint: state.pinned ? Brand.violet.opacity(0.18) : nil))
        .shadow(color: .black.opacity(faded ? 0 : 0.16), radius: 10, y: 4)
        .opacity(faded ? 0.4 : 1)
        // Click: keep it open. Drag: drop everything, in order.
        .overlay {
            StackDragSource(text: stack.joined, preview: stack.items.count == 1 ? stack.items[0].text : "\(stack.items.count) dictations",
                            onClick: { StackPanel.shared.toggleTabPin() },
                            onDropped: { [ids = stack.items.map(\.id)] in DictationStack.shared.remove(ids) })
        }
        .background(frame(StackTabRectKey.self))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(settings.stackMode ? "Stacking" : "Stack")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if !stack.items.isEmpty {
                    Text("\(stack.items.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !stack.items.isEmpty {
                    pillButton("Clear", help: "Empty the stack") { DictationStack.shared.clear() }
                }
                pillButton("Hide", help: "Put the stack away (Stack Mode turns off). Open Stack in the menu brings everything back.") {
                    StackPanel.shared.hide()
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.bottom, 6)

            if stack.items.isEmpty {
                Text("New dictations stack up here.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
            } else {
                // Everything at full length; it scrolls only once it's taller than the space.
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 30)) { context in rows(now: context.date) }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 470)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(stack.items.isEmpty ? "" : "Click or drag a line")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                if stack.items.count > 1 {
                    pillButton("Paste All", help: "Paste them all at your cursor, top to bottom. Or drag the tab into a text box.") {
                        DictationController.shared.pasteAllFromStack()
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.top, 6)
        }
        .padding(8)
        .frame(width: 370)
        .modifier(RoundedRectangle(cornerRadius: 18, style: .continuous).surface())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private func rows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(stack.items.enumerated()), id: \.element.id) { index, item in
                row(item, number: index + 1, now: now)
            }
        }
    }

    private func row(_ item: StackItem, number: Int, now: Date) -> some View {
        let hovered = state.hovered == item.id
        return HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.violet)
                .frame(minWidth: 14, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(DictationStack.age(of: item, now: now))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                DictationStack.shared.remove([item.id])
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Remove from the stack")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Brand.violet.opacity(hovered ? 0.14 : 0))
        }
        // Click or drag anywhere on the line except ✕.
        .overlay(alignment: .leading) {
            StackDragSource(text: item.text, preview: item.text,
                            onClick: { DictationController.shared.paste(fromStack: item) },
                            onDropped: { DictationStack.shared.remove([item.id]) })
                .padding(.trailing, 30)
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: StackRowFramesKey.self, value: [item.id: proxy.frame(in: .named("stack"))])
        })
    }

    private func pillButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.primary.opacity(0.1)))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func frame<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGRect {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.frame(in: .named("stack")))
        }
    }
}

/// Clicking pastes (or, on the tab, keeps the list open); dragging drops the text wherever you let
/// go, in any app. In AppKit, because only a dragging source learns whether the drop was taken, and
/// what was dropped somewhere should leave the stack.
private struct StackDragSource: NSViewRepresentable {
    let text: String
    let preview: String
    let onClick: () -> Void
    let onDropped: () -> Void

    func makeNSView(context: Context) -> StackDragView { StackDragView() }

    func updateNSView(_ view: StackDragView, context: Context) {
        view.text = text
        view.preview = preview
        view.onClick = onClick
        view.onDropped = onDropped
    }
}

final class StackDragView: NSView, NSDraggingSource {
    var text = ""
    var preview = ""
    var onClick: () -> Void = {}
    var onDropped: () -> Void = {}
    private var downAt: NSPoint?
    private var dragging = false

    // The panel never becomes key: the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, !dragging, !text.isEmpty else { return }
        let point = event.locationInWindow
        guard hypot(point.x - downAt.x, point.y - downAt.y) > 4 else { return }
        dragging = true
        let image = Self.dragImage(for: preview)
        let local = convert(point, from: nil)
        let item = NSDraggingItem(pasteboardWriter: text as NSString)
        item.setDraggingFrame(NSRect(x: local.x - 14, y: local.y - image.size.height / 2, width: image.size.width, height: image.size.height),
                              contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        if downAt != nil, !dragging { onClick() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        downAt = nil
        if operation != [] { onDropped() }
    }

    /// The start of the text on a small card, under the pointer while you drag.
    private static func dragImage(for text: String) -> NSImage {
        let shown = text.count > 42 ? String(text.prefix(41)) + "…" : text
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                         .foregroundColor: NSColor.labelColor]
        let size = (shown as NSString).size(withAttributes: attributes)
        return NSImage(size: NSSize(width: ceil(size.width) + 24, height: ceil(size.height) + 12), flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            (shown as NSString).draw(at: NSPoint(x: 12, y: 6), withAttributes: attributes)
            return true
        }
    }
}
