import AppKit
import ApplicationServices

// MARK: - Per-app rules

/// Different behaviour in one app or website: a style, plain text for terminals and code, or
/// pressing Return to send.
struct AppRule: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    /// The app's bundle identifier; nil for a website rule.
    var bundleID: String?
    /// A website's domain ("mail.google.com", "slack.com"), matching its subdomains too.
    var website: String?
    /// The app's name or the domain, for display.
    var name: String
    /// nil: the default style from Settings.
    var style: AIStyle?
    /// No capital letter at the start and no full stop at the end (terminals, code, search boxes).
    var plainText = false
    /// Press Return after inserting, to send the message.
    var pressReturn = false

    var isWebsite: Bool { website != nil }

    /// Hosts are compared without "www." and match subdomains: "google.com" covers "mail.google.com".
    func matches(host: String) -> Bool {
        guard let website = website.map(Self.normalizedHost), !website.isEmpty else { return false }
        let host = Self.normalizedHost(host)
        return host == website || host.hasSuffix("." + website)
    }

    /// "https://www.Mail.google.com/x" → "mail.google.com".
    static func normalizedHost(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let url = URL(string: host.contains("://") ? host : "https://" + host), let parsed = url.host() { host = parsed }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// Where a dictation is going, captured when it starts.
struct DictationTarget: Sendable {
    var bundleID: String?
    /// The current page's host, when the app is a browser and you have website rules.
    var host: String?

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "com.apple.SafariTechnologyPreview", "com.google.Chrome.canary", "ai.perplexity.comet",
    ]

    /// The page address from the focused web area (Safari, Chrome and other Chromium browsers
    /// expose it through Accessibility). Runs off the main thread.
    static func currentHost() async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.1)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            var element = focused as! AXUIElement
            // Walk up to the web area that holds the focused field.
            for _ in 0..<40 {
                AXUIElementSetMessagingTimeout(element, 0.1)
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                if (role as? String) == "AXWebArea" {
                    var url: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &url) == .success {
                        if let url = url as? URL { return url.host() }
                        if let string = url as? String { return URL(string: string)?.host() }
                    }
                    return nil
                }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
                element = parent as! AXUIElement
            }
            return nil
        }.value
    }
}

/// The settings one dictation actually uses, after applying any rule for where it's going.
struct EffectiveRules: Equatable {
    var style: AIStyle
    var plainText = false
    var pressReturn = false
    /// The rule that applied (for History), or nil.
    var ruleName: String?

    static func resolve(_ rules: [AppRule], target: DictationTarget, defaultStyle: AIStyle) -> EffectiveRules {
        // A website rule is more specific than its browser's app rule.
        let rule = target.host.flatMap { host in rules.first { $0.matches(host: host) } }
            ?? target.bundleID.flatMap { id in rules.first { $0.bundleID == id } }
        guard let rule else { return EffectiveRules(style: defaultStyle) }
        return EffectiveRules(style: rule.style ?? defaultStyle, plainText: rule.plainText, pressReturn: rule.pressReturn,
                              ruleName: rule.name)
    }
}

extension TextProcessor {
    /// For terminals, code and search boxes: no capital at the start (unless it's "I", an acronym
    /// or one of your vocabulary words) and no full stop after a single sentence.
    static func plain(_ input: String, vocabulary: [String]) -> String {
        var text = input
        if text.hasSuffix("."), !text.hasSuffix(".."),
           !text.dropLast().contains(where: { ".!?\n".contains($0) }) {
            text.removeLast()
        }
        let first = String(text.prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" })
        let keep = first.isEmpty || first == "I" || first.hasPrefix("I'") || first.hasPrefix("I’")
            || first.dropFirst().contains(where: \.isUppercase) || vocabulary.contains(first)
        if !keep { text = text.prefix(1).lowercased() + text.dropFirst() }
        return text
    }
}

// MARK: - Snippets

/// Say a phrase on its own and a saved text is inserted instead ("my signature" → your sign-off).
struct Snippet: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var trigger: String
    var text: String

    /// Placeholders filled in at insert time.
    static let placeholders: [(token: String, meaning: String)] = [
        ("{date}", "today's date"), ("{time}", "the time"), ("{day}", "the weekday"), ("{clipboard}", "the clipboard"),
    ]

    /// Lowercase letters and digits only, single spaces: how a spoken phrase is compared.
    static func normalized(_ text: String) -> String {
        TextProcessor.stripFillers(text).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The snippet whose phrase is everything you said, if any.
    static func match(_ spoken: String, in snippets: [Snippet]) -> Snippet? {
        let said = normalized(spoken)
        guard !said.isEmpty else { return nil }
        return snippets.first { !$0.text.isEmpty && normalized($0.trigger) == said }
    }

    func expanded(now: Date = Date(), clipboard: String? = NSPasteboard.general.string(forType: .string)) -> String {
        text.replacingOccurrences(of: "{date}", with: now.formatted(date: .long, time: .omitted))
            .replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
            .replacingOccurrences(of: "{day}", with: now.formatted(.dateTime.weekday(.wide)))
            .replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
    }
}

// MARK: - Learning from corrections

/// Watches the field a dictation went into. If you fix a word that Driftflow typed, and the fix
/// looks like a name or term (not an ordinary word), it offers to add it to your Vocabulary.
///
/// Uses Accessibility to read the field's text (never keystrokes), only for the next minute and a
/// half, only in that one field, and nothing is stored except a word you choose to add.
@MainActor
final class CorrectionWatcher {
    private var timer: Timer?
    private var element: AXUIElement?
    private var baseline = ""
    /// Where the dictated text sits in `baseline`, in UTF-16 units.
    private var inserted = NSRange(location: NSNotFound, length: 0)
    private var lastValue = ""
    private var stableTicks = 0
    private var deadline = Date()
    private var vocabulary: [String] = []
    private var onSuggest: ((String) -> Void)?
    /// Suggestions you've already been offered this session (don't nag).
    private var offered: Set<String> = []

    func stop() {
        timer?.invalidate()
        timer = nil
        element = nil
    }

    /// Starts watching the focused field for edits to `text`, which was just inserted.
    func watch(inserted text: String, vocabulary: [String], onSuggest: @escaping (String) -> Void) {
        stop()
        self.vocabulary = vocabulary
        self.onSuggest = onSuggest
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 3 else { return }
        // Give the app a moment to take the paste before reading the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let (element, value, caret) = Self.focusedField(), value.utf16.count < 200_000 else { return }
            let haystack = value as NSString
            // The copy just before the caret, or failing that the last one in the field.
            var range = haystack.range(of: needle, options: .backwards,
                                       range: NSRange(location: 0, length: min(max(caret, 0), haystack.length)))
            if range.location == NSNotFound { range = haystack.range(of: needle, options: .backwards) }
            guard range.location != NSNotFound else { return }
            self.element = element
            self.baseline = value
            self.lastValue = value
            self.inserted = range
            self.stableTicks = 0
            self.deadline = Date().addingTimeInterval(90)
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                onMainThread { self?.tick() }
            }
        }
    }

    private func tick() {
        guard let element, Date() < deadline else { return stop() }
        AXUIElementSetMessagingTimeout(element, 0.1)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let value = raw as? String else { return stop() } // field closed or went away
        if value != lastValue {
            lastValue = value
            stableTicks = 0
            return
        }
        // Judge an edit once you've paused (two quiet readings in a row).
        stableTicks += 1
        guard stableTicks == 2, value != baseline else { return }
        switch Self.classify(from: baseline, to: value, inserted: inserted) {
        case .elsewhere(let moved):
            // You typed or edited outside the dictation: keep watching it where it now sits.
            baseline = value
            inserted = moved
        case .rewritten:
            stop() // changed in a way that isn't a term fix
        case .term(let term):
            stop()
            let known = vocabulary.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
            guard !known, !offered.contains(term.lowercased()) else { return }
            offered.insert(term.lowercased())
            onSuggest?(term)
        }
    }

    /// The field with focus, its text and its caret, or nil if the app doesn't expose them.
    private static func focusedField() -> (AXUIElement, String, Int)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let value = raw as? String else { return nil }
        var caret = (value as NSString).length
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var selection = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) { caret = selection.location }
        }
        return (element, value, caret)
    }

    enum Change: Equatable {
        /// One to three dictated words replaced by one or two that look like a name or term.
        case term(String)
        /// The edit didn't touch the dictated text, which is now at this range.
        case elsewhere(NSRange)
        /// The dictated text was edited some other way.
        case rewritten
    }

    /// How `before` became `after`, relative to the dictated text at `inserted`. Pure, for testing.
    static func classify(from before: String, to after: String, inserted: NSRange) -> Change {
        let old = before as NSString, new = after as NSString
        // Common prefix and suffix (UTF-16), not overlapping.
        var prefix = 0
        let shorter = min(old.length, new.length)
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        let delta = new.length - old.length
        if old.length - suffix <= inserted.location { // entirely before the dictation
            return .elsewhere(NSRange(location: inserted.location + delta, length: inserted.length))
        }
        if prefix >= NSMaxRange(inserted) { return .elsewhere(inserted) } // entirely after
        // Widen to whole words (the same in both strings: that part is shared).
        func isWordUnit(_ string: NSString, _ index: Int) -> Bool {
            guard index >= 0, index < string.length, let scalar = Unicode.Scalar(string.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "’" || scalar == "-"
        }
        while prefix > 0, isWordUnit(old, prefix - 1) { prefix -= 1 }
        while suffix > 0, isWordUnit(old, old.length - suffix) { suffix -= 1 }
        let oldRange = NSRange(location: prefix, length: old.length - suffix - prefix)
        let newRange = NSRange(location: prefix, length: new.length - suffix - prefix)
        guard oldRange.length > 0, newRange.length > 0, newRange.length <= 40,
              NSIntersectionRange(oldRange, inserted).length == oldRange.length else { return .rewritten }
        let was = old.substring(with: oldRange).trimmingCharacters(in: .whitespaces)
        let now = new.substring(with: newRange).trimmingCharacters(in: .whitespaces)
        let wasWords = was.split(separator: " "), nowWords = now.split(separator: " ")
        guard (1...3).contains(wasWords.count), (1...2).contains(nowWords.count), !now.contains("\n"),
              now.filter(\.isLetter).count >= 3, was != now else { return .rewritten }

        // Same letters, new spelling ("open AI" → "OpenAI", "iphone" → "iPhone"): always worth keeping.
        let letters = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        if letters(was) == letters(now) { return now.contains(where: \.isUppercase) ? .term(now) : .rewritten }

        // Otherwise it must sound alike (similar spelling) and be a name or term, not a rewording.
        let distance = levenshtein(Array(letters(was)), Array(letters(now)))
        guard Double(distance) <= Double(max(letters(was).count, letters(now).count)) * 0.6 else { return .rewritten }
        let innerCaps = nowWords.contains { $0.dropFirst().contains(where: \.isUppercase) }
        // A capital mid-sentence marks a name ("to Kubernetes"); at a sentence start it says nothing.
        let before = new.substring(to: newRange.location).trimmingCharacters(in: .whitespaces)
        let sentenceStart = before.last.map { ".!?:\n".contains($0) } ?? true
        let name = !sentenceStart && now.first?.isUppercase == true && was.first?.isUppercase != true
        // The spell checker also knows words you've taught it, so it only helps in one direction.
        let unknown = nowWords.contains { !isDictionaryWord(String($0)) }
        return innerCaps || name || unknown ? .term(now) : .rewritten
    }

    private static func isDictionaryWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false, inSpellDocumentWithTag: 0,
                                          wordCount: nil)
        return range.location == NSNotFound
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Reading the selection (voice editing)

enum SelectionReader {
    /// The selected text in the focused app: through Accessibility, or failing that by copying it
    /// (⌘C) and putting your clipboard back straight after.
    @MainActor
    static func read() async -> String? {
        if let text = await accessibilitySelection(), !text.isEmpty { return text }
        return await copySelection()
    }

    private static func accessibilitySelection() async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.15)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.15)
            var selected: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
            return selected as? String
        }.value
    }

    @MainActor
    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let before = pasteboard.changeCount
        TextInserter.shared.sendCopy()
        var text: String?
        for _ in 0..<20 { // up to 400 ms for the app to copy
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return text
    }
}
