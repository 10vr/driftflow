import AppKit
import Carbon.HIToolbox

/// Watches the dictation trigger. Modifier-only triggers (Right ⌥, Right ⌘, Fn) use NSEvent
/// monitors, which need Accessibility access; key combos use a Carbon hot key, which doesn't.
@MainActor
final class HotKeyMonitor {
    /// Called with the key event's own time (seconds since boot, like `systemUptime`), so a tap is
    /// measured by when the key really moved, not by when the busy main thread got to the event.
    var onPress: (TimeInterval) -> Void = { _ in }
    var onRelease: (TimeInterval) -> Void = { _ in }
    /// Any other key pressed while Driftflow is running (used for Esc and chord detection).
    var onKeyDown: (UInt16) -> Void = { _ in }

    private(set) var trigger: TriggerKey = .rightOption
    private(set) var isDown = false
    private var monitors: [Any] = []
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Pseudo key code reported to `onKeyDown` for mouse clicks.
    static let mouseKeyCode: UInt16 = 0xFFFF

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) so left/right are distinguished.
    private static let rightOptionMask: UInt = 0x40
    private static let rightCommandMask: UInt = 0x10

    func install(_ trigger: TriggerKey) {
        uninstall()
        self.trigger = trigger

        addMonitor(for: .keyDown) { [weak self] event in self?.onKeyDown(event.keyCode) }
        // ⌘-click while holding a modifier trigger is a shortcut too; report it like a key. Only in
        // other apps: a click on the pill's own buttons (or the bag) is meant for Driftflow.
        addMonitor(for: [.leftMouseDown, .rightMouseDown], local: false) { [weak self] _ in self?.onKeyDown(Self.mouseKeyCode) }

        if trigger.isModifierOnly {
            addMonitor(for: .flagsChanged) { [weak self] event in self?.handleFlags(event) }
        } else {
            registerHotKey(trigger)
        }
    }

    func uninstall() {
        // Don't leave a hold-to-talk dictation stuck if we're reinstalled while the key is down.
        if isDown { onRelease(ProcessInfo.processInfo.systemUptime) }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        isDown = false
    }

    private func addMonitor(for mask: NSEvent.EventTypeMask, local: Bool = true, handler: @escaping (NSEvent) -> Void) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            onMainThread { handler(event) }
        }) {
            monitors.append(global)
        }
        if local, let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            onMainThread { handler(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.rawValue
        let down: Bool
        switch trigger {
        case .rightOption:
            guard event.keyCode == UInt16(kVK_RightOption) else { return }
            down = flags & Self.rightOptionMask != 0
        case .rightCommand:
            guard event.keyCode == UInt16(kVK_RightCommand) else { return }
            down = flags & Self.rightCommandMask != 0
        case .fn:
            guard event.keyCode == UInt16(kVK_Function) else { return }
            down = event.modifierFlags.contains(.function)
        default:
            return
        }
        setDown(down, at: event.timestamp)
    }

    private func setDown(_ down: Bool, at time: TimeInterval) {
        guard down != isDown else { return }
        isDown = down
        down ? onPress(time) : onRelease(time)
    }

    private func registerHotKey(_ trigger: TriggerKey) {
        let modifiers: Int = switch trigger {
        case .optionSpace: optionKey
        case .controlOptionSpace: optionKey | controlKey
        default: 0
        }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == OSType(0x4452_4654) else { return OSStatus(eventNotHandledErr) } // not ours
            let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let time = GetEventTime(event) // seconds since boot, as NSEvent.timestamp
            onMainThread { monitor.setDown(pressed, at: time) }
            return noErr
        }, eventTypes.count, &eventTypes, context, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4452_4654), id: 1) // "DRFT"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
