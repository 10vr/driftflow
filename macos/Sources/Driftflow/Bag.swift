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

// MARK: - The bag

enum BagTabStyle: String, CaseIterable, Identifiable {
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

struct BagItem: Identifiable, Equatable, Codable {
    var id = UUID()
    let text: String
    let added: Date
}

/// Dictations waiting to be pasted: ones you put in the bag from the pill, and ones that had no
/// text box to go into. The newest is first. They stay until you use or remove them (a fourth
/// pushes the oldest out), across restarts too: kept on this Mac next to History, and only in
/// memory when History is off.
@MainActor
final class DictationBag: ObservableObject {
    static let shared = DictationBag()
    static let capacity = 3

    @Published private(set) var items: [BagItem] = [] { didSet { save() } }
    /// Counts additions, so the tab can bounce when something goes in.
    @Published private(set) var addedCount = 0
    private let fileURL = AppData.directory.appendingPathComponent("bag.json")

    private init() {
        guard AppSettings.shared.historyRetention != .off, let data = try? Data(contentsOf: fileURL) else { return }
        items = (try? JSONDecoder().decode([BagItem].self, from: data)) ?? []
    }

    func add(_ text: String) {
        items.insert(BagItem(text: text, added: Date()), at: 0)
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
        addedCount += 1
        BagPanel.shared.itemAdded()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// An empty bag opened from the menu: your last dictations, to paste again.
    func refillFromHistory() {
        items = HistoryStore.shared.entries.filter { $0.status == nil && !$0.text.isEmpty }
            .prefix(Self.capacity)
            .map { BagItem(text: $0.text, added: $0.date) }
    }

    private func save() {
        guard AppSettings.shared.historyRetention != .off, !items.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? FileManager.default.createDirectory(at: AppData.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: fileURL, options: [.atomic])
    }

    /// After Paste Last Dictation used the newest dictation, it's no longer waiting.
    func remove(text: String) {
        guard let item = items.first(where: { $0.text == text }) else { return }
        remove(item.id)
    }

    /// "just now", "5 min ago", "yesterday"…
    static func age(of item: BagItem, now: Date = Date()) -> String {
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
final class BagPanelState: ObservableObject {
    @Published var expanded = false
    @Published var hovered: UUID?
    /// Full strength for a moment after something goes in, even when the tab is faded.
    @Published var peeking = false
    /// Each row's frame in the panel (for hover), reported by SwiftUI.
    var rowFrames: [UUID: CGRect] = [:]
    /// `--bag-demo`: open or closed regardless of the pointer.
    var forced: Bool?
    /// Opened from the menu: stays open until the pointer has been in and left again (or it never
    /// comes, `pinnedUntil`), even with the tab hidden.
    var pinned = false
    var pinnedEntered = false
    var pinnedUntil = Date.distantPast
}

/// The bag's tab at the bottom right of the screen and the list that slides up from it. Like the
/// pill, a transparent non-activating panel: clicks pass through everywhere except the tab and the
/// list, and using it never takes the focus away from the text box you're in.
@MainActor
final class BagPanel {
    static let shared = BagPanel()
    let state = BagPanelState()
    private var panel: NSPanel?
    private let canvas = NSSize(width: 380, height: 440)
    private var hitRect: CGRect = .zero
    private var timer: Timer?
    private var leftAt: Date?
    private var peekWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        guard cancellables.isEmpty else { return }
        DictationBag.shared.$items.map(\.isEmpty).removeDuplicates()
            .combineLatest(AppSettings.shared.$bagTab.removeDuplicates())
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
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

    /// Open Bag in the menu: the list, open, until you've used it (with your last dictations if it's empty).
    func open() {
        if DictationBag.shared.items.isEmpty { DictationBag.shared.refillFromHistory() }
        guard !DictationBag.shared.items.isEmpty else { return }
        state.pinned = true
        state.pinnedEntered = false
        state.pinnedUntil = Date().addingTimeInterval(10)
        refresh()
        place(on: nil)
        track(fast: true)
    }

    private func refresh() {
        guard !DictationBag.shared.items.isEmpty, AppSettings.shared.bagTab != .hidden || state.pinned else {
            state.pinned = false
            panel?.orderOut(nil)
            timer?.invalidate()
            timer = nil
            state.expanded = false
            return
        }
        guard panel?.isVisible != true else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        place(on: nil)
        panel.appearance = HUDController.systemAppearance
        panel.orderFrontRegardless()
        track(fast: false)
    }

    func place(on screen: NSScreen?) {
        guard let panel, let screen = screen ?? HUDController.activeScreen() else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - canvas.width, y: visible.minY))
    }

    /// 10 times a second while closed (only to notice the pointer arriving), every frame while open.
    private func track(fast: Bool) {
        let interval = fast ? 1.0 / 60 : 0.1
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            onMainThread { self?.tick() }
        }
        timer.tolerance = fast ? 0 : 0.03
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y) // SwiftUI: top-left origin
        let open: Bool
        if let forced = state.forced {
            open = forced
        } else {
            let inside = hitRect.insetBy(dx: -6, dy: -6).contains(local)
            if inside { leftAt = nil } else if state.expanded, leftAt == nil { leftAt = Date() }
            // Stays open while you drag a line out of it, and for a moment after the pointer leaves.
            let dragging = state.expanded && NSEvent.pressedMouseButtons != 0
            let lingering = state.expanded && Date().timeIntervalSince(leftAt ?? .distantPast) < 0.35
            if state.pinned {
                if inside { state.pinnedEntered = true }
                if state.pinnedEntered ? !(inside || dragging || lingering) : Date() > state.pinnedUntil {
                    state.pinned = false
                    if AppSettings.shared.bagTab == .hidden {
                        refresh()
                        return
                    }
                }
            }
            open = state.pinned || inside || dragging || lingering
        }
        if panel.ignoresMouseEvents == open { panel.ignoresMouseEvents = !open }
        if state.expanded != open {
            state.expanded = open
            track(fast: open)
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
        let host = NSHostingView(rootView: BagView(bag: .shared, state: state, settings: .shared) { [weak self] rect in
            self?.hitRect = rect
        })
        host.frame = NSRect(origin: .zero, size: canvas)
        panel.contentView = host
        return panel
    }

    // MARK: Demo

    /// `--bag-demo <folder>`: the tab and the open list over black and white, captured to PNGs.
    /// Run with DRIFTFLOW_DATA_DIR set, so the demo's lines don't land in your real bag.
    func runDemo(to directory: URL) async {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let savedStyle = AppSettings.shared.bagTab
        let backdrop = NSWindow(contentRect: NSRect(x: visible.maxX - canvas.width - 20, y: visible.minY, width: canvas.width + 20, height: canvas.height),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.isReleasedWhenClosed = false
        for text in ["Also remind me to send the invoice to Daniel before Friday.",
                     "Can we move the Thursday call to ten? The studio is booked until nine thirty, so the crew can set up after that.",
                     "Hi Sarah, just following up on the shoot schedule for tomorrow."] {
            DictationBag.shared.add(text)
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
            for style in [BagTabStyle.faded, .visible] {
                AppSettings.shared.bagTab = style
                state.forced = false
                state.peeking = false
                try? await Task.sleep(for: .milliseconds(600))
                DictationController.capture(region, to: directory.appendingPathComponent("\(name)-tab-\(style.rawValue).png"))
            }
            state.forced = true
            try? await Task.sleep(for: .milliseconds(700))
            DictationController.capture(region, to: directory.appendingPathComponent("\(name)-open.png"))
            state.hovered = DictationBag.shared.items.dropFirst().first?.id
            try? await Task.sleep(for: .milliseconds(500))
            DictationController.capture(region, to: directory.appendingPathComponent("\(name)-hover.png"))
            state.hovered = nil
        }
        AppSettings.shared.bagTab = savedStyle
        NSApp.terminate(nil)
    }
}

// MARK: - Views

private struct BagHitRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        value = value == .zero ? next : (next == .zero ? value : value.union(next))
    }
}

private struct BagRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct BagView: View {
    @ObservedObject var bag: DictationBag
    @ObservedObject var state: BagPanelState
    @ObservedObject var settings: AppSettings
    let reportHitRect: (CGRect) -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            VStack(alignment: .trailing, spacing: 8) {
                if state.expanded, !bag.items.isEmpty {
                    list.transition(.move(edge: .bottom).combined(with: .opacity))
                }
                tab
            }
            .background(hitRect)
            .padding(.trailing, 14)
            .padding(.bottom, 12)
        }
        .coordinateSpace(name: "bag")
        .onPreferenceChange(BagHitRectKey.self) { reportHitRect($0) }
        .onPreferenceChange(BagRowFramesKey.self) { state.rowFrames = $0 }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.expanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: bag.items)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: state.hovered)
        .animation(.easeInOut(duration: 0.2), value: state.peeking)
    }

    private var faded: Bool { settings.bagTab == .faded && !state.expanded && !state.peeking }

    private var tab: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full.fill")
                .foregroundStyle(Brand.violet)
                .symbolEffect(.bounce, value: bag.addedCount)
            Text("\(bag.items.count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 13)
        .frame(height: 30)
        .modifier(Capsule().surface())
        .shadow(color: .black.opacity(faded ? 0 : 0.16), radius: 10, y: 4)
        .opacity(faded ? 0.4 : 1)
        .help("Your bag: dictations waiting to be pasted")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(bag.items) { item in
                        row(item, now: context.date)
                    }
                }
            }
            Text("Click to paste · drag into a text box")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 2)
        }
        .padding(8)
        .frame(width: 330)
        .modifier(RoundedRectangle(cornerRadius: 18, style: .continuous).surface())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private func row(_ item: BagItem, now: Date) -> some View {
        let hovered = state.hovered == item.id
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(hovered ? 6 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(DictationBag.age(of: item, now: now))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                bag.remove(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Remove from the bag")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Brand.violet.opacity(hovered ? 0.16 : 0))
        }
        // Click or drag anywhere on the line except ✕.
        .overlay(alignment: .leading) {
            BagDragSource(text: item.text,
                          onClick: { DictationController.shared.paste(fromBag: item) },
                          onDropped: { DictationBag.shared.remove(item.id) })
                .padding(.trailing, 28)
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: BagRowFramesKey.self, value: [item.id: proxy.frame(in: .named("bag"))])
        })
    }

    private var hitRect: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: BagHitRectKey.self, value: proxy.frame(in: .named("bag")))
        }
    }
}

/// Clicks paste the line; dragging it drops the text wherever you let go (a text box in any app).
/// In AppKit, because only a dragging source learns whether the drop was taken, and a line that
/// was dropped somewhere should leave the bag.
private struct BagDragSource: NSViewRepresentable {
    let text: String
    let onClick: () -> Void
    let onDropped: () -> Void

    func makeNSView(context: Context) -> BagDragView { BagDragView() }

    func updateNSView(_ view: BagDragView, context: Context) {
        view.text = text
        view.onClick = onClick
        view.onDropped = onDropped
    }
}

final class BagDragView: NSView, NSDraggingSource {
    var text = ""
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
        guard let downAt, !dragging else { return }
        let point = event.locationInWindow
        guard hypot(point.x - downAt.x, point.y - downAt.y) > 4 else { return }
        dragging = true
        let image = Self.dragImage(for: text)
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
