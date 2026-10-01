import AppKit
import SwiftUI

/// "Driftflow 0.2.16 is ready": what's new, Install Now or Later. Shown when an update has
/// downloaded, in front but without taking the keyboard focus from what you're typing.
@MainActor
final class UpdateWindow {
    static let shared = UpdateWindow()
    private(set) var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(version: String, notes: String) {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let view = UpdateView(version: version, current: current, notes: notes,
                              install: { [weak self] in self?.close(); Updater.shared.installNow() },
                              later: { [weak self] in self?.close() })
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.level = .floating // stays visible over the app you're in
            window.collectionBehavior = [.moveToActiveSpace]
            self.window = window
        }
        window?.contentViewController = NSHostingController(rootView: view)
        window?.center()
        // In front, but the app you're typing in keeps the keyboard.
        window?.orderFrontRegardless()
    }

    func close() { window?.orderOut(nil) }
}

private struct UpdateView: View {
    let version: String
    let current: String
    let notes: String
    let install: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Brand.appIcon(points: 56)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Driftflow \(version) is ready")
                        .font(.title3.weight(.semibold))
                    Text("You have \(current). Installing takes a few seconds: Driftflow closes and opens again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's new").font(.headline)
                    Text(notes)
                        .lineLimit(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            }
            Text("If you choose Later, it installs by itself when your Mac is idle or locked.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Later", action: later)
                    .keyboardShortcut(.cancelAction)
                Button("Install Now", action: install)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
