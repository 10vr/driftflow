import AppKit
import Combine
import os
import SwiftUI

struct DriftflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = DictationController.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        Settings {
            SettingsView(controller: controller, settings: settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dockObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist launches Driftflow as a menu bar app (no Dock flash for people who hide it);
        // the setting then adds the Dock icon and ⌘-Tab entry.
        Self.applyDockPresence(AppSettings.shared.showInDock)
        dockObserver = AppSettings.shared.$showInDock
            .dropFirst()
            .removeDuplicates()
            .sink { Self.applyDockPresence($0) }

        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { LoginItem.applyDefaultOnce() }
        if let index = CommandLine.arguments.firstIndex(of: "--scratch-test"), index + 2 < CommandLine.arguments.count,
           let pid = pid_t(CommandLine.arguments[index + 2]) {
            let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await Self.scratchTest(to: file, target: pid) }
        } else if let index = CommandLine.arguments.firstIndex(of: "--hud-demo"), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await DictationController.shared.runHUDDemo(to: directory) }
        } else if CommandLine.arguments.contains("--tap-test") {
            Task {
                await DictationController.shared.runTapTest()
                NSApp.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--demo") {
            Task { await DictationController.shared.runDemo() }
        } else if CommandLine.arguments.contains("--snapshot") {
            // Rendering only: no hot keys or microphone, so it can't interfere with the real app.
        } else {
            DictationController.shared.launch()
            StatusMenu.shared.install()
            _ = Updater.shared
        }
        if let index = CommandLine.arguments.firstIndex(of: "--mic-test"), index + 1 < CommandLine.arguments.count {
            Task { await Self.micTest(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            HUDSnapshot.render(to: directory)
            Task {
                await FilesWindow.shared.snapshotSettings(to: directory)
                await FilesWindow.shared.snapshot(to: directory)
                NSApp.terminate(nil) // a developer run: don't stay alive next to the real app
            }
        }
    }

    @MainActor
    static func applyDockPresence(_ show: Bool) {
        let front = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        // Changing the policy drops the app to the background; keep open windows in front.
        guard !front.isEmpty else { return }
        DispatchQueue.main.async {
            NSApp.activate()
            front.forEach { $0.makeKeyAndOrderFront(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationController.shared.restoreAudioOnQuit()
        TextInserter.shared.restoreNow() // give back your clipboard if a paste is still pending
        HistoryStore.shared.flush()
        FileTranscriber.shared.flush()
    }

    /// Clicking the Dock icon (or opening the app again) with no windows shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate()
            // Press the app menu's own "Settings…" item (the SwiftUI Settings scene has no public
            // opener outside a view).
            let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "," }
            if let item, let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }
        return true
    }

    /// Developer aid (`--scratch-test <file> <pid>`): types into the text field of the app `pid`
    /// (a throwaway test window, which must be in front) by paste and then keystrokes, sent to that
    /// process only,
    /// removes it as "scratch that" would, and checks that edited text is left alone. Stops at once
    /// if any other app comes to the front. Writes one PASS/FAIL line per case, then quits.
    @MainActor
    static func scratchTest(to file: URL, target pid: pid_t) async {
        var lines: [String] = []
        defer {
            try? lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        func targetInFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        guard Permissions.accessibilityGranted, targetInFront() else {
            lines.append("SKIP: needs Accessibility access and the test window in front")
            return
        }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            lines.append("SKIP: no focused text field in the test window")
            return
        }
        let field = focused as! AXUIElement
        func text() -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
            return value as? String ?? "<unreadable>"
        }
        func reset() {
            AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "Existing text." as CFString)
            var caret = CFRange(location: "Existing text.".utf16.count, length: 0)
            if let value = AXValueCreate(.cfRange, &caret) {
                AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value)
            }
        }
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            lines.append("\(ok ? "PASS" : "FAIL") \(name): \(detail)")
        }
        let inserter = TextInserter.shared
        // Keystrokes go to the test app's process only, never through the system to whichever
        // window has keyboard focus.
        inserter.testTargetPID = pid
        let typed = " Meet at five, café ☕️."
        for method in [InsertionMethod.paste, .type] {
            guard targetInFront() else { lines.append("ABORT: the test window lost focus"); return }
            reset()
            _ = inserter.insert(typed, method: method, restoreClipboard: true)
            let at = Date()
            try? await Task.sleep(for: .milliseconds(500))
            let afterInsert = text()
            guard targetInFront() else { lines.append("ABORT: the test window lost focus"); return }
            let removed = inserter.remove(typed, insertedAt: at)
            try? await Task.sleep(for: .milliseconds(400))
            check("\(method) insert", afterInsert == "Existing text." + typed, "\"\(afterInsert)\"")
            check("\(method) remove", removed && text() == "Existing text.", "removed=\(removed) now \"\(text())\"")

            // Edited after typing: must refuse and leave everything as it is.
            guard targetInFront() else { lines.append("ABORT: the test window lost focus"); return }
            reset()
            _ = inserter.insert(typed, method: method, restoreClipboard: true)
            let at2 = Date()
            try? await Task.sleep(for: .milliseconds(500))
            _ = inserter.insert("!", method: .type, restoreClipboard: true)
            try? await Task.sleep(for: .milliseconds(300))
            let edited = text()
            guard targetInFront() else { lines.append("ABORT: the test window lost focus"); return }
            let refused = !inserter.remove(typed, insertedAt: at2)
            try? await Task.sleep(for: .milliseconds(300))
            check("\(method) edited-refused", refused && text() == edited && edited.hasSuffix("!"), "refused=\(refused) now \"\(text())\"")
        }
    }

    /// Developer aid (`--mic-test <file>`): records 0.5 s from each microphone through the real
    /// capture path and writes what arrived. Audio is counted, never kept.
    @MainActor
    static func micTest(to file: URL) async {
        var lines: [String] = []
        for uid in [""] + AudioDevices.shared.inputs.map(\.uid) {
            let capture = AudioCapture()
            capture.preferredDeviceUIDs = [uid]
            let pipe = AudioPipe()
            let counter = OSAllocatedUnfairLock(initialState: (frames: 0, rate: 0.0, channels: 0))
            pipe.attach { buffer in
                counter.withLock { $0 = ($0.frames + Int(buffer.frameLength), buffer.format.sampleRate, Int(buffer.format.channelCount)) }
            }
            let name = uid.isEmpty ? "System default (\(AudioDevices.shared.defaultInputName))"
                : AudioDevices.shared.inputs.first { $0.uid == uid }?.name ?? uid
            do {
                try capture.beginRecording(into: pipe, includePreroll: false)
                try? await Task.sleep(for: .milliseconds(500))
                capture.endRecording()
                capture.cool()
                let result = counter.withLock { $0 }
                lines.append("\(name): \(result.frames) frames at \(Int(result.rate)) Hz, \(result.channels) ch")
            } catch {
                lines.append("\(name): failed: \(error.localizedDescription)")
            }
        }
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Finder's "Open With › Driftflow" and files dropped on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let id = FileTranscriber.shared.add(urls)
        FilesWindow.shared.show(select: id)
    }
}

