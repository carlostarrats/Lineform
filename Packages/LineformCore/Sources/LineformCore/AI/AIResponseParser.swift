import Foundation

/// Reads an AI reply. The reply is untrusted: anything unexpected is refused (nil), never
/// repaired, and nothing here can trap on junk input.
public enum AIResponseParser {
    /// The revised segments, or nil unless the reply's JSON object carries `segments` as an
    /// array of exactly `expectedCount` strings. Tolerates code fences and preambles by reading
    /// from the first `{` to the last `}`.
    public static func segments(from reply: String, expectedCount: Int) -> [String]? {
        guard let object = jsonObject(in: reply),
              let array = object["segments"] as? [Any],
              array.count == expectedCount else { return nil }
        var result: [String] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let string = element as? String else { return nil }
            result.append(string)
        }
        return result
    }

    /// 0-based indices of the marked sentences: deduped, sorted, in range, and capped at
    /// `max(1, ⌈sentenceCount / 3⌉)` (the first ones kept). The model numbers from 1. nil when
    /// the reply has no `sentences` array.
    public static func sentenceIndices(from reply: String, sentenceCount: Int) -> [Int]? {
        guard let object = jsonObject(in: reply),
              let array = object["sentences"] as? [Any] else { return nil }
        guard sentenceCount > 0 else { return [] }
        var seen = Set<Int>()
        for element in array {
            guard let number = element as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let value = number.doubleValue
            // Bound before any Int conversion: a huge or non-finite number would trap.
            guard value.isFinite, value >= 1, value <= Double(sentenceCount), value == value.rounded() else { continue }
            seen.insert(Int(value) - 1)
        }
        let cap = max(1, (sentenceCount + 2) / 3)
        return Array(seen.sorted().prefix(cap))
    }

    /// The longest answer kept, in characters; the rest is dropped.
    static let maxAnswerLength = 4_000

    /// A prose answer: the reply's `answer` string, or — for a question, when the model ignored
    /// the format and wrote no JSON object at all — the reply itself. Plain text only: control
    /// characters other than line breaks and tabs are removed, the result is trimmed and capped.
    /// nil when there is nothing to show.
    public static func answer(from reply: String, allowsPlainText: Bool = false) -> String? {
        let raw: String
        if let object = jsonObject(in: reply) {
            guard let answer = object["answer"] as? String else { return nil }
            raw = answer
        } else if allowsPlainText {
            raw = reply
        } else {
            return nil
        }
        let kept = raw.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.properties.generalCategory != .control
        }
        let cleaned = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxAnswerLength))
    }

    /// The reply's blanks: at most two guesses, each found verbatim in `revisions`, with a line
    /// that contains it, a question and 2–4 short options (the phrase first). Anything malformed
    /// is dropped, never repaired; a reply without them simply has none.
    public static func assumptions(from reply: String, revisions: [String]) -> [AIAssumption] {
        guard let object = jsonObject(in: reply), let array = object["assumptions"] as? [Any] else { return [] }
        func clean(_ value: Any?, max: Int) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, (text as NSString).length <= max,
                  !text.unicodeScalars.contains(where: {
                      let category = $0.properties.generalCategory
                      return category == .control || category == .lineSeparator || category == .paragraphSeparator
                  }) else { return nil }
            return text
        }
        var result: [AIAssumption] = []
        for element in array.prefix(4) {
            guard result.count < 2, let item = element as? [String: Any],
                  let phrase = clean(item["phrase"], max: 80),
                  let line = clean(item["line"], max: 200), line.contains(phrase),
                  let question = clean(item["question"], max: 120),
                  revisions.contains(where: { $0.contains(phrase) }),
                  !result.contains(where: { $0.phrase == phrase }) else { continue }
            var options = [phrase]
            for option in (item["options"] as? [Any] ?? []) {
                guard let text = clean(option, max: 80), !options.contains(text), options.count < 4 else { continue }
                options.append(text)
            }
            guard options.count >= 2 else { continue }
            result.append(AIAssumption(phrase: phrase, line: line, question: question, options: options))
        }
        return result
    }

    private static func jsonObject(in reply: String) -> [String: Any]? {
        guard let open = reply.firstIndex(of: "{"),
              let close = reply.lastIndex(of: "}"),
              open < close else { return nil }
        let data = Data(reply[open...close].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// One guess the AI made while rewriting ("I assumed you'll share it by Friday"): a blank the
/// writer can fill in. `phrase` occurs verbatim in the suggestion; choosing an option rewrites it
/// there (`AIActionController.applyAssumption`), with no request.
public struct AIAssumption: Equatable, Sendable {
    public let phrase: String
    public let line: String
    public let question: String
    public let options: [String]

    public init(phrase: String, line: String, question: String, options: [String]) {
        self.phrase = phrase
        self.line = line
        self.question = question
        self.options = options
    }

    /// `line` split around the phrase, for drawing the blank inside it.
    public var lineParts: (before: String, after: String) {
        guard let range = line.range(of: phrase) else { return (line + " ", "") }
        return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }
}

/// Is a typed instruction a QUESTION about the passage (answered in prose) rather than a request
/// to change it? On the device, with no request. Only a clear question counts: it ends with a
/// question mark or opens with a question word, and it neither asks for an edit ("Can you make
/// this shorter?") nor names one of the curated style words. Anything unclear is an edit request,
/// whose prompt still lets the model answer in prose (`AIActionPrompt.conversationInstruction`).
public enum AIRequestClassifier {
    static let questionOpeners: Set<String> = [
        "why", "what", "what's", "whats", "how", "how's", "is", "are", "does", "do", "did", "can", "could",
        "should", "would", "will", "which", "who", "whom", "whose", "where", "when", "am", "was", "were", "has", "have",
    ]
    static let whOpeners: Set<String> = ["why", "what", "what's", "whats", "which", "who", "whom", "whose", "where", "when"]
    static let editVerbs: Set<String> = [
        "make", "rewrite", "rephrase", "reword", "change", "fix", "shorten", "trim", "cut", "simplify", "turn",
        "edit", "improve", "tighten", "expand", "polish", "proofread", "add", "remove", "replace", "write",
        "translate", "convert", "condense", "clean", "soften", "lengthen", "drop", "delete", "use", "put",
    ]

    public static func isQuestion(_ text: String, words: [AIPromptWord] = AIPromptLexicon.current) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let separators = CharacterSet.letters.union(CharacterSet(charactersIn: "'’")).inverted
        let tokens = trimmed.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        let endsWithMark = trimmed.hasSuffix("?") || trimmed.hasSuffix("？")
        // "Why does this sound so informal?": a wh-question is a question whatever it names.
        if let first = tokens.first, whOpeners.contains(first) { return true }
        let opensWithQuestionWord = tokens.first.map(questionOpeners.contains) ?? false
        guard endsWithMark || opensWithQuestionWord else { return false }
        // "Can you make this shorter?", "Could you please rewrite…": a polite request.
        if tokens.prefix(5).contains(where: editVerbs.contains) { return false }
        if !AIPromptLexicon.matches(in: trimmed, words: words).isEmpty { return false }
        return true
    }
}
