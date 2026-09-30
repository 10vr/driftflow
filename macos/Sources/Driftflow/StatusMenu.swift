import AppKit
import Combine

/// The menu bar icon and its menu, in AppKit so each command can show its shortcut on the right,
/// including keys a menu can't normally show, like Right ⌘. The menu is rebuilt each time it opens,
/// so it always reflects the current state.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()

    private var item: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private let controller = DictationController.shared
    private let settings = AppSettings.shared

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.item = item
        controller.$phase
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshIcon() } }
            .store(in: &cancellables)
        DictationStack.shared.$items.map(\.count).removeDuplicates().map { _ in () }
            .merge(with: settings.$stackMode.removeDuplicates().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.refreshIcon() } }
            .store(in: &cancellables)
    }

    /// In Stack Mode, how many dictations are stacked, next to the icon (a reminder the mode is on,
    /// even with the tab hidden).
    private func showStackCount() {
        guard let item, let button = item.button else { return }
        let count = settings.stackMode ? DictationStack.shared.items.count : 0
        item.length = count > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.attributedTitle = NSAttributedString(string: count > 0 ? "\(count)" : "", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        ])
    }

    /// The waveform, filled while listening, with a blue dot while an update waits to be installed.
    func refreshIcon() {
        defer { showStackCount() }
        let listening = controller.phase != .idle
        let symbol = NSImage(systemSymbolName: listening ? "waveform.circle.fill" : "waveform", accessibilityDescription: "Driftflow")
        guard Updater.shared.readyVersion != nil, !listening, let symbol else {
            symbol?.isTemplate = true
            item?.button?.image = symbol
            item?.button?.toolTip = nil
            return
        }
        // Drawn when shown, so the waveform takes the menu bar's own colour (light or dark).
        let size = NSSize(width: 18, height: 16)
        let badged = NSImage(size: size, flipped: false) { rect in
            let glyph = NSRect(x: 0, y: (rect.height - 14) / 2, width: 15, height: 14)
            let tinted = NSImage(size: glyph.size, flipped: false) { inner in
                symbol.draw(in: inner)
                NSColor.labelColor.set()
                inner.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: glyph)
            let dot = NSRect(x: rect.width - 7, y: rect.height - 7, width: 7, height: 7)
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        badged.isTemplate = false
        badged.accessibilityDescription = "Driftflow, update ready"
        item?.button?.image = badged
        item?.button?.toolTip = "Driftflow \(Updater.shared.readyVersion ?? "") is ready to install"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        build(menu)
        alignShortcuts(in: menu)
    }

    // MARK: Contents

    private func build(_ menu: NSMenu) {
        let history = HistoryStore.shared
        let hasDictations = history.entries.contains { $0.status == nil }
        let setupNeeded = !controller.accessibilityGranted || Permissions.microphone != .authorized

        if let version = Updater.shared.readyVersion {
            let update = command("Restart to Update to \(version)") { Updater.shared.installNow() }
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white, .systemBlue]))
            update.attributedTitle = NSAttributedString(string: update.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            menu.addItem(update)
            let note = NSMenuItem(title: "Installs by itself when your Mac is idle", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
        }

        // Only when something needs your attention; the shortcuts sit next to their commands.
        if let status = statusLine(setupNeeded: setupNeeded) {
            let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            menu.addItem(.separator())
        }

        menu.addItem(command(controller.phase == .idle ? "Start Dictation" : "Stop Dictation",
                             shortcut: settings.trigger.shortLabel, enabled: controller.phase != .finishing) { [controller] in
            controller.toggleFromMenu()
        })
        menu.addItem(command("Edit Selection by Voice", shortcut: settings.editShortcut?.display,
                             enabled: controller.phase == .idle && AIRewriter.shared.isAvailable) { [controller] in
            Task {
                try? await Task.sleep(for: .milliseconds(250)) // let the menu close first
                controller.editSelectionByVoice()
            }
        })
        menu.addItem(command("Paste Last Dictation", shortcut: settings.pasteLastShortcut?.display, enabled: hasDictations) { [controller] in
            controller.pasteLastDictation()
        })

        menu.addItem(.separator())
        let stackMode = command("Stack Mode") { [controller] in controller.toggleStackMode() }
        stackMode.state = settings.stackMode ? .on : .off
        menu.addItem(stackMode)
        // The stack itself is where you see and use what's in it (an empty one opens with your last dictations).
        menu.addItem(command("Open Stack", enabled: hasDictations || !DictationStack.shared.items.isEmpty || settings.stackMode) {
            StackPanel.shared.open()
        })
        menu.addItem(command("Saved Stacks…") { [controller] in controller.openSettings(.stacks) })

        menu.addItem(.separator())
        menu.addItem(command("Transcribe Audio Files…") { FilesWindow.shared.show() })
        menu.addItem(submenu("Recent", recentMenu(history: history, hasDictations: hasDictations)))

        menu.addItem(.separator())
        menu.addItem(submenu("Microphone", microphoneMenu()))
        menu.addItem(submenu("Style", styleMenu()))
        let sounds = command("Play Sounds") { [settings] in settings.playSounds.toggle() }
        sounds.state = settings.playSounds ? .on : .off
        menu.addItem(sounds)

        menu.addItem(.separator())
        if setupNeeded {
            menu.addItem(command("Finish Setup…") { [controller] in controller.showOnboarding() })
        }
        menu.addItem(command("Settings…", shortcut: "⌘,") { [controller] in controller.openSettings(.general) })
        menu.addItem(command("About Driftflow") { AboutPanel.show() })
        menu.addItem(command("Copy Log for Support") { AppLog.copyToClipboard() })
        let updates = command("Check for Updates…") { Updater.shared.checkForUpdates() }
        updates.isEnabled = Updater.shared.canCheck
        menu.addItem(updates)
        menu.addItem(command("Quit Driftflow", shortcut: "⌘Q") { NSApp.terminate(nil) })
    }

    private func statusLine(setupNeeded: Bool) -> String? {
        if setupNeeded { return "Setup needed" }
        if let progress = controller.downloadProgress ?? controller.accuracyProgress, progress < 1 {
            return "Downloading speech model… \(Int(progress * 100))%"
        }
        switch controller.phase {
        case .listening: return controller.editing ? "Listening for your edit…" : "Listening…"
        case .finishing: return "Transcribing…"
        case .idle: return controller.lastError
        }
    }

    private func recentMenu(history: HistoryStore, hasDictations: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if hasDictations {
            let header = NSMenuItem.sectionHeader(title: "Click to Copy")
            menu.addItem(header)
            for entry in history.entries.filter({ $0.status == nil }).prefix(10) {
                let text = entry.text
                menu.addItem(command(text.count > 48 ? String(text.prefix(47)) + "…" : text) { TextInserter.shared.copy(text) })
            }
        } else {
            let empty = NSMenuItem(title: "Nothing dictated yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(command("Show All History…") { [controller] in controller.openSettings(.history) })
        return menu
    }

    private func microphoneMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let devices = AudioDevices.shared
        let choices = [("", "System Default (\(devices.defaultInputName))")] + devices.inputs.map { ($0.uid, $0.name) }
        for (uid, name) in choices {
            let item = command(name) { [settings] in settings.inputDeviceUID = uid }
            item.state = settings.inputDeviceUID == uid ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(command("Microphone Priority…") { [controller] in controller.openSettings(.general) })
        return menu
    }

    private func styleMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let available = AIRewriter.shared.isAvailable
        for style in AIStyle.allCases {
            let item = command(style.label, enabled: style == .literal || available) { [settings] in settings.aiStyle = style }
            item.state = settings.aiStyle == style ? .on : .off
            menu.addItem(item)
        }
        if !available {
            let note = NSMenuItem(title: "Needs Apple Intelligence", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        menu.addItem(command("App and Website Rules…") { [controller] in controller.openSettings(.styles) })
        return menu
    }

    // MARK: Items

    private func command(_ title: String, shortcut: String? = nil, enabled: Bool = true,
                         action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target // the menu item doesn't retain its target
        item.isEnabled = enabled
        if let shortcut { shortcuts[ObjectIdentifier(item)] = shortcut }
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Shortcut text per item for the current build of the menu.
    private var shortcuts: [ObjectIdentifier: String] = [:]

    /// Puts each shortcut in one right-aligned column after the titles, in the lighter colour
    /// macOS uses for key equivalents. (A real key equivalent can't show "Right ⌘", and mixing the
    /// two would leave two columns that don't line up.)
    private func alignShortcuts(in menu: NSMenu) {
        defer { shortcuts.removeAll() }
        let font = NSFont.menuFont(ofSize: 0)
        let width = { (text: String) in (text as NSString).size(withAttributes: [.font: font]).width }
        let items = menu.items.filter { shortcuts[ObjectIdentifier($0)] != nil }
        guard !items.isEmpty else { return }
        let titleWidth = menu.items.map { width($0.title) }.max() ?? 0
        let shortcutWidth = items.compactMap { shortcuts[ObjectIdentifier($0)] }.map(width).max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: ceil(titleWidth + 32 + shortcutWidth))]
        for item in items {
            guard let shortcut = shortcuts[ObjectIdentifier(item)] else { continue }
            let title = NSMutableAttributedString(string: item.title + "\t", attributes: [
                .font: font, .paragraphStyle: paragraph,
                .foregroundColor: item.isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
            ])
            title.append(NSAttributedString(string: shortcut, attributes: [
                .font: font, .paragraphStyle: paragraph,
                .foregroundColor: item.isEnabled ? NSColor.secondaryLabelColor : NSColor.quaternaryLabelColor,
            ]))
            item.attributedTitle = title
        }
    }
}

/// Target for a menu item's closure.
final class MenuAction: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func run() {
        onMainThread { action() }
    }
}
