import AppKit
import os
import SwiftUI

/// Audio levels written from the audio thread and read by the waveform at display refresh rate.
/// Bypasses SwiftUI state entirely, so the meter never causes view invalidations.
final class LevelStore: @unchecked Sendable {
    static let shared = LevelStore()
    private let lock = OSAllocatedUnfairLock(initialState: Float(0))

    /// Fast attack, slow release: the meter jumps with syllables and settles smoothly.
    func push(_ level: Float) {
        lock.withLock { current in
            current = level > current ? current + (level - current) * 0.7 : current * 0.8 + level * 0.2
        }
    }
    func reset() { lock.withLock { $0 = 0 } }
    func set(_ level: Float) { lock.withLock { $0 = level } }
    var current: Float { lock.withLock { $0 } }
}

enum HUDPosition: String, CaseIterable, Identifiable {
    case bottom
    case top

    var id: String { rawValue }
    var label: String { self == .bottom ? "Bottom of screen" : "Top, under the menu bar" }
}

/// A transparent, non-activating panel that sits over every app. SwiftUI animates the pill inside
/// it, so the window itself never resizes (window resizes make other overlays stutter). Clicks pass
/// through everywhere except the pill itself, which is clickable in hands-free mode, on toasts and
/// in its idle state.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private let canvas = NSSize(width: 720, height: 200)
    /// The pill's (and toast's) frame in panel coordinates, reported by SwiftUI.
    var hitRect: CGRect = .zero
    private var mouseTimer: Timer?
    /// When the pointer left the pill (for the hover grace period).
    private var leftAt: Date?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ controller: DictationController, position: HUDPosition) {
        let panel = panel ?? makePanel(controller)
        self.panel = panel
        if let screen = Self.activeScreen() {
            let visible = screen.visibleFrame
            let y = position == .bottom ? visible.minY + 12 : visible.maxY - canvas.height - 2
            panel.setFrameOrigin(NSPoint(x: visible.midX - canvas.width / 2, y: y))
        }
        panel.appearance = Self.systemAppearance
        panel.orderFrontRegardless()
        startTrackingMouse()
    }

    /// The system's light/dark setting (not the app's, which a window may override).
    static var systemAppearance: NSAppearance? {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// Follows light/dark changes made in System Settings while the panel exists.
    private func observeAppearance() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            onMainThread { self?.panel?.appearance = Self.systemAppearance }
        }
    }

    func hide() {
        // The SwiftUI content animates itself out; the empty panel is then removed.
        panel?.orderOut(nil)
        mouseTimer?.invalidate()
        mouseTimer = nil
    }

    /// The screen with the focused window of the app you're working in (falls back to the pointer's).
    static func activeScreen() -> NSScreen? {
        if let app = NSWorkspace.shared.frontmostApplication, Permissions.accessibilityGranted {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // A hung app must not freeze the pill (the default timeout is about 6 s).
            AXUIElementSetMessagingTimeout(element, 0.1)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
                var origin = CGPoint.zero, size = CGSize.zero
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
                   AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
                   let positionValue, let sizeValue {
                    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                    // AX uses top-left origin on the primary display; AppKit uses bottom-left.
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                    let center = CGPoint(x: origin.x + size.width / 2, y: primaryHeight - (origin.y + size.height / 2))
                    if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
                }
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Lets clicks through except over the pill: a transparent panel would otherwise swallow them.
    private func startTrackingMouse() {
        guard mouseTimer == nil else { return }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            onMainThread {
                guard let self, let panel = self.panel, HUDHover.shared.forced == nil else { return }
                let mouse = NSEvent.mouseLocation
                let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y) // SwiftUI: top-left origin
                // Hysteresis: easy to enter, a wider margin to leave, and a short grace period before
                // hiding, so the edge of the pill never flickers between hovered and not.
                let hovering = HUDHover.shared.isOver
                let inside = self.hitRect.insetBy(dx: hovering ? -14 : -4, dy: hovering ? -14 : -4).contains(local)
                if inside { self.leftAt = nil } else if hovering, self.leftAt == nil { self.leftAt = Date() }
                let over = inside || (hovering && Date().timeIntervalSince(self.leftAt ?? .distantPast) < 0.25)
                if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
                if hovering != over { HUDHover.shared.isOver = over }
            }
        }
    }

    private func makePanel(_ controller: DictationController) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: HUDView(controller: controller, settings: .shared, hover: .shared) { [weak self] rect in
            self?.hitRect = rect
        })
        host.frame = NSRect(origin: .zero, size: canvas)
        panel.contentView = host
        panel.appearance = Self.systemAppearance
        observeAppearance()
        return panel
    }
}

/// Whether the pointer is over the pill (drives the idle pill's hover expansion).
@MainActor
final class HUDHover: ObservableObject {
    static let shared = HUDHover()
    @Published var isOver = false
    /// Set by `--hud-demo` to show or hide the buttons regardless of the pointer.
    var forced: Bool? { didSet { if let forced { isOver = forced } } }
}

/// A short message under the pill, optionally with a button that fixes the problem.
struct HUDToast: Equatable {
    enum Action: Equatable {
        case chooseMicrophone
        case openHistory
        case addToVocabulary(String)
        case installUpdate
    }

    var id = UUID()
    var icon: String
    var text: String
    var action: Action?

    var actionTitle: String? {
        switch action {
        case .chooseMicrophone: "Change Microphone"
        case .openHistory: "View History"
        case .addToVocabulary: "Add"
        case .installUpdate: "Restart Now"
        case nil: nil
        }
    }
}

/// The pill's surface: real Liquid Glass (refraction and specular edge), in its *clear* variant.
/// Regular glass adapts to what's behind it and can flip between light and dark as it appears;
/// clear glass has no adaptive behaviour, so we add the dimming layer Apple prescribes for it,
/// chosen from the system appearance (pinned on the panel). The pill never changes mid-dictation.
struct PillSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    @Environment(\.colorScheme) private var scheme
    /// `DRIFTFLOW_GLASS=regular` (with `--hud-demo`) shows the old adaptive glass for comparison.
    private static var comparison: Bool { ProcessInfo.processInfo.environment["DRIFTFLOW_GLASS"] == "regular" }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    if !Self.comparison { shape.fill(scheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.66)) }
                    if let tint { shape.fill(tint) }
                }
                .glassEffect(Self.comparison ? .regular : .clear, in: shape)
        } else {
            // macOS 15: no Liquid Glass; a frosted material with a hairline edge, equally steady.
            content
                .background {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint) }
                    shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 1)
                }
                .clipShape(shape)
        }
    }
}

extension Shape where Self: InsettableShape {
    func surface(tint: Color? = nil) -> PillSurface<Self> { PillSurface(shape: self, tint: tint) }
}

private struct TextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ShownWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct HitRectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        value = value == .zero ? next : (next == .zero ? value : value.union(next))
    }
}

struct HUDView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var hover: HUDHover
    let reportHitRect: (CGRect) -> Void

    private var alignment: Alignment { settings.hudPosition == .bottom ? .bottom : .top }
    private var idle: Bool { controller.phase == .idle && !controller.hudVisible }
    /// ✕, bag and ✓ show on hover (while holding the key too); briefly on their own when hands-free
    /// starts, so you know they're there.
    @State private var revealButtons = false
    private var handsFreeListening: Bool { controller.handsFree && controller.phase == .listening }
    private var showButtons: Bool { controller.phase == .listening && (hover.isOver || (handsFreeListening && revealButtons)) }

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            VStack(spacing: 8) {
                if settings.hudPosition == .bottom { toast }
                if controller.hudVisible {
                    pill
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.6, anchor: settings.hudPosition == .bottom ? .bottom : .top)
                                    .combined(with: .opacity),
                                removal: .scale(scale: 0.85).combined(with: .opacity)
                            )
                        )
                } else if settings.showIdlePill {
                    idlePill.transition(.opacity)
                }
                if settings.hudPosition == .top { toast }
            }
        }
        .padding(12)
        // Measured in the panel's own coordinates (outside the padding), matching the hit test.
        .coordinateSpace(name: "hud")
        .onPreferenceChange(HitRectKey.self) { reportHitRect($0) }
        // Size animations live here, above the pill, so its centring moves on the same curve as its
        // width (animating only inside the pill made one edge snap while the other slid).
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: hasText)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: controller.phase)
        .animation(.easeOut(duration: 0.18), value: controller.finalizedText + controller.volatileText)
        // One critically damped spring for the button reveal (width, padding and icons together).
        .animation(.spring(response: 0.3, dampingFraction: 1), value: showButtons)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: controller.hudVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: controller.toast)
    }

    // MARK: Idle

    /// A thin sliver that grows into a hint on hover; clicking it starts hands-free dictation.
    private var idlePill: some View {
        Button { controller.toggleFromMenu() } label: {
            ZStack {
                if hover.isOver {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(Brand.violet)
                        Text("Click or hold \(settings.trigger.label)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: hover.isOver ? 220 : 48, height: hover.isOver ? 30 : 8)
            .modifier(Capsule().surface())
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(hitRect)
        .animation(.easeInOut(duration: 0.2), value: hover.isOver)
    }

    // MARK: Active

    private var pill: some View {
        HStack(spacing: 0) {
            pillButton("xmark", help: "Discard (Esc)", edge: .trailing) { controller.cancelFromHUD() }
            indicator
                .frame(width: 34, height: 26)
            if hasText || controller.statusMessage != nil || controller.editing {
                transcript
                    .padding(.leading, 12)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            if !controller.editing {
                pillButton("tray.and.arrow.down", help: "Put in the bag, to paste later", edge: .leading, tint: Brand.violet) { controller.finishIntoBag() }
            }
            pillButton("checkmark", help: "Finish and insert", edge: .leading, gap: controller.editing ? 12 : 6) { controller.toggleFromMenu() }
        }
        .padding(.leading, showButtons ? 8 : 16)
        .padding(.trailing, showButtons ? 8 : (hasText ? 20 : 16))
        .frame(height: 46)
        // No overall width cap: the transcript has its own, so the buttons never squeeze it and
        // the text never re-truncates while the pill grows.
        .fixedSize(horizontal: true, vertical: false)
        .modifier(Capsule().surface(tint: tint))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .background(hitRect)
        .onChange(of: controller.handsFree) { _, handsFree in
            guard handsFree else { revealButtons = false; return }
            revealButtons = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                revealButtons = false
            }
        }
    }

    /// Always in the layout, so showing it is a pure size animation: its slot opens from zero width
    /// while the icon scales up inside it, and the pill, text and icons all move on the same spring.
    /// (Inserting the button instead places it at its final spot at once, outside the growing pill.)
    private func pillButton(_ symbol: String, help: String, edge: Edge.Set, gap: CGFloat = 12, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.primary.opacity(0.08)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .scaleEffect(showButtons ? 1 : 0.3)
        .opacity(showButtons ? 1 : 0)
        .frame(width: showButtons ? 30 : 0)
        .padding(edge, showButtons ? gap : 0)
        .allowsHitTesting(showButtons)
        .help(help)
    }

    private var hasText: Bool { !controller.finalizedText.isEmpty || !controller.volatileText.isEmpty }

    private var tint: Color? {
        if controller.lastError != nil, controller.phase == .idle { return .red.opacity(0.25) }
        return nil
    }

    @ViewBuilder
    private var indicator: some View {
        switch controller.phase {
        case .listening:
            RippleWaveform()
                .transition(.scale.combined(with: .opacity))
        case .finishing:
            BouncingDots()
                .transition(.scale.combined(with: .opacity))
        case .idle:
            Image(systemName: controller.lastError != nil ? "exclamationmark" : controller.cancelled ? "xmark"
                  : controller.lastWentToBag ? "tray.full.fill" : "checkmark")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(controller.lastError != nil ? AnyShapeStyle(Color.red)
                                 : controller.cancelled ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Brand.gradient))
                .shadow(color: controller.lastError == nil && !controller.cancelled ? Brand.glow.opacity(0.45) : .clear, radius: 4)
                .symbolEffect(.bounce, value: controller.completedCount)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var transcript: some View {
        transcriptText
            .frame(maxWidth: 480, alignment: .trailing)
            .mask {
                // Soft fade on the left edge, only when the start of the sentence is cut off.
                if transcriptOverflows {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06)],
                                   startPoint: .leading, endPoint: .trailing)
                } else {
                    Color.black
                }
            }
            .background {
                // The sentence's full width, to know whether it fits.
                transcriptText.fixedSize().hidden()
                    .background(GeometryReader { Color.clear.preference(key: TextWidthKey.self, value: $0.size.width) })
            }
            .background(GeometryReader { Color.clear.preference(key: ShownWidthKey.self, value: $0.size.width) })
            .onPreferenceChange(TextWidthKey.self) { fullTextWidth = $0 }
            .onPreferenceChange(ShownWidthKey.self) { shownTextWidth = $0 }
    }

    @State private var fullTextWidth: CGFloat = 0
    @State private var shownTextWidth: CGFloat = 0
    private var transcriptOverflows: Bool { fullTextWidth > shownTextWidth + 1 }

    private var transcriptText: some View {
        Group {
            if let status = controller.statusMessage {
                Text(status).foregroundStyle(.secondary)
            } else if controller.editing, !hasText {
                Text("\(Image(systemName: "wand.and.sparkles")) Say how to change the selection").foregroundStyle(.secondary)
            } else {
                Text("\(controller.finalizedText)\(Text(controller.volatileText).foregroundStyle(.secondary))")
            }
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .lineLimit(1)
        .truncationMode(.head)
    }

    // MARK: Toast

    @ViewBuilder
    private var toast: some View {
        if let toast = controller.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.icon).foregroundStyle(Brand.violet)
                Text(toast.text)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .lineLimit(2)
                if let title = toast.actionTitle {
                    // Not a glass button: regular glass adapts to the backdrop and could flip light/dark.
                    Button { controller.performToastAction() } label: {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.primary.opacity(0.1)))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
                Button { controller.dismissToast() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .fixedSize()
            .modifier(Capsule().surface())
            .background(hitRect)
            .transition(.move(edge: settings.hudPosition == .bottom ? .bottom : .top).combined(with: .opacity))
            .id(toast.id)
        }
    }

    private var hitRect: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: HitRectKey.self, value: proxy.frame(in: .named("hud")))
        }
    }
}

/// The app icon's neon palette (Display P3), so the live meter matches the logo.
enum Brand {
    static let pink = Color(.displayP3, red: 1.0, green: 0x5D / 255, blue: 0xB1 / 255)
    static let violet = Color(.displayP3, red: 0x9B / 255, green: 0x5C / 255, blue: 1.0)
    static let cyan = Color(.displayP3, red: 0x4F / 255, green: 0xE7 / 255, blue: 1.0)
    static let glow = Color(.displayP3, red: 0x8A / 255, green: 0x5C / 255, blue: 1.0)
    /// The logo's gradient for small marks (the finished-dictation check), running diagonally.
    static let gradient = LinearGradient(colors: [pink, violet, cyan], startPoint: .bottomLeading, endPoint: .topTrailing)
}

/// Seven bars that rest as dots. Loudness drives the centre bar and ripples outward, each ring
/// 50 ms later and a little smaller; every bar moves on a spring, and a quiet room "breathes".
/// Filled with the logo gradient across the meter's height, so louder speech reaches into the
/// pink and cyan ends. Reads the level straight from `LevelStore`, never through SwiftUI state.
struct RippleWaveform: View {
    @State private var model = RippleModel()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let heights = model.step(time: timeline.date.timeIntervalSinceReferenceDate, level: Double(LevelStore.shared.current))
                let bars = heights.count
                let spacing: CGFloat = 3
                let width = (size.width - spacing * CGFloat(bars - 1)) / CGFloat(bars)
                let fill = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Brand.pink, Brand.violet, Brand.cyan]),
                    startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: 0))
                let level = min(Double(LevelStore.shared.current), 1)
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: Brand.glow.opacity(0.25 + 0.5 * level), radius: 2 + 4 * level))
                    for (i, value) in heights.enumerated() {
                        let height = width + CGFloat(value) * (size.height - width)
                        let rect = CGRect(x: CGFloat(i) * (width + spacing), y: (size.height - height) / 2, width: width, height: height)
                        layer.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: fill)
                    }
                }
            }
        }
    }
}

/// Spring physics for `RippleWaveform` (a reference type so each frame can advance it in place).
final class RippleModel {
    private static let gains = [1.0, 0.84, 0.64, 0.44] // by distance from the centre
    private static let stiffness = 420.0
    private static let damping = 2 * 0.58 * 420.0.squareRoot()
    private var history: [(time: Double, level: Double)] = []
    private var position = [Double](repeating: 0, count: 7)
    private var velocity = [Double](repeating: 0, count: 7)
    private var lastTime: Double?

    /// Bar heights in 0...1.08 for this frame.
    func step(time: Double, level: Double) -> [Double] {
        history.append((time, level))
        if history.count > 90 { history.removeFirst(history.count - 90) }
        let dt = min(max(time - (lastTime ?? time), 0), 1.0 / 30)
        lastTime = time
        for i in 0..<7 {
            let ring = abs(i - 3)
            let delayed = self.level(at: time - 0.05 * Double(ring))
            var target = Self.gains[ring] * delayed
            if delayed < 0.05 { // quiet: breathe gently
                target = max(target, 0.07 * (0.5 + 0.5 * sin(2 * .pi * 0.55 * time + Double(ring) * 0.6)))
            }
            let force = Self.stiffness * (target - position[i]) - Self.damping * velocity[i]
            velocity[i] += force * dt
            position[i] = min(max(position[i] + velocity[i] * dt, 0), 1.08)
        }
        return position
    }

    private func level(at time: Double) -> Double {
        history.last(where: { $0.time <= time })?.level ?? history.first?.level ?? 0
    }
}

/// Three dots bouncing in the logo's colors while the final text is being written.
struct BouncingDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill([Brand.pink, Brand.violet, Brand.cyan][i])
                        .frame(width: 5, height: 5)
                        .offset(y: -3.5 * max(0, sin(t * 8 - Double(i) * 0.9)))
                }
            }
        }
    }
}

/// Developer aid for `--snapshot`: the meter at a few loudness levels, on light and dark.
@MainActor
enum HUDSnapshot {
    static func render(to directory: URL) {
        for scheme in [ColorScheme.light, .dark] {
            for level in [0.05, 0.35, 0.9] {
                LevelStore.shared.set(Float(level))
                let view = RippleWaveform()
                    .frame(width: 34, height: 26)
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96), in: .capsule)
                    .padding(10)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 4
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("meter-\(scheme == .dark ? "dark" : "light")-\(Int(level * 100)).png"))
                }
            }
        }
        LevelStore.shared.reset()
        // The finished-dictation check, as the pill shows it.
        for scheme in [ColorScheme.light, .dark] {
            let view = HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Brand.gradient)
                    .shadow(color: Brand.glow.opacity(0.45), radius: 4)
                    .frame(width: 34, height: 26)
                Text("Hi team, quick update on the campaign.").font(.system(size: 14, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96), in: .capsule)
            .padding(10)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("check-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
