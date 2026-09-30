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

enum StackPasteChoice: String, CaseIterable, Identifiable {
    case stack
    case pinsAndStack
    case pins

    var id: String { rawValue }
    var label: String {
        switch self {
        case .stack: "The stack"
        case .pinsAndStack: "Pinned lines, then the stack"
        case .pins: "Pinned lines only"
        }
    }
}

/// Where a line dragged within the stack would go: above or below another line.
struct StackDropMarker: Equatable {
    let id: UUID
    let above: Bool
}

struct StackItem: Identifiable, Equatable, Codable {
    var id = UUID()
    let text: String
    let added: Date
    /// Pinned lines stay after you paste them, until you remove them.
    var pinned = false

    init(text: String, added: Date) {
        self.text = text
        self.added = added
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        added = try values.decode(Date.self, forKey: .added)
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// Dictations waiting to be pasted, in the order you said them: ones added from the pill, all of
/// them in Stack Mode, and ones that had no text box to go into. They stay until you use or remove
/// them (an 11th pushes the oldest out), across restarts too: kept on this Mac next to History, and
/// only in memory when History is off. Pinned lines (up to 5) sit apart: they're reused, not used up.
@MainActor
final class DictationStack: ObservableObject {
    static let shared = DictationStack()
    static let capacity = 10
    static let maxPins = 5

    /// Oldest first: pasting them all goes top to bottom.
    @Published private(set) var items: [StackItem] = [] { didSet { save() } }
    /// Put away with Hide: kept, just not on screen (Open Stack brings it back).
    @Published private(set) var hidden: Bool { didSet { UserDefaults.standard.set(hidden, forKey: "stackHidden") } }
    /// Once you've used the stack, its tab stays on screen (it's also the Stack Mode switch); before
    /// that it only appears when something goes in.
    @Published private(set) var used: Bool { didSet { UserDefaults.standard.set(used, forKey: "stackUsed") } }
    /// Counts additions, so the tab can bounce when something goes in.
    @Published private(set) var addedCount = 0
    private let fileURL = AppData.directory.appendingPathComponent("stack.json")

    private init() {
        hidden = UserDefaults.standard.bool(forKey: "stackHidden")
        used = UserDefaults.standard.bool(forKey: "stackUsed")
        guard AppSettings.shared.historyRetention != .off, let data = try? Data(contentsOf: fileURL) else { return }
        items = (try? JSONDecoder().decode([StackItem].self, from: data)) ?? []
    }

    var pins: [StackItem] { items.filter(\.pinned) }
    /// The stack proper: what Paste All, dragging the tab and Clear work on.
    var queue: [StackItem] { items.filter { !$0.pinned } }
    /// What Paste and dragging the tab put in (Settings › Stack, or the ▾ next to Paste).
    var pasteItems: [StackItem] {
        switch AppSettings.shared.stackPaste {
        case .stack: queue
        case .pinsAndStack: pins + queue
        case .pins: pins
        }
    }
    /// Those, in order, as one text.
    var joined: String { pasteItems.map(\.text).joined(separator: " ") }

    @discardableResult
    func add(_ text: String) -> UUID {
        let item = StackItem(text: text, added: Date())
        items.append(item)
        let queued = queue
        if queued.count > Self.capacity {
            let oldest = Set(queued.prefix(queued.count - Self.capacity).map(\.id))
            items.removeAll { oldest.contains($0.id) }
        }
        hidden = false // something new went in: show where it went
        used = true
        addedCount += 1
        StackPanel.shared.itemAdded()
        return item.id
    }

    /// ✕ on a line: gone, pinned or not.
    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Pasted or dropped: out of the stack, except pinned lines, which stay for next time.
    func used(_ ids: [UUID]) {
        items.removeAll { !$0.pinned && ids.contains($0.id) }
    }

    /// After Paste Last Dictation used the newest dictation, it's no longer waiting.
    func used(text: String) {
        guard let item = queue.last(where: { $0.text == text }) else { return }
        used([item.id])
    }

    /// Returns false when there are already `maxPins` pins.
    @discardableResult
    func togglePin(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        if !items[index].pinned, pins.count >= Self.maxPins { return false }
        items[index].pinned.toggle()
        return true
    }

    /// Dragged within the stack: to just above or below another line (of the same kind).
    func move(_ id: UUID, to marker: StackDropMarker) {
        guard id != marker.id, let item = items.first(where: { $0.id == id }) else { return }
        var reordered = items.filter { $0.id != id }
        guard let target = reordered.firstIndex(where: { $0.id == marker.id }) else { return }
        reordered.insert(item, at: marker.above ? target : target + 1)
        items = reordered
    }

    /// The Stacks page: reordering by dragging in its lists.
    func moveQueue(from source: IndexSet, to destination: Int) {
        var queue = self.queue
        queue.move(fromOffsets: source, toOffset: destination)
        items = pins + queue
    }

    func movePins(from source: IndexSet, to destination: Int) {
        var pins = self.pins
        pins.move(fromOffsets: source, toOffset: destination)
        items = pins + queue
    }

    /// Save Stack: the stack's lines leave (to be saved); pins stay.
    func takeQueue() -> [StackItem] {
        let taken = queue
        clear()
        return taken
    }

    /// Use Again: a saved stack's lines become the stack.
    func load(_ lines: [StackItem]) {
        items = pins + lines.map { var line = $0; line.pinned = false; return line }
    }

    /// Clear: empties the stack; pins stay.
    func clear() { items.removeAll { !$0.pinned } }

    /// Hide: off the screen and out of Stack Mode, with everything kept.
    func hide() {
        hidden = true
        AppSettings.shared.stackMode = false
    }

    func show() {
        hidden = false
        used = true
    }

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
    /// Opened from the menu: stays open until you click elsewhere or close it.
    @Published var keptOpen = false
    /// The lines' natural height, to scroll only when they don't fit.
    @Published var linesHeight: CGFloat = 0
    /// While a line is dragged within the stack: where it would go.
    @Published var dropMarker: StackDropMarker?
    /// A menu from the stack (▾ next to Paste, right-click on the tab) is open: stay open under it.
    var menuOpen = false
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
/// after the pointer leaves (small slips don't count), and closes at once when you click elsewhere,
/// press Esc or click ✕.
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

    var isOpen: Bool { state.expanded }

    func start() {
        guard cancellables.isEmpty else { return }
        let stack = DictationStack.shared, settings = AppSettings.shared
        stack.$items.map(\.isEmpty).removeDuplicates().map { _ in () }
            .merge(with: stack.$hidden.removeDuplicates().map { _ in () },
                   stack.$used.removeDuplicates().map { _ in () },
                   settings.$stackMode.removeDuplicates().map { _ in () },
                   settings.$stackTab.removeDuplicates().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place(on: nil) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.state.menuOpen = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in self?.state.menuOpen = false }
            .store(in: &cancellables)
    }

    // MARK: Reordering

    /// A line being dragged: where it would land if dropped here (nil outside the list).
    func dragMoved(_ id: UUID, to screenPoint: NSPoint) {
        let marker = self.marker(for: id, at: screenPoint)
        if state.dropMarker != marker { state.dropMarker = marker }
    }

    /// Dropped into an app: used. Dropped within the list: moved there.
    func dragEnded(_ id: UUID, at screenPoint: NSPoint, operation: NSDragOperation) {
        defer { state.dropMarker = nil }
        if operation != [] {
            DictationStack.shared.used([id])
        } else if let marker = marker(for: id, at: screenPoint) {
            DictationStack.shared.move(id, to: marker)
        }
    }

    private func marker(for id: UUID, at screenPoint: NSPoint) -> StackDropMarker? {
        guard let panel, let item = DictationStack.shared.items.first(where: { $0.id == id }) else { return nil }
        let local = CGPoint(x: screenPoint.x - panel.frame.minX, y: panel.frame.maxY - screenPoint.y)
        // Lines of the same kind (pinned or not), top to bottom.
        let frames = DictationStack.shared.items.filter { $0.pinned == item.pinned }
            .compactMap { line in state.rowFrames[line.id].map { (id: line.id, frame: $0) } }
        guard let first = frames.first, let last = frames.last,
              local.x > first.frame.minX - 20, local.x < first.frame.maxX + 20,
              local.y > first.frame.minY - 24, local.y < last.frame.maxY + 24 else { return nil }
        let marker = frames.first(where: { local.y < $0.frame.midY }).map { StackDropMarker(id: $0.id, above: true) }
            ?? StackDropMarker(id: last.id, above: false)
        // Where it already is: nothing to show.
        let order = frames.map(\.id)
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: marker.id) else { return nil }
        let destination = marker.above ? to : to + 1
        return destination == from || destination == from + 1 ? nil : marker
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
        state.keptOpen = true
        refresh()
        place(on: nil)
    }

    /// ✕ or Esc: the list closes; the stack and its tab stay.
    func close() {
        guard state.expanded else { return }
        state.keptOpen = false
        state.expanded = false
        state.hovered = nil
        leftAt = nil
        onTabSince = nil
        panel?.ignoresMouseEvents = true
        track(fast: false)
        if AppSettings.shared.stackTab == .hidden { refresh() }
    }

    /// Hide Stack (right-click on the tab): the tab goes away and Stack Mode turns off; everything is kept.
    func hide() {
        state.keptOpen = false
        DictationStack.shared.hide()
        DictationController.shared.showToast(HUDToast(icon: "rectangle.stack",
                                                      text: "Stack hidden, with everything in it. Open Stack in the menu bar brings it back."), for: 4)
    }

    private var wanted: Bool {
        let stack = DictationStack.shared, settings = AppSettings.shared
        guard !stack.hidden, stack.used || !stack.items.isEmpty || settings.stackMode else { return false }
        return settings.stackTab != .hidden || state.keptOpen
    }

    private func refresh() {
        guard wanted else {
            state.keptOpen = false
            state.expanded = false
            panel?.orderOut(nil)
            timer?.invalidate()
            timer = nil
            return
        }
        guard panel?.isVisible != true else {
            if state.keptOpen { track(fast: true) }
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        place(on: nil)
        panel.appearance = HUDController.systemAppearance
        panel.orderFrontRegardless()
        track(fast: state.keptOpen)
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
                if pressed, !pressStartedInside, !state.menuOpen {
                    // A click somewhere else: close now.
                    state.keptOpen = false
                    open = false
                } else {
                    // Dragging a line (or the tab) out keeps it open until the drop.
                    open = state.keptOpen || state.menuOpen || inside || pressed || now.timeIntervalSince(leftAt ?? now) < Self.closeAfter
                }
            } else {
                onTabSince = overTab && !pressed ? (onTabSince ?? now) : nil
                open = state.keptOpen || onTabSince.map { now.timeIntervalSince($0) >= Self.openAfter } ?? false
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

    /// Right-click on the tab.
    func tabMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let target = MenuAction(action)
            item.target = target
            item.representedObject = target // the menu item doesn't retain its target
            return item
        }
        let mode = item("Stack Mode") { DictationController.shared.toggleStackMode() }
        mode.state = AppSettings.shared.stackMode ? .on : .off
        menu.addItem(mode)
        let save = item("Save Stack") { StackPanel.shared.saveCurrentStack() }
        save.isEnabled = !DictationStack.shared.queue.isEmpty
        menu.addItem(save)
        menu.addItem(item("Saved Stacks…") { DictationController.shared.openSettings(.stacks) })
        menu.addItem(.separator())
        menu.addItem(item("Hide Stack") { StackPanel.shared.hide() })
        return menu
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
        let stack = DictationStack.shared
        for item in stack.items { stack.remove(item.id) }
        let many = ProcessInfo.processInfo.environment["DRIFTFLOW_DEMO_MANY"] != nil // a stack long enough to scroll
        let lines = ["Thanks for your time today, talk soon.",
                     "Hi Sarah, just following up on the shoot schedule for tomorrow.",
                     "Can we move the Thursday call to ten? The studio is booked until nine thirty, so the crew can set up after that and we still finish the interviews before lunch.",
                     "Also remind me to send the invoice to Daniel before Friday."]
        for text in many ? lines + lines.dropFirst() + lines.dropFirst() : lines { stack.add(text) }
        if let first = stack.items.first { stack.togglePin(first.id) }
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
            print("lines \(state.linesHeight) pt tall")
            state.hovered = stack.queue.dropFirst().first?.id
            state.dropMarker = stack.queue.first.map { StackDropMarker(id: $0.id, above: true) } // a line being dragged to the top
            try? await Task.sleep(for: .milliseconds(400))
            DictationController.capture(region, to: directory.appendingPathComponent("\(name)-hover.png"))
            state.hovered = nil
            state.dropMarker = nil
            settings.stackMode = true
            state.forced = false
            try? await Task.sleep(for: .milliseconds(600))
            DictationController.capture(region, to: directory.appendingPathComponent("\(name)-tab-stacking.png"))
        }
        backdrop.orderOut(nil)
        // The Stacks page, with one saved stack and the current one.
        StackLibrary.shared.saveCurrent()
        for text in ["Call me back when you can, thanks.", "The files for the shoot are in the shared folder."] { stack.add(text) }
        DictationController.shared.openSettings(.stacks)
        try? await Task.sleep(for: .seconds(1.5))
        FilesWindow.capture(NSApp.windows.first { $0.isVisible && $0.title == SettingsView.Pane.stacks.title },
                            to: directory.appendingPathComponent("stacks-page.png"))
        settings.stackTab = saved.0
        settings.stackMode = saved.1
        if saved.2 { stack.hide() }
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

private struct StackLinesHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct StackView: View {
    @ObservedObject var stack: DictationStack
    @ObservedObject var state: StackPanelState
    @ObservedObject var settings: AppSettings
    let reportHitRect: (CGRect) -> Void
    /// Taller than this, the lines scroll.
    private let maxLinesHeight: CGFloat = 470

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
        .onPreferenceChange(StackLinesHeightKey.self) { height in
            if abs(height - state.linesHeight) > 0.5 { state.linesHeight = height }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: state.expanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: stack.items)
        .animation(.easeOut(duration: 0.12), value: state.hovered)
        .animation(.easeInOut(duration: 0.2), value: state.peeking)
    }

    private var faded: Bool { settings.stackTab == .faded && !state.expanded && !state.peeking && !settings.stackMode }

    private var tab: some View {
        let count = stack.items.count // pinned lines count too: they're in the stack
        let dropping = stack.pasteItems.count
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(Brand.violet)
                .symbolEffect(.bounce, value: stack.addedCount)
            Group {
                if settings.stackMode {
                    Text(count == 0 ? "Stacking" : "Stacking · \(count)")
                } else if count > 0 {
                    Text("\(count)")
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 13)
        .frame(height: 30)
        .modifier(Capsule().surface(tint: settings.stackMode ? Brand.violet.opacity(0.22) : nil))
        .shadow(color: .black.opacity(faded ? 0 : 0.16), radius: 10, y: 4)
        .opacity(faded ? 0.4 : 1)
        // Click: Stack Mode on or off. Drag: drop the whole stack, in order. Right-click: Hide Stack.
        .overlay {
            StackDragSource(text: stack.joined, preview: dropping == 1 ? stack.joined : "\(dropping) dictations",
                            onClick: { DictationController.shared.toggleStackMode() },
                            onEnded: { [ids = stack.pasteItems.map(\.id)] _, operation in
                                if operation != [] { DictationStack.shared.used(ids) }
                            },
                            menu: { StackPanel.shared.tabMenu() })
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
                if !stack.queue.isEmpty {
                    circleButton("square.and.arrow.down", help: "Save this stack for later and start a new one (Saved Stacks in the main window)") {
                        StackPanel.shared.saveCurrentStack()
                    }
                }
                circleButton("xmark", help: "Close (Esc)") { StackPanel.shared.close() }
            }
            .padding(.leading, 10)
            .padding(.trailing, 2)
            .padding(.bottom, 4)

            if stack.items.isEmpty {
                Text("New dictations stack up here.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
            } else {
                // Everything at full length; it only becomes a scrolling list once it doesn't fit,
                // so no scroll bar shows (or flashes) when there's nothing to scroll.
                if state.linesHeight > maxLinesHeight {
                    ScrollView { lines }
                        .frame(height: maxLinesHeight)
                } else {
                    lines
                }
            }

            if !stack.items.isEmpty {
                HStack(spacing: 8) {
                    if !stack.queue.isEmpty {
                        textButton("Clear", help: "Empty the stack (pinned lines stay)") { DictationStack.shared.clear() }
                    }
                    Text("Click or drag a line")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    if stack.items.count > 1 {
                        pasteButton
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 4)
                .padding(.top, 6)
            }
        }
        .padding(8)
        .frame(width: 370)
        .modifier(RoundedRectangle(cornerRadius: 18, style: .continuous).surface())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var lines: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 2) {
                let pins = stack.pins, queue = stack.queue
                if !pins.isEmpty {
                    sectionLabel("Pinned")
                    ForEach(pins) { row($0, number: nil, now: context.date) }
                    if !queue.isEmpty {
                        Divider().padding(.horizontal, 10).padding(.vertical, 4)
                    }
                }
                ForEach(Array(queue.enumerated()), id: \.element.id) { index, item in
                    row(item, number: index + 1, now: context.date)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: StackLinesHeightKey.self, value: proxy.size.height)
        })
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 2)
    }

    private func row(_ item: StackItem, number: Int?, now: Date) -> some View {
        let hovered = state.hovered == item.id
        return HStack(alignment: .top, spacing: 8) {
            Group {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(Brand.violet)
            .frame(minWidth: 14, alignment: .trailing)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.pinned ? "stays after you paste it" : DictationStack.age(of: item, now: now))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                iconButton(item.pinned ? "pin.slash" : "pin", help: item.pinned ? "Unpin" : "Pin: keep it after you paste it") {
                    if !DictationStack.shared.togglePin(item.id) {
                        DictationController.shared.showToast(HUDToast(icon: "pin", text: "You can pin up to \(DictationStack.maxPins) lines. Unpin one first."), for: 3)
                    }
                }
                .opacity(hovered ? 1 : 0)
                iconButton("xmark", help: "Remove") { DictationStack.shared.remove(item.id) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Brand.violet.opacity(hovered ? 0.14 : 0))
        }
        // Click or drag anywhere on the line except its buttons.
        .overlay(alignment: .leading) {
            StackDragSource(text: item.text, preview: item.text,
                            onClick: { DictationController.shared.paste(fromStack: item) },
                            onEnded: { point, operation in StackPanel.shared.dragEnded(item.id, at: point, operation: operation) },
                            onMoved: { point in StackPanel.shared.dragMoved(item.id, to: point) })
                .padding(.trailing, 52)
        }
        // Where a dragged line would go.
        .overlay(alignment: state.dropMarker?.above == false ? .bottom : .top) {
            if state.dropMarker?.id == item.id {
                Capsule().fill(Brand.violet).frame(height: 2).padding(.horizontal, 8).offset(y: state.dropMarker?.above == true ? -2 : 2)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: StackRowFramesKey.self, value: [item.id: proxy.frame(in: .named("stack"))])
        })
    }

    /// Paste at your cursor; ▾ chooses what's included (remembered, also in Settings › Stack).
    /// One capsule, the same height as Clear: paste on the left, the ▾ choice on the right.
    private var pasteButton: some View {
        HStack(spacing: 0) {
            Button {
                DictationController.shared.pasteAllFromStack()
            } label: {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 34, height: footerHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Paste \(settings.stackPaste.label.lowercased()) at your cursor, in order. Or drag the tab into a text box.")
            Rectangle()
                .fill(.primary.opacity(0.15))
                .frame(width: 1, height: 14)
            Menu {
                Picker("Paste Puts In", selection: $settings.stackPaste) {
                    ForEach(StackPasteChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 24, height: footerHeight)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose what Paste puts in")
        }
        .background(Capsule().fill(.primary.opacity(0.1)))
    }

    private let footerHeight: CGFloat = 26

    /// ✕ and Save at the top: small round buttons, like the pill's.
    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.primary.opacity(0.08)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func textButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .frame(height: footerHeight)
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

/// Clicking pastes (on the tab: switches Stack Mode); dragging drops the text wherever you let go,
/// in any app. In AppKit, because only a dragging source learns whether the drop was taken, and
/// what was dropped somewhere should leave the stack.
private struct StackDragSource: NSViewRepresentable {
    let text: String
    let preview: String
    let onClick: () -> Void
    /// Where the drag ended, and whether an app took the drop (an empty operation: nothing did).
    let onEnded: (NSPoint, NSDragOperation) -> Void
    var onMoved: ((NSPoint) -> Void)?
    var menu: (() -> NSMenu)?

    func makeNSView(context: Context) -> StackDragView { StackDragView() }

    func updateNSView(_ view: StackDragView, context: Context) {
        view.text = text
        view.preview = preview
        view.onClick = onClick
        view.onEnded = onEnded
        view.onMoved = onMoved
        view.makeMenu = menu
    }
}

final class StackDragView: NSView, NSDraggingSource {
    var text = ""
    var preview = ""
    var onClick: () -> Void = {}
    var onEnded: (NSPoint, NSDragOperation) -> Void = { _, _ in }
    var onMoved: ((NSPoint) -> Void)?
    var makeMenu: (() -> NSMenu)?
    private var downAt: NSPoint?
    private var dragging = false

    // The panel never becomes key: the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        // Control-click is a right-click.
        if event.modifierFlags.contains(.control), let menu = makeMenu?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
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

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        onMoved?(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        downAt = nil
        onEnded(screenPoint, operation)
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
