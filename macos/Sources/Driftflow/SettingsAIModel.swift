import AppKit
import SwiftUI

/// Settings › AI Model: which on-device language model runs AI Styles and editing by voice.
struct AIModelPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var models = TextModelManager.shared
    @State private var pendingDelete: TextModel?
    @State private var appleUsable = TextModel.appleModelUsable

    private var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: inUse == nil ? "exclamationmark.triangle" : "sparkles")
                        .foregroundStyle(inUse == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(Brand.gradient))
                    Text(statusLine).fixedSize(horizontal: false, vertical: true)
                }
                if !TextModel.hasComfortableMemory {
                    Label("This Mac has \(memoryGB) GB of memory. Qwen and Gemma use about 3 GB while they work, which can slow other apps down. Apple Intelligence needs no extra memory.",
                          systemImage: "memorychip")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(TextModel.allCases) { model in
                    TextModelRow(model: model,
                                 selected: settings.textModel == model,
                                 status: models.status(of: model),
                                 inUse: inUse == model,
                                 unavailable: model == .apple && !appleUsable ? AIRewriter.appleUnavailableReason : nil,
                                 select: { select(model) },
                                 download: { models.download(model) },
                                 cancel: { models.cancelDownload(model) },
                                 delete: { pendingDelete = model })
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Measured on an M5 MacBook with the same 45 test dictations (15 sentences in each of the 3 styles) and 16 voice edits for every model. A rewrite counts when it says what you dictated, tidied up; an edit when it does what you asked. Speed is the time from letting go of the key to the rewritten sentence; older Macs take longer (an M1 about twice as long). Qwen and Gemma run on this Mac's graphics chip and are loaded only while you use them, then freed after 5 idle minutes. They download once from Hugging Face; Driftline uses the same files, so they're never downloaded twice.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            models.refresh()
            appleUsable = TextModel.appleModelUsable
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appleUsable = TextModel.appleModelUsable // e.g. back from turning Apple Intelligence on
        }
        .confirmationDialog("Delete \(pendingDelete?.displayName ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let model = pendingDelete { models.delete(model) }
                pendingDelete = nil
            }
        } message: {
            Text("Frees \(pendingDelete?.downloadSize ?? "") of disk space. You can download it again any time. Driftline keeps its own copy, if it has one.")
        }
    }

    /// The model that runs right now (the chosen one, or Apple's while it downloads).
    private var inUse: TextModel? {
        _ = models.status // redraw when a download finishes
        return AIRewriter.shared.activeModel
    }

    private var statusLine: String {
        let chosen = settings.textModel
        switch inUse {
        case chosen?:
            return "AI Styles and editing by voice use \(chosen.displayName), on this Mac. Nothing you say leaves it."
        case .apple?:
            return "Apple Intelligence does the work until \(chosen.displayName) is downloaded."
        default:
            if chosen == .apple { return AIRewriter.appleUnavailableReason + " Download Qwen 3.5 4B below to use AI Styles and editing by voice." }
            return "Download \(chosen.displayName) to use AI Styles and editing by voice."
        }
    }

    private func select(_ model: TextModel) {
        if model.needsDownload, !models.isDownloaded(model) { models.download(model) }
        withAnimation(.snappy) { settings.textModel = model }
    }
}

private struct TextModelRow: View {
    let model: TextModel
    let selected: Bool
    let status: ModelManager.Status
    let inUse: Bool
    /// Why Apple's model can't run here.
    let unavailable: String?
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.displayName).font(.headline)
                    Text(model.badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.18), in: .capsule)
                        .foregroundStyle(badgeColor)
                }
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Stat(icon: "target", text: "\(model.rewritesKept) of \(TextModel.rewriteTests) rewrites right")
                    Stat(icon: "pencil", text: "\(model.editsRight) of \(TextModel.editTests) edits right")
                    Stat(icon: "bolt.fill", text: String(format: "%.2g s a sentence", model.typicalSeconds))
                }
                HStack(spacing: 12) {
                    Stat(icon: "internaldrive", text: model.downloadSize)
                    Stat(icon: "memorychip", text: model.memory)
                }
                if let unavailable, !unavailable.isEmpty {
                    Label(unavailable, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)
            trailing
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { if !selected { select() } }
        .animation(.snappy, value: status)
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(progress >= 1 ? "Checking…" : "\(Int(progress * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel download")
            }
        case .notDownloaded, .failed:
            VStack(alignment: .trailing, spacing: 2) {
                Button("Download", action: download)
                    .glassButtonStyle()
                if case .failed(let message) = status {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
        case .downloaded:
            if selected {
                Label(inUse ? "In use" : "Not available", systemImage: inUse ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(inUse ? Color.green : Color.secondary)
            } else {
                HStack(spacing: 6) {
                    Button("Use", action: select)
                        .glassButtonStyle()
                    if model.needsDownload {
                        Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Delete from disk")
                    }
                }
            }
        }
    }

    private var badgeColor: Color {
        switch model {
        case .qwen: .green
        case .gemma: .orange
        case .apple: .gray
        }
    }
}

extension AIModelPane {
    /// The model rows outside a Form, for `--snapshot` (Forms can't be captured off screen).
    static func snapshotWindow() -> NSWindow {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(TextModel.allCases) { model in
                TextModelRow(model: model, selected: model == .qwen, status: TextModelManager.shared.status(of: model),
                             inUse: model == .qwen, unavailable: nil, select: {}, download: {}, cancel: {}, delete: {})
                    .padding(.horizontal, 16)
                Divider()
            }
        }
        .frame(width: 620)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: rows)
        window.setContentSize(window.contentView!.fittingSize)
        return window
    }
}
