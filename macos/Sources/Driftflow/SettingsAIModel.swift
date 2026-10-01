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
                Text("It tidies what you dictate into a style (Settings › Styles), and changes selected text when you press \(settings.editShortcut?.display ?? "the edit shortcut") and say how. Try it below.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                                 elsewhere: models.downloadingElsewhere.contains(model),
                                 keptForOtherApp: model.needsDownload && models.isDownloaded(model) && !models.usedHere(model)
                                     && settings.textModel != model && models.usedByOtherApp(model),
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
                Text("Measured on an M5 MacBook with the same 45 test dictations (15 sentences in each of the 3 styles) and 16 voice edits for every model. A rewrite counts when it says what you dictated, tidied up; an edit when it does what you asked. Speed is the time from letting go of the key to the rewritten sentence; older Macs take longer (an M1 about twice as long). Qwen and Gemma run on this Mac's graphics chip and are loaded only while you use them, then freed after 5 idle minutes. They download once from Hugging Face into a folder Driftline shares: a model is downloaded once for both apps, and when both use it at the same time it's in memory once.")
                    .foregroundStyle(.secondary)
            }

            AITrySection(models: models, chosen: settings.textModel)
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
            if let model = pendingDelete, models.usedByOtherApp(model) {
                Text("\(TextModelManager.otherApp ?? "Driftline") uses this model too, so it stays on your Mac (\(model.downloadSize)) until you delete it there as well. Driftflow stops using it.")
            } else {
                Text("Frees \(pendingDelete?.downloadSize ?? "") of disk space. You can download it again any time.")
            }
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
    /// Driftline is downloading it (this app waits instead of downloading it again).
    var elsewhere = false
    /// Deleted here, but on disk because Driftline uses it.
    var keptForOtherApp = false
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
                Group {
                    if elsewhere { ProgressView() } else { ProgressView(value: progress) }
                }
                .progressViewStyle(.circular)
                .controlSize(.small)
                .help(elsewhere ? "\(TextModelManager.otherApp ?? "The other app") is downloading this model; Driftflow will use the same file." : "")
                Text(elsewhere ? "In \(TextModelManager.otherApp ?? "the other app")…" : progress >= 1 ? "Checking…" : "\(Int(progress * 100))%")
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
                    if keptForOtherApp {
                        Text("Kept for \(TextModelManager.otherApp ?? "Driftline")").font(.caption).foregroundStyle(.secondary)
                    } else if model.needsDownload {
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

/// Settings › AI Model › Try it: a sentence through any ready model, in a style or with a spoken-style
/// edit instruction, so you can compare the models on your own words. Nothing is saved.
private struct AITrySection: View {
    @ObservedObject var models: TextModelManager
    let chosen: TextModel

    enum Mode: String, CaseIterable, Identifiable {
        case clean, professional, casual, edit
        var id: String { rawValue }
        var label: String { self == .edit ? "Edit" : AIStyle(rawValue: rawValue)?.label ?? rawValue }
    }

    static let sampleDictation = "yeah that's gonna be kinda tricky cause the client wants like everything done by friday"
    static let sampleSelection = "hey, can u send me the report asap? need it for the meeting tmrw. thx"

    @State private var model: TextModel?
    @State private var mode: Mode = .professional
    @State private var input = sampleDictation
    @State private var instruction = "make it more formal"
    @State private var result: String?
    @State private var note: String?
    @State private var seconds: Double?
    @State private var running = false

    /// Models that can run now: downloaded ones, and Apple's when it's on.
    private var ready: [TextModel] {
        TextModel.allCases.filter { $0 == .apple ? TextModel.appleModelUsable : models.isDownloaded($0) }
    }

    var body: some View {
        Section {
            if ready.isEmpty {
                Text("Download a model above to try it.").foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: Binding(get: { model ?? (ready.contains(chosen) ? chosen : ready[0]) }, set: { model = $0 })) {
                    ForEach(ready) { Text($0.displayName).tag($0) }
                }
                Picker("Try", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { old, new in
                    // Swap in the matching sample if the box still holds the other one.
                    if new == .edit, input == Self.sampleDictation { input = Self.sampleSelection }
                    if old == .edit, new != .edit, input == Self.sampleSelection { input = Self.sampleDictation }
                    result = nil; note = nil; seconds = nil
                }
                if mode == .edit {
                    TextField("Say", text: $instruction, prompt: Text("make it shorter"))
                }
                TextField(mode == .edit ? "Selected text" : "You said", text: $input, axis: .vertical)
                    .lineLimit(2...6)
                HStack {
                    Button(mode == .edit ? "Edit" : "Rewrite") { run() }
                        .glassButtonStyle()
                        .disabled(running || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (mode == .edit && instruction.trimmingCharacters(in: .whitespaces).isEmpty))
                    if running { ProgressView().controlSize(.small) }
                    Spacer()
                    if let seconds {
                        Text(String(format: "%.1f s", seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let result {
                    Text(result)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 8))
                }
                if let note {
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Try it")
        } footer: {
            Text("Type, or dictate into the box. Styles get the same clean-up as a dictation first (filler words, your replacements). The first try loads the model, which takes a second or two. Nothing is saved.")
                .foregroundStyle(.secondary)
        }
    }

    private func run() {
        let model = model ?? (ready.contains(chosen) ? chosen : ready.first)
        guard let model else { return }
        running = true
        result = nil; note = nil; seconds = nil
        let text = input, instruction = instruction, mode = mode
        let started = Date()
        Task { @MainActor in
            defer {
                running = false
                seconds = Date().timeIntervalSince(started)
            }
            if mode == .edit {
                do { result = try await AIRewriter.shared.edit(text, instruction: instruction, using: model) }
                catch { note = error.localizedDescription }
                return
            }
            guard let style = AIStyle(rawValue: mode.rawValue) else { return }
            let said = AppSettings.shared.textProcessor.process(text, english: true)
            if let rewritten = await AIRewriter.shared.rewrite(said, style: style, using: model) {
                result = rewritten
            } else {
                result = said
                let wrote = AIRewriter.shared.lastOutput.map { AIRewriter.tidy($0) } ?? ""
                note = wrote.isEmpty
                    ? "\(model.displayName) didn't answer in time, so your words would be typed as said."
                    : "The rewrite didn't pass the safety check, so your words would be typed as said. It wrote: “\(wrote.prefix(200))”"
            }
        }
    }
}
