import ApplicationServices
import Foundation

/// Deterministic, microsecond-fast cleanup applied after transcription. No LLM round-trip.
struct TextProcessor {
    var removeFillers = true
    var spokenCommands = true
    var replacements: [(String, String)] = []
    /// The user's words, spelled their way: "DriftFlow", "drift flow" and "Drift-Flow" all become
    /// "Driftflow"; "open ai" becomes "OpenAI".
    var vocabulary: [String] = []

    /// Fillers only in the forms speech models write them: lowercase or capitalized, never
    /// all-caps (ER, UM are acronyms) and never inside a hyphenated word ("Uh-oh").
    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}'\-])(?:[Uu]m+|[Uu]h+|[Ee]rm+|[Ee]r|[Aa]h+|[Hh]mm+|[Mm]hm)(?![\p{L}'\-])([,.!?])?[ \t]*"#
    )
    private static let commandPatterns: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"(?i)\s*\bnew paragraph\b[,.]?\s*"#), "\n\n"),
        (try! NSRegularExpression(pattern: #"(?i)\s*\bnew line\b[,.]?\s*"#), "\n"),
    ]

    /// `english`: filler words are English ("er" and "um" are real words in German, Dutch…).
    func process(_ input: String, english: Bool = true) -> String {
        var text = input
        if removeFillers, english { text = Self.stripFillers(text) }
        if spokenCommands {
            for (pattern, replacement) in Self.commandPatterns {
                text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
            }
        }
        // Tidy spacing left behind by removals and capitalize each line, before your own words are
        // applied, so vocabulary and replacements come out exactly as written ("iPhone", an email).
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" +([,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #",+([.!?])"#, with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.prefix(1).uppercased() + line.dropFirst() }
            .joined(separator: "\n")
        text = applyVocabulary(text)
        for (from, to) in replacements where !from.isEmpty {
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
            text = text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: to), options: .regularExpression)
        }
        return text
    }

    /// Removes filler words. One that started a sentence hands its capital to the next word
    /// ("Um, so we go." → "So we go."); one that ended a sentence keeps the full stop.
    static func stripFillers(_ input: String) -> String {
        let text = NSMutableString(string: input)
        for match in fillerPattern.matches(in: input, range: NSRange(location: 0, length: text.length)).reversed() {
            let before = text.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
            let startsSentence = before.last.map { ".!?\n".contains($0) } ?? true
            let punctuation = match.range(at: 1).location == NSNotFound ? "" : text.substring(with: match.range(at: 1))
            let keep = !startsSentence && ".!?".contains(punctuation) && !punctuation.isEmpty ? punctuation : ""
            text.replaceCharacters(in: match.range, with: keep)
            let next = match.range.location + (keep as NSString).length
            if startsSentence, keep.isEmpty, next < text.length {
                let range = text.rangeOfComposedCharacterSequence(at: next)
                text.replaceCharacters(in: range, with: text.substring(with: range).uppercased())
            }
        }
        return text as String
    }
}

extension TextProcessor {
    /// Only as a phrase of its own (start of text or after punctuation, and followed by punctuation
    /// or the end), so "don't scratch that surface" is left alone.
    private static let scratchPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|(?<=[.,!?;:\n]))\s*scratch that(?:\s*[.,!?;:]+|\s*$)\s*"#
    )

    /// "Scratch that" deletes the sentence said just before it: "Meet at five. Scratch that. Meet
    /// at six." keeps "Meet at six." Said first in a dictation, it refers to the previous dictation,
    /// which the caller removes from the app (`undoPrevious`). English only, like the other commands.
    func applyScratch(_ input: String) -> (text: String, undoPrevious: Bool) {
        guard spokenCommands else { return (input, false) }
        // Fillers first, so "Um, scratch that" scratches the sentence before, not the "um".
        var text = removeFillers ? Self.stripFillers(input) : input
        var undoPrevious = false
        while let match = Self.scratchPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) {
            let head = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            var rest = String(text[range.upperBound...])
            var kept = ""
            if head.isEmpty {
                undoPrevious = true
            } else {
                // Drop the scratched sentence: back to the end of the one before it (or the start).
                let body = head.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;: "))
                if let end = body.lastIndex(where: { ".!?\n".contains($0) }) {
                    kept = String(body[...end])
                }
            }
            if kept.isEmpty || kept.last.map({ ".!?\n".contains($0) }) == true {
                rest = rest.prefix(1).uppercased() + rest.dropFirst()
            }
            let joiner = kept.isEmpty || kept.hasSuffix("\n") || rest.isEmpty ? "" : " "
            text = kept + joiner + rest
        }
        return (text.trimmingCharacters(in: .whitespaces), undoPrevious)
    }

    /// Vocabulary spellings and replacements only (no filler removal or spoken commands), for
    /// transcripts of recordings.
    func applyVocabularyAndReplacements(_ input: String) -> String {
        var text = applyVocabulary(input)
        for (from, to) in replacements where !from.isEmpty {
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
            text = text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: to), options: .regularExpression)
        }
        return text
    }

    /// Rewrites any casing or spacing of a vocabulary term as the term itself.
    func applyVocabulary(_ input: String) -> String {
        var text = input
        for term in vocabulary {
            let characters = Array(term.filter { $0.isLetter || $0.isNumber })
            guard characters.count >= 3 else { continue }
            // A space or hyphen may appear only where the term splits into real parts: at a case
            // change ("Open|AI") or between two parts of 3+ letters ("drift|flow"). Anything looser
            // lets a short name swallow ordinary words ("a man" → "Aman").
            var body = ""
            for (index, character) in characters.enumerated() {
                if index > 0 {
                    let caseChange = characters[index - 1].isLowercase && character.isUppercase
                    if caseChange || (index >= 3 && characters.count - index >= 3) { body += "[\\s\\-]?" }
                }
                body += NSRegularExpression.escapedPattern(for: String(character))
            }
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])"
            text = text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: term), options: .regularExpression)
        }
        return text
    }
}

/// What sits just before the caret in the focused text field, read through Accessibility while the
/// user is still talking (off the critical path) so spacing can be decided instantly at insert time.
struct CaretContext: Sendable {
    /// Up to two characters before the caret, or nil if the app doesn't expose them.
    let precedingText: String?

    static let unknown = CaretContext(precedingText: nil)

    /// Leading space to add so dictations chain naturally ("…end.| Next" / "word| next").
    func leadingSpace(for text: String) -> String {
        guard let preceding = precedingText, let last = preceding.last, let first = text.first else { return "" }
        if last.isWhitespace || first.isWhitespace || first.isPunctuation { return "" }
        if "([{\"'“‘/-".contains(last) { return "" }
        return " "
    }

    /// Reads the caret context of the system-wide focused element. Runs off the main thread.
    static func capture() async -> CaretContext {
        await Task.detached(priority: .userInitiated) { () -> CaretContext in
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.08)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.08)

            var rangeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
                  let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .unknown }
            var selection = CFRange()
            guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return .unknown }
            if selection.location == 0 { return CaretContext(precedingText: "\n") } // start of field

            var before = CFRange(location: max(0, selection.location - 2), length: min(2, selection.location))
            guard let request = AXValueCreate(.cfRange, &before) else { return .unknown }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, request, &result
            ) == .success, let string = result as? String else { return .unknown }
            return CaretContext(precedingText: string)
        }.value
    }
}
