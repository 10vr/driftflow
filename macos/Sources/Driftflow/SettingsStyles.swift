import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Styles: the default AI Style and the per-app / per-website rules.
struct StylesPane: View {
    @ObservedObject var settings: AppSettings
    @State private var availability = AIRewriter.shared.availability

    private var aiAvailable: Bool { availability == .available }

    var body: some View {
        Form {
            if case .unavailable(let reason) = availability {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AI Styles need Apple Intelligence").fontWeight(.medium)
                            Text(reason).foregroundStyle(.secondary)
                            if #available(macOS 26.0, *) {
                                Button("Open Apple Intelligence Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Per-app rules for plain text and pressing Return still work without it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(AIStyle.allCases) { style in
                    StyleRow(style: style, selected: settings.aiStyle == style) { settings.aiStyle = style }
                        .disabled(style != .literal && !aiAvailable)
                }
            } header: {
                Text("Default style")
            } footer: {
                Text("Styles use Apple's on-device model: nothing leaves your Mac. They add about 0.3–0.5 s after you release the key and apply to English dictation. If a rewrite doesn't match what you said (for example, if it answers a question you dictated), your own words are inserted instead.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.appRules.isEmpty {
                    Text("No rules yet. Add one to use a different style in an app or on a website, type plain text in a terminal, or send chat messages automatically.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.appRules) { $rule in
                    RuleRow(rule: $rule, aiAvailable: aiAvailable) {
                        withAnimation(.snappy) { settings.appRules.removeAll { $0.id == rule.id } }
                    }
                }
                AddRuleMenu(settings: settings)
            } header: {
                Text("Apps and websites")
            } footer: {
                Text("Plain text: no capital at the start and no full stop at the end, for terminals, code and search boxes. Press Return: sends the message right after inserting it. Website rules work in Safari, Chrome, Arc, Edge and Brave, and win over the browser's own rule.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { availability = AIRewriter.shared.availability }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            availability = AIRewriter.shared.availability // e.g. back from turning Apple Intelligence on
        }
    }
}

private struct StyleRow: View {
    let style: AIStyle
    let selected: Bool
    let select: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.system(size: 14))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(style.label).fontWeight(.medium)
                    Text(style.summary).foregroundStyle(.secondary)
                    Text(style == .literal ? "“\(style.example)”" : "→ \(style.example)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .italic(style == .literal)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct RuleRow: View {
    @Binding var rule: AppRule
    let aiAvailable: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RuleIcon(rule: rule)
            if rule.isWebsite {
                TextField("", text: Binding(get: { rule.website ?? "" }, set: { rule.website = $0; rule.name = $0 }),
                          prompt: Text("example.com"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 170)
                    .onSubmit { rule.website = AppRule.normalizedHost(rule.website ?? ""); rule.name = rule.website ?? "" }
            } else {
                Text(rule.name).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
            }
            Spacer(minLength: 8)
            Picker("Style", selection: $rule.style) {
                Text("Default style").tag(AIStyle?.none)
                Divider()
                ForEach(AIStyle.allCases) { style in
                    Text(style.label).tag(AIStyle?.some(style)).disabled(style != .literal && !aiAvailable)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Toggle("Plain text", isOn: $rule.plainText).toggleStyle(.checkbox)
            Toggle("Press Return", isOn: $rule.pressReturn).toggleStyle(.checkbox)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this rule")
        }
    }
}

private struct RuleIcon: View {
    let rule: AppRule

    var body: some View {
        Group {
            if let id = rule.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: rule.isWebsite ? "globe" : "app.dashed")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// "Add App or Website": running apps first, then any app on disk, or a website.
private struct AddRuleMenu: View {
    @ObservedObject var settings: AppSettings

    private var runningApps: [NSRunningApplication] {
        let taken = Set(settings.appRules.compactMap(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { app in
                guard let id = app.bundleIdentifier, !taken.contains(id) else { return false }
                return seen.insert(id).inserted
            }
            .sorted { ($0.localizedName ?? "") .localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    var body: some View {
        Menu {
            Section("Open apps") {
                ForEach(runningApps, id: \.processIdentifier) { app in
                    Button {
                        add(bundleID: app.bundleIdentifier, name: app.localizedName ?? "App")
                    } label: {
                        if let icon = app.icon { Image(nsImage: Self.menuIcon(icon)) }
                        Text(app.localizedName ?? "App")
                    }
                }
            }
            Divider()
            Button("Other App…", action: chooseApp)
            Button("Website…") {
                withAnimation(.snappy) { settings.appRules.append(AppRule(website: "", name: "")) }
            }
        } label: {
            Label("Add App or Website", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func add(bundleID: String?, name: String) {
        guard let bundleID, !settings.appRules.contains(where: { $0.bundleID == bundleID }) else { return }
        withAnimation(.snappy) { settings.appRules.append(AppRule(bundleID: bundleID, name: name)) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add Rule"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        add(bundleID: bundle.bundleIdentifier, name: name)
    }

    private static func menuIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// Settings › Vocabulary › Snippets.
struct SnippetsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            ForEach($settings.snippets) { $snippet in
                HStack(alignment: .top) {
                    TextField("", text: $snippet.trigger, prompt: Text("my signature"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary).frame(width: 20).padding(.top, 4)
                    TextField("", text: $snippet.text, prompt: Text("Best,\nAlex"), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                    Button {
                        withAnimation(.snappy) { settings.snippets.removeAll { $0.id == snippet.id } }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20)
                    .padding(.top, 4)
                    .help("Remove this snippet")
                }
            }
            Button {
                withAnimation(.snappy) { settings.snippets.append(Snippet(trigger: "", text: "")) }
            } label: {
                Label("Add Snippet", systemImage: "plus")
            }
        } header: {
            Text("Snippets")
        } footer: {
            Text("Say the phrase on its own and the whole text is inserted exactly as saved, line breaks included. Use \(Snippet.placeholders.map { "\($0.token) for \($0.meaning)" }.joined(separator: ", ")).")
                .foregroundStyle(.secondary)
        }
    }
}
