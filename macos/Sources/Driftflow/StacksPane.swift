import AppKit
import SwiftUI

/// A stack put aside for later ("Message to Ali"), while a new one fills up.
struct SavedStack: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    let saved: Date
    var items: [StackItem]

    var joined: String { items.map(\.text).joined(separator: " ") }
}

/// Saved stacks, newest first, kept on this Mac (you saved them on purpose, so they're kept even
/// with History off).
@MainActor
final class StackLibrary: ObservableObject {
    static let shared = StackLibrary()

    @Published private(set) var stacks: [SavedStack] = [] { didSet { save() } }
    private let fileURL = AppData.directory.appendingPathComponent("saved-stacks.json")

    private init() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        stacks = (try? JSONDecoder().decode([SavedStack].self, from: data)) ?? []
    }

    /// Save Stack: the current stack (pinned lines stay put) is set aside and a new one starts.
    @discardableResult
    func saveCurrent() -> SavedStack? {
        let lines = DictationStack.shared.takeQueue()
        guard !lines.isEmpty else { return nil }
        let saved = SavedStack(name: Self.name(for: lines), saved: Date(), items: lines)
        stacks.insert(saved, at: 0)
        return saved
    }

    /// Use Again: this one becomes the current stack. What was there is saved first, so switching
    /// between stacks never loses anything.
    func useAgain(_ id: UUID) {
        guard let index = stacks.firstIndex(where: { $0.id == id }) else { return }
        let chosen = stacks.remove(at: index)
        saveCurrent()
        DictationStack.shared.load(chosen.items)
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = stacks.firstIndex(where: { $0.id == id }) else { return }
        stacks[index].name = name
    }

    func delete(_ id: UUID) {
        stacks.removeAll { $0.id == id }
    }

    func moveLines(in id: UUID, from source: IndexSet, to destination: Int) {
        guard let index = stacks.firstIndex(where: { $0.id == id }) else { return }
        stacks[index].items.move(fromOffsets: source, toOffset: destination)
    }

    func removeLine(_ lineID: UUID, from id: UUID) {
        guard let index = stacks.firstIndex(where: { $0.id == id }) else { return }
        stacks[index].items.removeAll { $0.id == lineID }
        if stacks[index].items.isEmpty { stacks.remove(at: index) }
    }

    /// The start of the first line, until you rename it.
    private static func name(for lines: [StackItem]) -> String {
        let words = lines[0].text.split(separator: " ")
        return words.prefix(5).joined(separator: " ") + (words.count > 5 ? "…" : "")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AppData.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(stacks).write(to: fileURL, options: [.atomic])
    }
}

extension StackPanel {
    /// Save Stack (the floating stack's header or its tab's menu): set aside, with a way to find it.
    func saveCurrentStack() {
        guard let saved = StackLibrary.shared.saveCurrent() else { return }
        DictationController.shared.showToast(HUDToast(icon: "square.and.arrow.down",
                                                      text: "Saved as “\(saved.name)”. A new stack has started.",
                                                      action: .openStacks), for: 5)
    }
}

// MARK: - The Stacks page

/// Stacks in the main window: the one you're adding to now, and the ones you saved, each with its
/// lines in full, to reorder, rename, copy or bring back.
struct StacksPane: View {
    enum Selection: Hashable {
        case current
        case saved(UUID)
    }

    @ObservedObject private var library = StackLibrary.shared
    @ObservedObject private var stack = DictationStack.shared
    @State private var selection: Selection? = .current

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Now") {
                    StackListRow(name: "Current Stack", detail: stack.items.isEmpty ? "Empty" : lines(stack.items.count),
                                 icon: "rectangle.stack")
                        .tag(Selection.current)
                }
                Section("Saved") {
                    if library.stacks.isEmpty {
                        Text("Stacks you save appear here")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.stacks) { saved in
                        StackListRow(name: saved.name,
                                     detail: "\(lines(saved.items.count)) · \(saved.saved.formatted(.relative(presentation: .named)))",
                                     icon: "tray.full")
                            .tag(Selection.saved(saved.id))
                            .contextMenu {
                                Button("Use Again") { useAgain(saved.id) }
                                Button("Copy All") { TextInserter.shared.copy(saved.joined) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(saved.id) }
                            }
                    }
                }
            }
            .frame(width: 250)
            Divider()
            Group {
                switch selection ?? .current {
                case .current:
                    CurrentStackDetail(stack: stack)
                case .saved(let id):
                    if let saved = library.stacks.first(where: { $0.id == id }) {
                        SavedStackDetail(saved: saved, useAgain: { useAgain(id) }, delete: { delete(id) })
                    } else {
                        CurrentStackDetail(stack: stack)
                    }
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func lines(_ count: Int) -> String { count == 1 ? "1 line" : "\(count) lines" }

    private func useAgain(_ id: UUID) {
        library.useAgain(id)
        DictationStack.shared.show()
        selection = .current
    }

    private func delete(_ id: UUID) {
        library.delete(id)
        if selection == .saved(id) { selection = .current }
    }
}

private struct StackListRow: View {
    let name: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CurrentStackDetail: View {
    @ObservedObject var stack: DictationStack
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Stack")
                        .font(.title2.weight(.semibold))
                    Text(settings.stackMode ? "Stack Mode is on: new dictations are added here."
                         : "Dictations you add with the pill's stack button, or that had nowhere to paste, land here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save Stack") { StackPanel.shared.saveCurrentStack() }
                    .disabled(stack.queue.isEmpty)
                    .help("Put this stack aside for later and start a new one")
                Button("Copy All") { TextInserter.shared.copy(stack.joined) }
                    .disabled(stack.pasteItems.isEmpty)
                Button("Clear") { stack.clear() }
                    .disabled(stack.queue.isEmpty)
            }
            .padding(20)
            Divider()
            if stack.items.isEmpty {
                ContentUnavailableView("Nothing in the stack",
                                       systemImage: "rectangle.stack",
                                       description: Text("Turn on Stack Mode, or use the stack button on the pill while you dictate."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !stack.pins.isEmpty {
                        Section("Pinned") {
                            ForEach(stack.pins) { item in
                                StackLineRow(number: nil, item: item) { stack.remove(item.id) }
                            }
                            .onMove { stack.movePins(from: $0, to: $1) }
                        }
                    }
                    Section(stack.pins.isEmpty ? "" : "Stack") {
                        ForEach(Array(stack.queue.enumerated()), id: \.element.id) { index, item in
                            StackLineRow(number: index + 1, item: item) { stack.remove(item.id) }
                        }
                        .onMove { stack.moveQueue(from: $0, to: $1) }
                    }
                }
            }
        }
    }
}

private struct SavedStackDetail: View {
    let saved: SavedStack
    let useAgain: () -> Void
    let delete: () -> Void
    @ObservedObject private var library = StackLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: Binding(get: { saved.name }, set: { library.rename(saved.id, to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .help("Rename this stack")
                    Text("\(saved.items.count == 1 ? "1 line" : "\(saved.items.count) lines") · saved \(saved.saved.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Use Again", action: useAgain)
                    .help("Make this the current stack (the current one is saved first)")
                Button("Copy All") { TextInserter.shared.copy(saved.joined) }
                Button("Delete", role: .destructive, action: delete)
            }
            .padding(20)
            Divider()
            List {
                ForEach(Array(saved.items.enumerated()), id: \.element.id) { index, item in
                    StackLineRow(number: index + 1, item: item) { library.removeLine(item.id, from: saved.id) }
                }
                .onMove { library.moveLines(in: saved.id, from: $0, to: $1) }
            }
        }
    }
}

/// One line, in full and selectable; drag it to reorder.
private struct StackLineRow: View {
    let number: Int?
    let item: StackItem
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let number {
                    Text("\(number)").font(.callout.weight(.bold)).monospacedDigit()
                } else {
                    Image(systemName: "pin.fill").font(.caption)
                }
            }
            .foregroundStyle(Brand.violet)
            .frame(minWidth: 18, alignment: .trailing)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.added.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove this line")
        }
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { TextInserter.shared.copy(item.text) }
            Button("Remove", role: .destructive, action: remove)
        }
    }
}
