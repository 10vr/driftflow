import AppKit
import SwiftUI

extension StackPanel {
    /// New Stack (＋ on the floating stack, its ▾, or its tab's menu): a fresh one in use.
    func newStack() {
        let previous = DictationStack.shared.active?.name
        DictationStack.shared.newStack()
        guard let previous else { return }
        DictationController.shared.showToast(HUDToast(icon: "rectangle.stack.badge.plus",
                                                      text: "New stack started. “\(previous)” is in All Stacks.",
                                                      action: .openStacks), for: 4)
    }
}

// MARK: - The Stacks page

/// Stacks in the main window: every stack in one list, the one in use marked, each shown in full
/// to rename, reorder, copy or switch to; and the pinned lines they all share.
struct StacksPane: View {
    enum Selection: Hashable {
        case pins
        case stack(UUID)
    }

    @ObservedObject private var store = DictationStack.shared
    @State private var selection: Selection?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    if !store.pins.isEmpty {
                        Section {
                            StackListRow(name: "Pinned", detail: lines(store.pins.count), icon: "pin", inUse: false, selected: current == .pins)
                                .tag(Selection.pins)
                        }
                    }
                    Section("Stacks") {
                        ForEach(store.stacks.reversed()) { stack in
                            StackListRow(name: stack.name,
                                         detail: "\(lines(stack.items.count)) · \(stack.lastChanged.formatted(.relative(presentation: .named)))",
                                         icon: "rectangle.stack", inUse: stack.id == store.activeID,
                                         selected: current == .stack(stack.id))
                                .tag(Selection.stack(stack.id))
                                .contextMenu {
                                    if stack.id != store.activeID {
                                        Button("Use This Stack") { store.activate(stack.id) }
                                    }
                                    Button("Copy All") { TextInserter.shared.copy(stack.joined) }
                                        .disabled(stack.items.isEmpty)
                                    Divider()
                                    Button("Delete", role: .destructive) { delete(stack.id) }
                                }
                        }
                    }
                }
                Divider()
                HStack {
                    Button {
                        store.newStack()
                        selection = store.activeID.map(Selection.stack)
                    } label: {
                        Label("New Stack", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(10)
            }
            .frame(width: 250)
            Divider()
            Group {
                switch current {
                case .pins:
                    PinsDetail(store: store)
                case .stack(let id):
                    if let stack = store.stacks.first(where: { $0.id == id }) {
                        StackDetail(stack: stack, inUse: stack.id == store.activeID, store: store) { delete(id) }
                    } else {
                        empty
                    }
                case nil:
                    empty
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            store.prune()
            if selection == nil { selection = current }
        }
    }

    /// The selected stack, or the one in use.
    private var current: Selection? {
        if let selection, selection == .pins ? !store.pins.isEmpty : store.stacks.contains(where: { .stack($0.id) == selection }) {
            return selection
        }
        return store.activeID.map(Selection.stack) ?? store.stacks.last.map { .stack($0.id) }
    }

    private var empty: some View {
        ContentUnavailableView("No stacks yet", systemImage: "rectangle.stack",
                               description: Text("Turn on Stack Mode, or use the stack button on the pill while you dictate."))
    }

    private func lines(_ count: Int) -> String { count == 1 ? "1 line" : "\(count) lines" }

    private func delete(_ id: UUID) {
        store.deleteStack(id)
        if selection == .stack(id) { selection = nil }
    }
}

private struct StackListRow: View {
    let name: String
    let detail: String
    let icon: String
    let inUse: Bool
    /// On the selection's accent colour, the violet marks turn white.
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(inUse && !selected ? AnyShapeStyle(Brand.violet) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if inUse {
                Text("In Use")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(selected ? Color.white : Brand.violet)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Brand.violet.opacity(0.14)))
            }
        }
        .padding(.vertical, 2)
    }
}

private struct StackDetail: View {
    let stack: NamedStack
    let inUse: Bool
    @ObservedObject var store: DictationStack
    let delete: () -> Void

    /// " · kept 30 days after its last change", when History (and so stacks) isn't kept forever.
    private var keptFor: String {
        switch AppSettings.shared.historyRetention {
        case .day: " · kept 1 day after its last change"
        case .week: " · kept 7 days after its last change"
        case .month: " · kept 30 days after its last change"
        case .off, .forever: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: Binding(get: { stack.name }, set: { store.rename(stack.id, to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .help("Rename this stack")
                    Text(inUse ? "In use: it's the floating stack at the bottom right, and new dictations go into it."
                         : "\(stack.items.count == 1 ? "1 line" : "\(stack.items.count) lines") · last changed \(stack.lastChanged.formatted(date: .abbreviated, time: .shortened))\(keptFor)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if inUse {
                    Button("Show") { StackPanel.shared.open() }
                        .help("Open the floating stack")
                } else {
                    Button("Use This Stack") { store.activate(stack.id) }
                        .buttonStyle(.borderedProminent)
                        .help("Show it in the floating stack; new dictations go into it")
                }
                Button("Copy All") { TextInserter.shared.copy(stack.joined) }
                    .disabled(stack.items.isEmpty)
                Button("Delete", role: .destructive, action: delete)
            }
            .padding(20)
            Divider()
            if stack.items.isEmpty {
                ContentUnavailableView("Empty", systemImage: "rectangle.stack",
                                       description: Text(inUse ? "New dictations will stack up here." : "This stack has no lines."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(stack.items.enumerated()), id: \.element.id) { index, item in
                        StackLineRow(number: index + 1, item: item) { store.remove(item.id) }
                    }
                    .onMove { store.moveLines(in: stack.id, from: $0, to: $1) }
                }
            }
        }
    }
}

private struct PinsDetail: View {
    @ObservedObject var store: DictationStack

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pinned")
                    .font(.title2.weight(.semibold))
                Text("Pinned lines show at the top of every stack and stay after you paste them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            List {
                ForEach(store.pins) { item in
                    StackLineRow(number: nil, item: item) { store.remove(item.id) }
                }
                .onMove { store.movePins(from: $0, to: $1) }
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
