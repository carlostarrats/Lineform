import Foundation

/// One of Lineform's curated "vague words": a word writers use to ask for a change ("more
/// professional", "punchier") that the AI follows better as concrete directions. Typed in the AI
/// drawer's input, it is underlined at once, on the device, with no request; tapping it offers its
/// refinements, and the chosen ones travel with the instruction as explicit directions
/// (`AIPromptLexicon.directions`).
///
/// The list is internal (the writer never browses it). Its words and refinements come from the
/// 2026-11-24 vocabulary research (product menus, research taxonomies, real prompts); every
/// refinement is phrased as an observable property of the output, and none is crude or offensive.
/// Each word matches its forms in all six languages (`AIPromptLexicon.formTables`); its question
/// and chip labels are shown in the interface language.
public struct AIPromptWord: Sendable, Equatable, Identifiable {
    public enum Group: String, CaseIterable, Sendable {
        case tone, length, clarity, energy, polish, audience
    }

    /// One concrete meaning of the word: a short chip label and the direction sent to the model.
    public struct Refinement: Sendable, Equatable, Identifiable {
        public var id: String { key }
        /// The English label: the catalog key and a stable identity. Never shown outside English.
        public let key: String
        /// The chip's text, in the interface language.
        public let label: String
        /// The instruction to the model, in English whatever the interface or typed language.
        public let direction: String
    }

    /// Stable identity (the word's base form). Never shown, never persisted.
    public let id: String
    public let group: Group
    /// The options card's heading ("Professional how?"), in the interface language.
    public let question: String
    public let refinements: [Refinement]
    /// Labels of the refinements preselected (and sent while the writer has not chosen).
    public let defaults: [String]
    /// Every form that matches, in every language, each with its matching rule.
    let taggedForms: [AIPromptForm]

    /// Phrases and word forms that match, lower case ("more professional", "kürzer", "短く").
    public var forms: [String] { taggedForms.map(\.text) }

    /// The refinement with this chip label (or its English key).
    public func refinement(_ label: String) -> Refinement? {
        refinements.first { $0.label == label } ?? refinements.first { $0.key == label }
    }
}

/// Where a curated word sits in the typed instruction, in UTF-16 units of that text.
public struct AIPromptWordMatch: Sendable, Equatable {
    public let wordID: String
    public let range: NSRange

    public init(wordID: String, range: NSRange) {
        self.wordID = wordID
        self.range = range
    }
}

/// One matchable form and how it is compared. The rule belongs to the form's language.
struct AIPromptForm: Sendable, Equatable {
    enum Rule: Sendable, Equatable {
        /// English, French, Spanish: case- and accent-insensitive (writers drop accents).
        case folded
        /// German: case-insensitive, but umlauts count ("kürzer" is not "kurzer").
        case umlautSensitive
        /// An English form that is also a German noun ("brief" / Brief, "kinder" / Kinder): it
        /// matches capitalized only where a sentence starts, so German text is not underlined.
        case lowercaseUnlessSentenceStart
        /// Japanese and Chinese: no spaces, so no word boundary on a CJK edge; width- and
        /// case-insensitive (for "AI" in "AIっぽさ").
        case cjk

        var options: NSString.CompareOptions {
            switch self {
            case .folded, .lowercaseUnlessSentenceStart: return [.caseInsensitive, .diacriticInsensitive]
            case .umlautSensitive: return [.caseInsensitive]
            case .cjk: return [.caseInsensitive, .widthInsensitive]
            }
        }
    }

    let text: String
    let rule: Rule
}

/// The compiled matcher: every form of every word (plus the blockers), longest first, with the
/// per-form comparison and boundary rules worked out once. Built when a conversation starts, never
/// per keystroke.
struct AIPromptTable: Sendable {
    struct Entry: Sendable {
        /// nil for a blocker: it claims its span (so a shorter form inside it cannot match) and
        /// reports nothing.
        let wordID: String?
        let form: String
        let rule: AIPromptForm.Rule
        let leadingBoundary: Bool
        let trailingBoundary: Bool
        /// The form's first two characters (one for a one-character form), folded as
        /// `AIPromptTable.fold` folds the text: a form whose opening is not in the text is skipped
        /// without a search.
        let opening: String
    }

    let entries: [Entry]

    init(words: [AIPromptWord], blockers: [String] = AIPromptLexicon.blockers) {
        var entries: [Entry] = []
        func add(_ wordID: String?, _ form: AIPromptForm) {
            let scalars = form.text.unicodeScalars
            guard let first = scalars.first, let last = scalars.last,
                  case let folded = Self.fold(form.text), !folded.isEmpty else { return }
            entries.append(Entry(wordID: wordID, form: form.text, rule: form.rule,
                                 leadingBoundary: !AIPromptLexicon.isCJK(first),
                                 trailingBoundary: !AIPromptLexicon.isCJK(last),
                                 opening: String(folded.prefix(2))))
        }
        for word in words { for form in word.taggedForms { add(word.id, form) } }
        for blocker in blockers { add(nil, AIPromptForm(text: blocker, rule: .cjk)) }
        entries.sort {
            let left = ($0.form as NSString).length, right = ($1.form as NSString).length
            return left != right ? left > right : $0.form < $1.form
        }
        self.entries = entries
    }

    /// The loosest comparison any rule uses, so the opening filter never skips a form that would
    /// match.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Every folded character of `text` and every pair of neighbours: the openings it can match.
    static func openings(in text: String) -> Set<String> {
        let characters = Array(fold(text))
        var openings = Set<String>(minimumCapacity: characters.count * 2)
        for index in characters.indices {
            openings.insert(String(characters[index]))
            if index + 1 < characters.count { openings.insert(String(characters[index]) + String(characters[index + 1])) }
        }
        return openings
    }
}

public enum AIPromptLexicon {
    /// The fixed keep-constraint appended to every request built from the drawer's input.
    public static let keepConstraint = "Keep the meaning, facts, numbers and every Markdown mark; change only the selected passage."

    /// The languages whose forms are matched, all at once: a German writer on an English iPhone
    /// still gets "kürzer" underlined. Forms that are also everyday words in another of these
    /// languages are left out or narrowed (see `formTables`), so English text stays clean.
    public static let languages = ["en", "de", "fr", "es", "ja", "zh-Hans"]

    /// The words with their questions and chip labels in `code`'s language (the package
    /// catalog's `.lproj`; English is the key itself). Forms are the same for every language.
    public static func words(forLanguage code: String) -> [AIPromptWord] {
        words(localizing: localizer(forLanguage: code))
    }

    /// The words for the interface language the app is running in.
    public static let current: [AIPromptWord] = words(localizing: { String(localized: String.LocalizationValue($0), bundle: .module) })

    /// The words with English questions and labels.
    public static let english: [AIPromptWord] = words(forLanguage: "en")

    public static func word(_ id: String, in words: [AIPromptWord] = english) -> AIPromptWord? {
        words.first { $0.id == id }
    }

    /// Every curated word in `text`: longest forms first, case-insensitive (accents per language),
    /// whole words for Latin-script forms (a letter or digit on a Latin edge is no match), plain
    /// substrings on a Japanese or Chinese edge, never overlapping. Sorted by position. Pure and
    /// on the device, with no network. This convenience compiles `words` each call; the drawer
    /// matches per keystroke through a table it built once (`matches(in:table:)`).
    public static func matches(in text: String, words: [AIPromptWord] = current) -> [AIPromptWordMatch] {
        guard !text.isEmpty, !words.isEmpty else { return [] }
        return matches(in: text, table: words == current ? currentTable : AIPromptTable(words: words))
    }

    static let currentTable = AIPromptTable(words: current)

    static func matches(in text: String, table: AIPromptTable) -> [AIPromptWordMatch] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let present = AIPromptTable.openings(in: text)

        var taken = IndexSet()
        var found: [AIPromptWordMatch] = []
        for entry in table.entries where present.contains(entry.opening) {
            var searchStart = 0
            while searchStart < ns.length {
                let range = ns.range(of: entry.form, options: entry.rule.options,
                                     range: NSRange(location: searchStart, length: ns.length - searchStart))
                guard range.location != NSNotFound, range.length > 0 else { break }
                searchStart = NSMaxRange(range)
                guard !entry.leadingBoundary || isBoundary(before: range.location, in: ns),
                      !entry.trailingBoundary || isBoundary(after: NSMaxRange(range), in: ns),
                      entry.rule != .lowercaseUnlessSentenceStart || isLowercaseOrSentenceStart(range, in: ns),
                      !taken.intersects(integersIn: range.location..<NSMaxRange(range)) else { continue }
                taken.insert(integersIn: range.location..<NSMaxRange(range))
                if let wordID = entry.wordID { found.append(AIPromptWordMatch(wordID: wordID, range: range)) }
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The direction lines for the words matched in an instruction: for each word (once, in the
    /// order typed), the refinements the writer chose, or the word's defaults when they never
    /// opened it. The writer's word is kept, in the language they typed it ("“kürzer” means: …"):
    /// it carries intent the checklist can miss. The directions themselves stay English, which
    /// every connected model follows; the reply's language comes from the passage.
    public static func directions(for matches: [AIPromptWordMatch], in text: String,
                                  choices: [String: [String]], words: [AIPromptWord] = current) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var lines: [String] = []
        for match in matches where !seen.contains(match.wordID) {
            seen.insert(match.wordID)
            guard let word = word(match.wordID, in: words) else { continue }
            let chosen = choices[word.id] ?? word.defaults
            let directions = chosen.compactMap { label in word.refinement(label)?.direction ?? custom(label) }
            guard !directions.isEmpty else { continue }
            let typed = ns.substring(with: match.range)
            lines.append("“\(typed)” means: " + directions.joined(separator: " "))
        }
        return lines
    }

    /// The text a typed instruction is sent as: the instruction, the directions for its curated
    /// words, and the fixed keep-constraint.
    public static func instruction(_ typed: String, choices: [String: [String]],
                                   words: [AIPromptWord] = current) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = directions(for: matches(in: trimmed, words: words), in: trimmed, choices: choices, words: words)
        var parts = [trimmed]
        if !lines.isEmpty { parts.append("Directions:\n" + lines.map { "- " + $0 }.joined(separator: "\n")) }
        parts.append(keepConstraint)
        return parts.joined(separator: "\n\n")
    }

    /// A refinement that is not on the list never reaches the model as a direction.
    private static func custom(_ label: String) -> String? { nil }

    // MARK: Building the words

    /// `code`'s catalog lookup: English is the key; another language reads its `.lproj` (zh → zh-Hans);
    /// a language the catalog lacks falls back to English.
    static func localizer(forLanguage code: String) -> (String) -> String {
        let parts = code.split(separator: "-").map(String.init)
        let base = parts.first?.lowercased() ?? code.lowercased()
        guard base != "en" else { return { $0 } }
        let candidates = base == "zh" ? ["zh-Hans"] : [code, base]
        for candidate in candidates {
            if let path = Bundle.module.path(forResource: candidate, ofType: "lproj"), let bundle = Bundle(path: path) {
                return { String(localized: String.LocalizationValue($0), bundle: bundle) }
            }
        }
        return { $0 }
    }

    private static func words(localizing localize: (String) -> String) -> [AIPromptWord] {
        definitions.map { definition in
            let refinements = definition.refinements.map {
                AIPromptWord.Refinement(key: $0.label, label: localize($0.label), direction: $0.direction)
            }
            return AIPromptWord(id: definition.id, group: definition.group, question: localize(definition.question),
                                refinements: refinements, defaults: definition.defaults.map { refinements[$0].label },
                                taggedForms: mergedForms[definition.id] ?? [])
        }
    }

    /// Each word's forms in every language, English first, each text once (a form shared by two
    /// languages, "formal", keeps the first language's rule).
    static let mergedForms: [String: [AIPromptForm]] = {
        var merged: [String: [AIPromptForm]] = [:]
        let tables: [(AIPromptForm.Rule, [String: [String]])] =
            [(.folded, definitions.reduce(into: [:]) { $0[$1.id] = $1.forms })] + formTables.map { ($0.rule, $0.forms) }
        for (rule, table) in tables {
            for (id, forms) in table {
                for text in forms where !(merged[id] ?? []).contains(where: { $0.text == text }) {
                    let formRule = rule == .folded && lowercaseUnlessSentenceStart.contains(text)
                        ? .lowercaseUnlessSentenceStart : rule
                    merged[id, default: []].append(AIPromptForm(text: text, rule: formRule))
                }
            }
        }
        return merged
    }()

    // MARK: Boundaries

    /// Hiragana, katakana (and half-width), the CJK ideographs and their iteration marks.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005...0x3007, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    /// A letter or digit that would make a Latin-script form part of a longer word. A Japanese or
    /// Chinese neighbour does not ("もっとAIっぽくない", "更professional").
    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true } // a surrogate: part of a letter
        return CharacterSet.alphanumerics.contains(scalar) && !isCJK(scalar)
    }

    private static func isBoundary(before index: Int, in text: NSString) -> Bool {
        index == 0 || !isWordCharacter(text.character(at: index - 1))
    }

    private static func isBoundary(after index: Int, in text: NSString) -> Bool {
        index >= text.length || !isWordCharacter(text.character(at: index))
    }

    /// Lower case, or capitalized where a sentence starts (only spaces back to the start of the
    /// text or to . ! ? or a line break).
    private static func isLowercaseOrSentenceStart(_ range: NSRange, in text: NSString) -> Bool {
        guard let first = Unicode.Scalar(text.character(at: range.location)),
              first.properties.isUppercase else { return true }
        var index = range.location - 1
        while index >= 0 {
            let unit = text.character(at: index)
            guard let scalar = Unicode.Scalar(unit) else { return false }
            if CharacterSet.whitespaces.contains(scalar) { index -= 1; continue }
            return ".!?\n\r".unicodeScalars.contains(scalar)
        }
        return true
    }
}


// MARK: - The words

extension AIPromptLexicon {
    struct Definition: Sendable {
        struct RefinementDefinition: Sendable {
            let label: String
            let direction: String
        }
        let id: String
        let group: AIPromptWord.Group
        let forms: [String]
        let question: String
        let refinements: [RefinementDefinition]
        let defaults: [Int]
    }

    private static func define(_ id: String, _ group: AIPromptWord.Group, _ forms: [String], _ question: String,
                               _ refinements: [(String, String)], defaults: [Int]) -> Definition {
        Definition(id: id, group: group, forms: forms, question: question,
                   refinements: refinements.map { Definition.RefinementDefinition(label: $0.0, direction: $0.1) },
                   defaults: defaults)
    }

    /// 33 words in six groups, with their English forms. Directions are plain English instructions
    /// to the model (never shown); labels and questions are the catalog keys of what the writer sees
    /// (`Localizable.xcstrings`, six languages).
    static let definitions: [Definition] = [
        // MARK: Tone
        define("professional", .tone,
             ["professional", "professionally", "more professional", "businesslike", "less casual", "polished"],
             "Professional how?", [
                ("no slang or emoji", "Replace slang and idioms with standard wording, and remove emoji."),
                ("fewer jokes", "Remove jokes and playful asides."),
                ("no exclamation marks", "Use no exclamation marks."),
                ("fewer adjectives", "Cut decorative adjectives and adverbs; keep only ones that carry meaning."),
                ("shorter sentences", "Shorten long sentences."),
                ("keep it warm", "Keep a warm, human tone; do not become cold or bureaucratic."),
             ], defaults: [0, 2]),
        define("formal", .tone,
             ["formal", "formally", "more formal", "formalize", "formalise", "less informal"],
             "Formal how?", [
                ("no contractions", "Expand contractions (don't becomes do not)."),
                ("standard punctuation", "Use standard capitalization and punctuation; no repeated punctuation."),
                ("no fillers", "Remove fillers such as like, basically and so yeah."),
                ("complete sentences", "Use complete sentences; no fragments."),
                ("no slang", "Replace slang with standard words."),
             ], defaults: [0, 3]),
        define("casual", .tone,
             ["casual", "casually", "more casual", "informal", "relaxed", "less formal", "laid-back", "chatty", "conversational"],
             "Casual how?", [
                ("use contractions", "Use contractions (it's, we'll)."),
                ("shorter sentences", "Use shorter sentences; a fragment now and then is fine."),
                ("everyday words", "Use everyday words instead of formal ones (use, not utilize)."),
                ("speak to “you”", "Address the reader directly as “you”."),
                ("a touch of humour", "Allow at most one light touch of humour."),
             ], defaults: [0, 2]),
        define("friendly", .tone,
             ["friendly", "friendlier", "more friendly", "warm", "warmer", "warmly", "nicer", "kinder", "approachable"],
             "Friendlier how?", [
                ("add a thank-you", "Add one short greeting or thank-you where it fits naturally."),
                ("use “you” and “we”", "Use “you” and “we”."),
                ("use contractions", "Use contractions."),
                ("softer requests", "Phrase requests as invitations (could you…, would it help to…)."),
                ("acknowledge the reader", "Acknowledge the reader's situation in one line."),
                ("no new promises", "Do not add new claims or promises."),
             ], defaults: [2, 3]),
        define("polite", .tone,
             ["polite", "politer", "more polite", "politely", "courteous", "respectful"],
             "Polite how?", [
                ("requests, not commands", "Turn commands into requests (could you…)."),
                ("add thanks", "Add a brief thank-you."),
                ("please mid-sentence", "If you use please, put it mid-sentence, not at the start."),
                ("drop “actually”", "Remove “in fact” and “actually”."),
                ("keep the request", "Keep the request itself unchanged."),
             ], defaults: [0, 4]),
        define("softer", .tone,
             ["softer", "soften", "gentler", "gentle", "less harsh", "less blunt", "less aggressive", "milder"],
             "Softer how?", [
                ("add light hedges", "Add light hedges such as I think or perhaps."),
                ("“I” statements", "Turn statements of fault into “I” statements (I couldn't find… rather than You forgot…)."),
                ("suggest, don't demand", "Turn demands into questions or suggestions."),
                ("no absolutes", "Remove absolute words such as always, never and obviously."),
                ("keep the deadline", "Keep the core message and any deadline intact."),
             ], defaults: [2, 4]),
        define("diplomatic", .tone,
             ["diplomatic", "more diplomatic", "diplomatically", "tactful", "more tactful", "tactfully"],
             "Diplomatic how?", [
                ("lead with what works", "Lead with what is agreed or what works."),
                ("criticism as suggestion", "Frame criticism as a suggestion."),
                ("no blame words", "Remove blame words such as failed, wrong and mistake."),
                ("hedge disagreement", "Hedge disagreements gently."),
                ("keep the facts", "Keep facts and decisions unchanged."),
             ], defaults: [1, 4]),
        define("direct", .tone,
             ["direct", "more direct", "directly", "straightforward", "to the point", "get to the point", "blunter"],
             "Direct how?", [
                ("point first", "Put the main point or request in the first sentence."),
                ("no hedges", "Remove hedges such as I think, maybe and just."),
                ("no preamble", "Remove apologies and preambles."),
                ("a clear ask", "End with a clear ask."),
                ("shorter sentences", "Use shorter sentences."),
                ("stay polite", "Stay polite; no blame."),
             ], defaults: [0, 5]),
        define("confident", .tone,
             ["confident", "more confident", "confidently", "assertive", "more assertive", "less hedgy", "less unsure", "surer"],
             "Confident how?", [
                ("no hedges", "Remove hedges and qualifiers such as I think, sort of and might."),
                ("no needless apologies", "Remove unnecessary apologies."),
                ("active voice", "Use the active voice."),
                ("“will”, not “try to”", "Use will instead of would like to try to."),
                ("statements, not questions", "Prefer statements to questions."),
                ("don't overstate", "Do not overstate any fact."),
             ], defaults: [0, 5]),
        define("natural", .tone,
             ["natural", "more natural", "naturally", "less stiff", "stiff", "robotic", "less robotic", "wooden", "more human"],
             "More natural how?", [
                ("use contractions", "Use contractions."),
                ("everyday words", "Replace formal words with everyday ones."),
                ("vary sentence length", "Vary sentence length."),
                ("verbs, not nouns", "Turn nominalizations into verbs (make a decision becomes decide)."),
                ("no stock phrases", "Remove stock phrases such as I hope this email finds you well."),
                ("same politeness", "Keep the same level of politeness."),
             ], defaults: [1, 3]),
        define("neutral", .tone,
             ["neutral", "more neutral", "neutrally", "objective", "more objective", "unbiased", "less biased", "impartial"],
             "Neutral how?", [
                ("no loaded words", "Remove opinion words and loaded adjectives."),
                ("no intensifiers", "Remove intensifiers such as very, extremely and incredibly."),
                ("no exclamation marks", "Use no exclamation marks."),
                ("attribute claims", "Attribute claims (according to…) rather than asserting them."),
                ("both sides", "If the text argues one side, present both sides evenly."),
             ], defaults: [0, 1]),

        // MARK: Length
        define("shorter", .length,
             ["shorter", "shorten", "short", "trim", "trimmed", "condense", "condensed", "less long", "briefer"],
             "Shorter how?", [
                ("about a third shorter", "Make it about a third shorter."),
                ("about half", "Make it about half as long."),
                ("no repeated points", "Remove repeated points."),
                ("no intro or sign-off", "Remove intros and sign-off padding."),
                ("drop examples", "Drop examples, keeping the main point."),
                ("keep every fact", "Keep every key fact, number, date and name."),
             ], defaults: [0, 5]),
        define("concise", .length,
             ["concise", "more concise", "concisely", "succinct", "brief", "tighter", "tighten", "tight", "less verbose", "less wordy"],
             "Concise how?", [
                ("no filler words", "Remove filler words such as really, just, actually and basically."),
                ("fewer adverbs", "Remove adverbs where the verb is enough."),
                ("no wordy phrases", "Replace wordy phrases (in order to becomes to)."),
                ("unhide verbs", "Unhide verbs (conduct an analysis becomes analyze)."),
                ("active voice", "Use the active voice."),
                ("cut words, not ideas", "Keep all content: cut words, not ideas."),
             ], defaults: [0, 5]),
        define("longer", .length,
             ["longer", "lengthen", "expand", "expanded", "elaborate", "flesh out", "more detail", "more detailed", "more depth"],
             "Longer how?", [
                ("an example per point", "Add one example per main point, drawn from the text."),
                ("explain the reasons", "Explain the reasons (because…)."),
                ("add transitions", "Add transitions between ideas."),
                ("spell out shorthand", "Expand abbreviations and shorthand."),
                ("no new facts", "Add no facts the text does not already give."),
                ("about a third longer", "Make it about a third longer."),
             ], defaults: [1, 4]),

        // MARK: Clarity
        define("clearer", .clarity,
             ["clear", "clearer", "more clear", "clarify", "clarity", "readable", "more readable", "easier to follow", "less confusing"],
             "Clearer how?", [
                ("one idea per sentence", "One idea per sentence."),
                ("under 20 words", "Keep sentences under about 20 words."),
                ("say who does what", "Use the active voice and name who does what."),
                ("define jargon", "Define or replace jargon."),
                ("main point first", "Put the main point first."),
                ("keep it accurate", "Keep the meaning and technical accuracy."),
             ], defaults: [0, 5]),
        define("simpler", .clarity,
             ["simple", "simpler", "simplify", "simplified", "plain", "plainer", "plain english", "easier to read", "easier"],
             "Simpler how?", [
                ("everyday words", "Use everyday words instead of long ones."),
                ("short sentences", "Use short sentences."),
                ("explain acronyms", "Explain or remove jargon and acronyms."),
                ("present tense", "Use the present tense where possible."),
                ("speak to “you”", "Address the reader as “you”."),
                ("keep every fact", "Keep every fact."),
             ], defaults: [0, 5]),
        define("jargon", .clarity,
             ["jargon", "less jargon", "jargony", "less jargony", "less technical", "fewer buzzwords", "buzzwords"],
             "Less jargon how?", [
                ("plain words", "Replace technical terms with plain words."),
                ("spell out acronyms", "Spell out acronyms on first use."),
                ("explain kept terms", "Add a short explanation where a term must stay."),
                ("no buzzwords", "Remove buzzwords such as leverage and synergy."),
                ("keep needed terms", "Keep the terms the reader must know."),
             ], defaults: [0, 3]),
        define("flow", .clarity,
             ["flow", "flows", "flows better", "better flow", "smooth", "smoother", "smooth this out", "more coherent", "reads better"],
             "What makes it flow?", [
                ("better transitions", "Add or improve transitions between sentences."),
                ("vary sentence length", "Vary sentence length and openings."),
                ("fix awkward phrasing", "Rewrite awkward or clunky phrasing."),
                ("clear pronouns", "Fix pronouns that do not clearly refer to anything."),
                ("no new content", "Add no new ideas."),
             ], defaults: [0, 4]),
        define("specific", .clarity,
             ["specific", "more specific", "precise", "more precise", "less vague", "vague", "concrete", "more concrete"],
             "Specific how?", [
                ("replace vague words", "Replace vague words such as things, stuff and soon with specifics."),
                ("use the text's numbers", "Use numbers, dates and names already in the text."),
                ("mark missing details", "Mark missing details with a placeholder such as [date] rather than inventing them."),
                ("a concrete example", "Replace a general claim with a concrete example from the text."),
                ("no filler qualifiers", "Remove filler qualifiers."),
             ], defaults: [0, 2]),
        define("structured", .clarity,
             ["structured", "more structured", "organized", "organised", "better organized", "better organised", "logical"],
             "Structured how?", [
                ("one topic per paragraph", "Reorder so each paragraph has one topic."),
                ("logical order", "Put the points in a logical order."),
                ("topic sentence first", "Open each paragraph with its topic sentence."),
                ("signpost the steps", "Signpost steps with words such as first, then and finally."),
                ("no new content", "Add no new ideas."),
             ], defaults: [1, 4]),

        // MARK: Energy
        define("punchier", .energy,
             ["punchy", "punchier", "snappy", "snappier", "more impact", "more impactful", "stronger", "bolder", "crisper", "crisp"],
             "Punchier how?", [
                ("shorter sentences", "Use shorter sentences; fragments are allowed."),
                ("strong verbs", "Use strong verbs instead of adverb plus verb."),
                ("cut the warm-up", "Cut the first sentence if it is a warm-up."),
                ("end strong", "End on the strongest line."),
                ("no hedges", "Remove hedges."),
                ("no hype words", "Add no hype words or exclamation marks."),
             ], defaults: [0, 4]),
        define("engaging", .energy,
             ["engaging", "more engaging", "interesting", "more interesting", "compelling", "more compelling", "less boring", "boring"],
             "Engaging how?", [
                ("a strong opening", "Open with a question, a surprising fact or a concrete example from the text."),
                ("speak to “you”", "Speak to the reader as “you”."),
                ("vary sentence length", "Vary sentence length."),
                ("concrete images", "Use concrete images instead of abstractions."),
                ("keep the facts", "Keep claims and facts unchanged."),
             ], defaults: [2, 4]),
        define("enthusiastic", .energy,
             ["enthusiastic", "more enthusiastic", "excited", "more excited", "upbeat", "more upbeat", "energetic", "livelier", "lively"],
             "Enthusiastic how?", [
                ("upbeat words", "Use upbeat word choice."),
                ("one exclamation mark", "Allow at most one exclamation mark."),
                ("lead with the positive", "Lead with the positive."),
                ("emoji allowed", "One fitting emoji is allowed."),
                ("don't exaggerate", "Do not exaggerate facts."),
             ], defaults: [0, 4]),
        define("persuasive", .energy,
             ["persuasive", "more persuasive", "persuasively", "convincing", "more convincing", "salesy"],
             "Persuasive how?", [
                ("benefit first", "Lead with the benefit to the reader."),
                ("a call to action", "End with a clear call to action."),
                ("back the claims", "Back claims with reasons or evidence from the text."),
                ("answer the objection", "Answer the likely objection."),
                ("no hedges", "Remove hedges."),
                ("no invented claims", "Invent no statistics or claims."),
             ], defaults: [0, 5]),
        define("creative", .energy,
             ["creative", "more creative", "imaginative", "more imaginative", "vivid", "more vivid", "colorful", "colourful", "descriptive"],
             "Creative how?", [
                ("sensory detail", "Use concrete sensory detail."),
                ("one comparison", "Allow one metaphor or comparison."),
                ("replace clichés", "Replace clichés."),
                ("vary the rhythm", "Vary rhythm and sentence openings."),
                ("keep the facts", "Keep the events and facts the same."),
             ], defaults: [2, 4]),
        define("playful", .energy,
             ["playful", "more playful", "fun", "more fun", "funnier", "humorous", "witty", "wittier", "lighter", "light-hearted", "lighthearted"],
             "Playful how?", [
                ("one light joke", "Add light humour: one joke at most."),
                ("casual words", "Use contractions and casual words."),
                ("wordplay allowed", "Wordplay is allowed."),
                ("emoji allowed", "One fitting emoji is allowed."),
                ("keep the information", "Keep the information complete."),
             ], defaults: [1, 4]),

        // MARK: Polish
        define("better", .polish,
             ["better", "improve", "improved", "polish", "refine", "refined", "make it better", "nicer wording"],
             "Better how?", [
                ("grammar and spelling only", "Fix grammar and spelling only."),
                ("better word choice", "Also improve word choice."),
                ("tighter", "Also tighten the wording."),
                ("smoother flow", "Also smooth the flow."),
                ("keep my voice", "Keep the writer's voice: do not change the tone."),
                ("same length", "Keep the length within about ten percent."),
             ], defaults: [1, 4]),
        define("cleaner", .polish,
             ["clean", "cleaner", "clean up", "clean it up", "tidy", "tidier", "tidy up", "neater"],
             "Cleaner how?", [
                ("fix grammar", "Fix grammar, spelling and punctuation."),
                ("consistent style", "Make capitalization and spacing consistent."),
                ("no repetition", "Remove repeated words and phrases."),
                ("no filler words", "Remove filler words."),
                ("keep the wording", "Otherwise keep the wording as it is."),
             ], defaults: [0, 4]),
        define("academic", .polish,
             ["academic", "more academic", "scholarly", "more scholarly", "scientific", "for a paper"],
             "Academic how?", [
                ("no contractions", "Use no contractions."),
                ("careful claims", "Hedge claims appropriately (suggests, may)."),
                ("precise terms", "Prefer precise terms to everyday ones."),
                ("third person", "Write in the third person; no “you”."),
                ("no exclamations", "No rhetorical questions or exclamation marks."),
                ("keep the data", "Keep citations and data unchanged."),
             ], defaults: [2, 5]),
        define("humanize", .polish,
             ["humanize", "humanise", "less ai", "less ai-sounding", "less like ai", "sound human", "sounds human"],
             "More human how?", [
                ("no stock AI phrases", "Remove stock AI phrases such as delve, in today's fast-paced world and it's worth noting."),
                ("no dash chains", "Remove chains of dashes and lists of three."),
                ("vary sentence length", "Vary sentence length."),
                ("use contractions", "Use contractions."),
                ("no summary ending", "Remove a closing summary sentence."),
                ("keep the meaning", "Keep the meaning."),
             ], defaults: [0, 5]),

        // MARK: Audience
        define("beginners", .audience,
             ["beginners", "for beginners", "non-experts", "non-technical", "laypeople", "a general audience", "newcomers"],
             "Beginners how?", [
                ("explain every term", "Explain every technical term in plain words."),
                ("one step at a time", "Take one step at a time."),
                ("an everyday example", "Add one everyday example."),
                ("no assumed knowledge", "Assume no prior knowledge."),
                ("keep it accurate", "Keep it accurate; simplify without dumbing down."),
             ], defaults: [0, 4]),
        define("experts", .audience,
             ["experts", "for experts", "expert", "more technical", "for engineers", "specialists"],
             "Experts how?", [
                ("precise terms", "Use precise technical terms."),
                ("skip the basics", "Skip explanations of the basics."),
                ("denser", "Make it denser: fewer words per idea."),
                ("numbers first", "Lead with numbers and specifics already in the text."),
                ("keep it accurate", "Keep it accurate; add no new claims."),
             ], defaults: [0, 4]),
        define("executives", .audience,
             ["executives", "leadership", "leadership team", "my boss", "management", "for my manager", "my manager", "stakeholders"],
             "What should they see first?", [
                ("summary first", "Open with a one-line summary."),
                ("the decision needed", "Make the decision being asked for explicit."),
                ("cost and timing", "Surface cost and timing that the text gives."),
                ("risks", "Name the main risk the text mentions."),
                ("shorter", "Make it shorter."),
             ], defaults: [0, 1]),
    ]
}

// MARK: - The other languages' forms

extension AIPromptLexicon {
    struct FormTable: Sendable {
        let language: String
        let rule: AIPromptForm.Rule
        /// Word id → the forms writers type in this language, lower case.
        let forms: [String: [String]]
    }

    /// English forms that are also German nouns (Brief, Kinder): see `.lowercaseUnlessSentenceStart`.
    static let lowercaseUnlessSentenceStart: Set<String> = ["brief", "kinder"]

    /// Longer Japanese and Chinese words that contain a form but mean something else. Each claims
    /// its span and reports nothing ("流れ星" is a shooting star, not "flow"; "正式版" a release,
    /// "扩展名" a file extension; "得体の知れない" is "mysterious" in Japanese).
    static let blockers: [String] = ["流れ星", "得体の知れ", "正式版", "正式发布", "正式上线", "扩展名"]

    /// Forms per language, chosen for how writers phrase a request in it, not translated word for
    /// word. Every form was checked against English (and the other languages): a form that is also
    /// an everyday word elsewhere is left out or kept only inside a phrase (French "court" is a law
    /// court, so only "plus court"; "structuré" would fold to English "structure", so only "plus
    /// structuré"; German "natürlich" means "of course", so only "natürlicher"; Spanish "claro" is
    /// "of course", so only "más claro"). Japanese and Chinese prefer multi-character forms.
    static let formTables: [FormTable] = [
        FormTable(language: "de", rule: .umlautSensitive, forms: [
            "professional": ["professionell", "professioneller", "seriös", "seriöser", "geschäftsmäßig",
                             "geschäftsmäßiger", "weniger salopp"],
            "formal": ["formell", "formeller", "förmlich", "förmlicher", "siezen", "sie-form", "in der sie-form"],
            "casual": ["lockerer", "ungezwungen", "ungezwungener", "umgangssprachlich", "umgangssprachlicher",
                       "informell", "informeller", "lässig", "lässiger", "weniger förmlich", "weniger formell",
                       "duzen", "du-form", "in der du-form"],
            "friendly": ["freundlich", "freundlicher", "herzlich", "herzlicher", "wärmer", "netter", "nahbar",
                         "nahbarer", "sympathisch", "sympathischer"],
            "polite": ["höflich", "höflicher", "respektvoll", "respektvoller", "zuvorkommend", "zuvorkommender"],
            "softer": ["sanfter", "weicher", "milder", "abmildern", "abschwächen", "entschärfen", "weniger hart",
                       "weniger schroff", "weniger aggressiv", "behutsamer"],
            "diplomatic": ["diplomatisch", "diplomatischer", "taktvoll", "taktvoller", "feinfühlig", "feinfühliger"],
            "direct": ["direkter", "geradliniger", "auf den punkt", "ohne umschweife", "unverblümt", "unverblümter"],
            "confident": ["selbstbewusst", "selbstbewusster", "selbstsicher", "selbstsicherer", "entschiedener",
                          "souveräner", "weniger zögerlich"],
            "natural": ["natürlicher", "weniger steif", "weniger hölzern", "weniger roboterhaft", "menschlicher"],
            "neutral": ["neutraler", "sachlich", "sachlicher", "objektiv", "objektiver", "unvoreingenommen",
                        "ausgewogen", "ausgewogener"],
            "shorter": ["kürzer", "kürzen", "kürze", "verkürzen", "verkürze", "gekürzt", "weniger lang", "eindampfen"],
            "concise": ["prägnant", "prägnanter", "knapper", "straffen", "straffer", "kompakter", "bündig",
                        "bündiger", "weniger wortreich", "weniger geschwätzig"],
            "longer": ["länger", "verlängern", "verlängere", "ausführlich", "ausführlicher", "ausbauen", "erweitern",
                       "erweitere", "detaillierter", "mehr details", "vertiefen"],
            "clearer": ["klarer", "deutlicher", "verständlich", "verständlicher", "lesbarer", "eindeutiger",
                        "verdeutlichen", "verdeutliche", "leichter zu folgen"],
            "simpler": ["einfacher", "vereinfachen", "vereinfache", "vereinfacht", "schlichter", "einfache sprache",
                        "leichte sprache", "in einfachen worten"],
            "jargon": ["fachjargon", "weniger jargon", "weniger fachjargon", "fachsprache", "weniger fachsprache",
                       "fachbegriffe", "weniger fachbegriffe", "weniger technisch", "weniger buzzwords", "schlagwörter"],
            "flow": ["flüssig", "flüssiger", "fließender", "runder", "abrunden", "glätten", "geschmeidiger",
                     "kohärenter", "zusammenhängender", "lesefluss"],
            "specific": ["konkreter", "genauer", "präziser", "präzise", "spezifischer", "weniger vage",
                         "weniger schwammig", "weniger allgemein"],
            "structured": ["strukturiert", "strukturierter", "gegliedert", "besser gegliedert", "geordneter",
                           "übersichtlicher", "logischer", "besser organisiert"],
            "punchier": ["knackig", "knackiger", "schlagkräftiger", "wirkungsvoller", "eindringlicher", "pointierter",
                         "zackiger", "mit mehr biss", "mehr wumms"],
            "engaging": ["fesselnd", "fesselnder", "packend", "packender", "spannend", "spannender", "interessanter",
                         "ansprechender", "weniger langweilig", "langweilig"],
            "enthusiastic": ["begeistert", "begeisterter", "enthusiastisch", "enthusiastischer", "schwungvoll",
                             "schwungvoller", "lebhafter", "lebendiger", "motivierter", "optimistischer", "positiver"],
            "persuasive": ["überzeugend", "überzeugender", "verkaufsstärker", "werblicher", "mitreißender"],
            "creative": ["kreativ", "kreativer", "fantasievoll", "fantasievoller", "phantasievoller", "bildhaft",
                         "bildhafter", "anschaulich", "anschaulicher", "origineller"],
            "playful": ["verspielt", "verspielter", "lustig", "lustiger", "witzig", "witziger", "humorvoll",
                        "humorvoller", "unterhaltsam", "unterhaltsamer", "mit humor", "augenzwinkernd"],
            "better": ["besser", "verbessern", "verbessere", "verbessert", "überarbeiten", "überarbeite",
                       "aufpolieren", "polieren", "optimieren", "optimiere", "schöner", "schöner formulieren"],
            "cleaner": ["sauber", "sauberer", "säubern", "aufräumen", "aufgeräumter", "ordentlicher", "bereinigen",
                        "bereinige"],
            "academic": ["akademisch", "akademischer", "wissenschaftlich", "wissenschaftlicher", "für eine arbeit",
                         "für eine hausarbeit", "für ein paper"],
            "humanize": ["humanisieren", "menschlich klingen", "menschlicher klingen", "weniger nach ki",
                         "nicht nach ki", "weniger ki", "wie ein mensch"],
            "beginners": ["anfänger", "für anfänger", "einsteiger", "für einsteiger", "laien", "für laien",
                          "ohne vorwissen", "allgemeinverständlich", "für alle verständlich"],
            "experts": ["experten", "für experten", "fachleute", "für fachleute", "fachpublikum", "spezialisten",
                        "technischer", "für ingenieure"],
            "executives": ["führungskräfte", "für führungskräfte", "geschäftsführung", "vorstand", "meinen chef",
                           "meine chefin", "für meinen chef", "vorgesetzte", "vorgesetzten", "entscheider", "stakeholder"],
        ]),
        FormTable(language: "fr", rule: .folded, forms: [
            "professional": ["professionnel", "professionnelle", "plus professionnel", "plus professionnelle",
                             "professionnellement", "moins familier"],
            "formal": ["formel", "formelle", "plus formel", "plus formelle", "soutenu", "plus soutenu", "vouvoyer",
                       "vouvoiement"],
            "casual": ["décontracté", "plus décontracté", "détendu", "plus détendu", "plus familier", "informel",
                       "plus informel", "moins formel", "moins formelle", "tutoyer", "tutoiement", "conversationnel"],
            "friendly": ["amical", "plus amical", "chaleureux", "plus chaleureux", "chaleureuse", "aimable",
                         "plus aimable", "sympathique", "sympa", "plus sympa", "cordial", "plus cordial"],
            "polite": ["plus poli", "plus polie", "poliment", "courtois", "plus courtois", "respectueux",
                       "plus respectueux"],
            "softer": ["plus doux", "plus douce", "adoucir", "adoucis", "adoucissez", "atténuer", "moins dur",
                       "moins brutal", "moins sec", "moins agressif", "plus délicat"],
            "diplomatic": ["diplomate", "plus diplomate", "diplomatique", "avec tact", "avec plus de tact"],
            "direct": ["plus direct", "plus directe", "droit au but", "sans détour", "sans détours", "plus franc"],
            "confident": ["confiant", "plus confiant", "plus assuré", "affirmé", "plus affirmé", "assertif",
                          "plus assertif", "moins hésitant", "avec assurance"],
            "natural": ["naturel", "plus naturel", "naturelle", "plus naturelle", "moins rigide", "moins guindé",
                        "moins robotique", "plus humain"],
            "neutral": ["neutre", "plus neutre", "objectif", "plus objectif", "impartiale", "factuel", "plus factuel"],
            "shorter": ["plus court", "plus courte", "raccourcir", "raccourcis-le", "raccourcissez", "écourter",
                        "réduire", "réduis", "moins long", "moins longue", "condenser"],
            "concise": ["concis", "plus concis", "plus concise", "plus succinct", "plus bref", "plus brève",
                        "resserrer", "resserre", "moins verbeux", "moins bavard"],
            "longer": ["plus long", "plus longue", "allonger", "allonge", "rallonger", "développer", "développe",
                       "développez", "étoffer", "plus détaillé", "plus détaillée", "plus de détails", "approfondir"],
            "clearer": ["clair", "plus clair", "plus claire", "clarifier", "clarifie", "clarifiez", "lisible",
                        "plus lisible", "compréhensible", "plus compréhensible", "moins confus", "plus limpide"],
            "simpler": ["plus simple", "simplifier", "simplifie", "simplifiez", "en termes simples",
                        "plus facile à lire", "langage simple"],
            "jargon": ["moins de jargon", "jargonneux", "moins technique", "termes techniques",
                       "moins de termes techniques", "mots à la mode"],
            "flow": ["fluide", "plus fluide", "fluidité", "fluidifier", "mieux enchaîné", "enchaînements",
                     "plus cohérent", "cohérent", "se lit mieux", "plus coulant"],
            "specific": ["précis", "plus précis", "plus précise", "spécifique", "plus spécifique", "concret",
                         "plus concret", "concrète", "plus concrète", "moins vague", "moins flou"],
            "structured": ["plus structuré", "mieux structuré", "bien structuré", "structurer", "restructurer",
                           "mieux organisé", "plus organisé", "plus logique"],
            "punchier": ["percutant", "plus percutant", "percutante", "plus percutante", "plus d’impact",
                         "plus d'impact", "incisif", "plus incisif", "plus mordant", "plus punchy"],
            "engaging": ["captivant", "plus captivant", "engageant", "plus engageant", "intéressant",
                         "plus intéressant", "accrocheur", "plus accrocheur", "moins ennuyeux", "ennuyeux"],
            "enthusiastic": ["enthousiaste", "plus enthousiaste", "plus dynamique", "énergique", "plus énergique",
                             "entraînant", "plus vivant", "plus positif"],
            "persuasive": ["persuasif", "plus persuasif", "convaincant", "plus convaincant", "convaincante",
                           "vendeur", "plus vendeur"],
            "creative": ["créatif", "plus créatif", "créative", "imaginatif", "plus imaginatif", "plus imagé",
                         "coloré", "plus coloré", "plus descriptif", "évocateur", "plus évocateur", "plus original"],
            "playful": ["ludique", "plus ludique", "drôle", "plus drôle", "amusant", "plus amusant", "humoristique",
                        "avec humour", "plein d’humour", "plein d'humour", "espiègle", "plus léger", "plus légère",
                        "plus fun"],
            "better": ["mieux", "en mieux", "améliorer", "améliore", "améliorez", "peaufiner", "peaufine", "polir",
                       "retravailler", "retravaille"],
            "cleaner": ["plus propre", "nettoyer", "nettoie", "nettoyez", "mettre au propre", "mets au propre",
                        "épurer", "épure", "plus net", "plus nette", "plus soigné"],
            "academic": ["académique", "plus académique", "universitaire", "scientifique", "plus scientifique",
                         "style académique", "pour un article", "pour un mémoire"],
            "humanize": ["humaniser", "moins ia", "moins artificiel", "comme un humain", "pas comme une ia",
                         "moins comme une ia", "sonner humain"],
            "beginners": ["débutants", "pour débutants", "pour les débutants", "novices", "néophytes",
                          "non-spécialistes", "grand public", "pour le grand public", "non-initiés"],
            "experts": ["pour experts", "pour des experts", "spécialistes", "plus technique", "pour ingénieurs",
                        "pour des ingénieurs", "public averti"],
            "executives": ["dirigeants", "pour la direction", "à la direction", "cadres", "mon patron",
                           "ma patronne", "mon chef", "ma cheffe", "mon manager", "comité de direction", "décideurs",
                           "parties prenantes"],
        ]),
        FormTable(language: "es", rule: .folded, forms: [
            "professional": ["profesional", "más profesional", "profesionalmente", "más serio", "más seria",
                             "menos coloquial"],
            "formal": ["más formal", "formalmente", "de usted", "tratar de usted"],
            "casual": ["más informal", "más casual", "relajado", "más relajado", "desenfadado", "más desenfadado",
                       "coloquial", "más coloquial", "menos formal", "tutear", "tutea"],
            "friendly": ["amable", "más amable", "amigable", "más amigable", "cálido", "más cálido", "cercano",
                         "más cercano", "más cordial", "simpático", "más simpático"],
            "polite": ["más cortés", "cortésmente", "educado", "más educado", "respetuoso", "más respetuoso",
                       "con cortesía"],
            "softer": ["más suave", "suavizar", "suaviza", "suavízalo", "suavízala", "menos duro", "menos brusco",
                       "menos agresivo", "más delicado"],
            "diplomatic": ["diplomático", "más diplomático", "diplomática", "con tacto", "con más tacto"],
            "direct": ["directo", "más directo", "directa", "al grano", "ir al grano", "ve al grano", "sin rodeos",
                       "más franco"],
            "confident": ["más seguro", "más segura", "con seguridad", "con más seguridad", "con confianza",
                          "más confiado", "más firme", "asertivo", "más asertivo", "seguro de sí", "menos dubitativo"],
            "natural": ["más natural", "con naturalidad", "menos rígido", "menos robótico", "menos acartonado",
                        "más humano"],
            "neutral": ["más neutral", "neutro", "más neutro", "más objetivo", "imparcial", "más imparcial",
                        "sin sesgo", "menos sesgado"],
            "shorter": ["más corto", "más corta", "acortar", "acorta", "acórtalo", "acórtala", "recortar", "recorta",
                        "recórtalo", "reducir", "redúcelo", "menos largo", "condensar", "condénsalo"],
            "concise": ["conciso", "más conciso", "concisa", "sucinto", "más sucinto", "breve", "más breve",
                        "menos verboso", "sin relleno", "sin paja"],
            "longer": ["más largo", "más larga", "alargar", "alarga", "alárgalo", "ampliar", "amplíalo",
                       "desarrollar", "desarrolla", "desarróllalo", "más detallado", "más detalle", "más detalles",
                       "profundizar", "extender"],
            "clearer": ["más claro", "más clara", "aclarar", "aclara", "acláralo", "clarificar", "legible",
                        "más legible", "comprensible", "más comprensible", "entendible", "más entendible",
                        "menos confuso"],
            "simpler": ["más simple", "sencillo", "más sencillo", "simplificar", "simplifica", "simplifícalo",
                        "más fácil", "fácil de leer", "lenguaje sencillo", "en palabras sencillas"],
            "jargon": ["jerga", "menos jerga", "tecnicismos", "menos tecnicismos", "menos técnico",
                       "términos técnicos", "palabras de moda"],
            "flow": ["fluido", "más fluido", "fluidez", "con más fluidez", "coherente", "más coherente", "que fluya",
                     "fluya mejor", "se lea mejor"],
            "specific": ["específico", "más específico", "más preciso", "más concreto", "concreto", "concreta",
                         "menos vago", "menos ambiguo"],
            "structured": ["estructurado", "más estructurado", "mejor estructurado", "organizado", "más organizado",
                           "mejor organizado", "más lógico", "más ordenado"],
            "punchier": ["contundente", "más contundente", "impactante", "más impactante", "con más fuerza",
                         "con gancho", "más gancho", "incisivo", "más incisivo"],
            "engaging": ["atractivo", "más atractivo", "interesante", "más interesante", "cautivador",
                         "más cautivador", "atrapante", "ameno", "más ameno", "menos aburrido", "aburrido"],
            "enthusiastic": ["entusiasta", "más entusiasta", "entusiasmado", "animado", "más animado", "enérgico",
                             "más enérgico", "más dinámico", "vivaz", "más positivo", "con más energía"],
            "persuasive": ["persuasivo", "más persuasivo", "persuasiva", "convincente", "más convincente",
                           "más vendedor"],
            "creative": ["creativo", "más creativo", "creativa", "imaginativo", "más imaginativo", "más vívido",
                         "colorido", "más colorido", "descriptivo", "más descriptivo", "más original", "evocador"],
            "playful": ["divertido", "más divertido", "divertida", "gracioso", "más gracioso", "con humor",
                        "humorístico", "juguetón", "más juguetón", "ingenioso", "más ingenioso", "más ligero"],
            "better": ["mejor", "mejorar", "mejora", "mejóralo", "mejórala", "pulir", "púlelo", "perfeccionar",
                       "refinar", "refina", "retocar", "retoca", "mejor redactado"],
            "cleaner": ["más limpio", "limpiar", "limpia", "límpialo", "pulcro", "más pulcro", "depurar", "depura",
                        "más prolijo", "prolijo"],
            "academic": ["académico", "más académico", "académica", "científico", "más científico",
                         "estilo académico", "para un artículo", "para una tesis"],
            "humanize": ["humanizar", "humaniza", "humanízalo", "menos ia", "menos artificial", "que suene humano",
                         "que no suene a ia", "sin sonar a ia"],
            "beginners": ["principiantes", "para principiantes", "novatos", "no expertos", "público general",
                          "para todos los públicos", "no técnicos", "sin conocimientos previos"],
            "experts": ["expertos", "para expertos", "especialistas", "más técnico", "para ingenieros",
                        "público experto"],
            "executives": ["directivos", "ejecutivos", "para la dirección", "alta dirección", "mi jefe", "mi jefa",
                           "gerencia", "junta directiva", "partes interesadas"],
        ]),
        FormTable(language: "ja", rule: .cjk, forms: [
            "professional": ["プロフェッショナル", "プロらしく", "プロっぽく", "ビジネスライク", "ビジネス向け",
                             "ビジネスらしく", "仕事向け"],
            "formal": ["フォーマル", "硬めに", "堅めに", "改まった", "かしこまった", "敬語"],
            "casual": ["カジュアル", "くだけた", "砕けた", "気軽な", "軽い感じ", "タメ口", "話し言葉", "口語"],
            "friendly": ["親しみやすく", "親しみやすい", "親しみのある", "フレンドリー", "温かみ", "温かい", "温かく",
                         "あたたかい", "あたたかく"],
            "polite": ["丁寧な言い方", "丁寧な表現", "丁寧な口調", "もっと丁寧", "丁寧にして", "丁寧に書", "礼儀正しく",
                       "失礼のない"],
            "softer": ["柔らかく", "やわらかく", "柔らかい", "やわらかい", "優しく", "やさしく", "穏やか", "きつくない",
                       "とげのない", "トゲのない"],
            "diplomatic": ["角が立たない", "角を立てず", "外交的", "波風を立てない", "配慮した", "配慮のある"],
            "direct": ["単刀直入", "端的に", "ストレートに", "はっきりと", "率直に", "率直な", "結論から", "要点から"],
            "confident": ["自信を持って", "自信のある", "自信がある", "自信満々", "堂々と", "言い切る", "言い切って",
                          "断定的"],
            "natural": ["自然に", "自然な", "もっと自然", "不自然", "ナチュラル", "硬さを取って", "ロボットっぽくない",
                        "機械的でない"],
            "neutral": ["中立的", "中立", "客観的", "客観", "公平", "偏りのない", "偏りなく"],
            "shorter": ["短く", "もっと短く", "短めに", "短縮", "縮めて", "削って", "手短に", "文字数を減らして"],
            "concise": ["簡潔", "簡潔に", "もっと簡潔", "冗長", "くどくない", "くどさ", "無駄を省いて", "無駄を削って",
                        "要点だけ"],
            "longer": ["長くして", "もっと長く", "長めに", "膨らませて", "詳しく", "もっと詳しく", "詳細に", "肉付け",
                       "加筆", "補足して"],
            "clearer": ["分かりやすく", "わかりやすく", "分かりやすい", "わかりやすい", "明確に", "明確", "明快", "明瞭",
                        "読みやすく", "読みやすい"],
            "simpler": ["簡単に", "簡単な", "もっと簡単", "シンプルに", "シンプル", "平易", "易しく", "噛み砕いて",
                        "かみ砕いて", "やさしい言葉"],
            "jargon": ["専門用語", "業界用語", "ジャーゴン", "カタカナ語", "横文字", "難しい言葉", "専門的すぎ"],
            "flow": ["流れ", "流れを良く", "流れよく", "流れるように", "自然な流れ", "つながり", "スムーズに", "スムーズ",
                     "なめらかに", "滑らかに"],
            "specific": ["具体的", "具体的に", "もっと具体的", "具体性", "曖昧", "あいまい", "曖昧さ", "正確に"],
            "structured": ["構成を整えて", "構成を見直して", "構造化", "整理して", "整理された", "論理的に", "論理的な",
                           "体系的"],
            "punchier": ["インパクト", "インパクトのある", "パンチのある", "パンチの効いた", "キレのある", "力強く",
                         "力強い", "メリハリ", "歯切れよく", "歯切れの良い"],
            "engaging": ["魅力的", "面白く", "おもしろく", "興味を引く", "引き込まれる", "惹きつける", "引きつける",
                         "退屈", "飽きない", "読ませる"],
            "enthusiastic": ["熱意", "熱意を込めて", "情熱的", "元気よく", "元気な感じ", "ポジティブ", "前向き",
                             "前向きに", "明るく", "明るい", "活気", "生き生き", "いきいき"],
            "persuasive": ["説得力", "説得力のある", "説得的", "納得感", "納得できる", "訴求力"],
            "creative": ["創造的", "クリエイティブ", "想像力", "想像力豊か", "独創的", "鮮やか", "表現豊か", "描写豊か",
                         "比喩"],
            "playful": ["遊び心", "楽しく", "楽しい", "ユーモア", "ユーモアのある", "面白おかしく", "軽やか", "軽快",
                        "おちゃめ", "ウィット"],
            "better": ["より良く", "もっと良く", "良くして", "改善", "改良", "推敲", "磨いて", "ブラッシュアップ",
                       "手直し", "洗練"],
            "cleaner": ["きれいに", "綺麗に", "整えて", "体裁を整えて", "誤字脱字", "すっきり", "スッキリ"],
            "academic": ["学術的", "学術的に", "アカデミック", "学問的", "論文調", "論文向け", "論文風", "論文らしく"],
            "humanize": ["人間らしく", "人間味", "人間っぽく", "aiっぽくない", "aiっぽさ", "aiらしさ", "ai臭さ"],
            "beginners": ["初心者", "初心者向け", "素人", "一般向け", "一般の人", "入門", "予備知識なし"],
            "experts": ["専門家", "専門家向け", "上級者", "上級者向け", "エンジニア向け", "技術者向け", "専門的に",
                        "もっと専門的"],
            "executives": ["経営陣", "経営層", "役員", "上司", "管理職", "幹部", "意思決定者", "ステークホルダー",
                           "マネージャー"],
        ]),
        FormTable(language: "zh-Hans", rule: .cjk, forms: [
            "professional": ["更专业", "专业一点", "专业些", "专业化", "显得专业", "商务风格", "商务化"],
            "formal": ["正式", "更正式", "正式一点", "正式些", "书面语", "更书面"],
            "casual": ["非正式", "随意一点", "随意些", "随性", "口语", "口语化", "轻松", "轻松一点", "轻松些"],
            "friendly": ["友好", "更友好", "友善", "更友善", "亲切", "更亲切", "热情", "更热情", "更温暖", "温暖一点",
                         "平易近人"],
            "polite": ["礼貌", "更礼貌", "礼貌一点", "客气", "客气一点", "更客气"],
            "softer": ["柔和", "更柔和", "温和", "更温和", "缓和", "软一点", "不那么强硬", "不那么尖锐"],
            "diplomatic": ["委婉", "更委婉", "得体", "更得体", "圆滑", "更圆滑", "有分寸"],
            "direct": ["更直接", "直接一点", "直接些", "直截了当", "开门见山", "直奔主题", "直白", "更直白"],
            "confident": ["自信", "更自信", "自信一点", "果断", "更果断", "坚定", "更坚定", "有底气", "语气肯定"],
            "natural": ["更自然", "自然一点", "自然些", "读起来自然", "不生硬", "生硬", "更地道", "地道一点"],
            "neutral": ["更中立", "客观", "更客观", "客观一点", "公正", "不偏不倚", "不带偏见"],
            "shorter": ["更短", "短一点", "短一些", "短些", "缩短", "删减", "压缩", "简短一点", "减少篇幅"],
            "concise": ["简洁", "更简洁", "精简", "简练", "精炼", "言简意赅", "简明扼要", "不啰嗦", "别啰嗦", "啰嗦"],
            "longer": ["更长", "长一点", "长一些", "长些", "加长", "扩写", "扩展", "扩充", "展开", "详细", "更详细",
                       "详细一点", "充实"],
            "clearer": ["更清楚", "清楚一点", "清楚些", "说清楚", "写清楚", "清晰", "更清晰", "明确", "更明确", "易懂",
                        "好懂", "更易懂", "更好懂", "易读", "更好读"],
            "simpler": ["更简单", "简单一点", "简单些", "简单点", "简化", "通俗", "通俗易懂", "浅显", "浅显易懂", "白话",
                        "大白话"],
            "jargon": ["术语", "专业术语", "行话", "黑话", "少用术语", "太专业", "不那么专业", "流行语"],
            "flow": ["流畅", "更流畅", "通顺", "更通顺", "连贯", "更连贯", "顺畅", "衔接", "过渡", "读起来顺", "行文流畅"],
            "specific": ["更具体", "具体一点", "具体些", "具体化", "精确", "更精确", "更准确", "准确一点", "笼统", "含糊",
                         "模糊"],
            "structured": ["有条理", "更有条理", "条理清晰", "结构化", "结构清晰", "调整结构", "有逻辑", "更有逻辑",
                           "逻辑清晰", "层次分明"],
            "punchier": ["更有力", "有力度", "有力一点", "冲击力", "更有冲击力", "掷地有声", "铿锵有力", "干脆利落",
                         "有张力"],
            "engaging": ["吸引人", "更吸引人", "引人入胜", "有趣", "更有趣", "抓人", "更抓人", "不无聊", "无聊", "枯燥",
                         "不枯燥"],
            "enthusiastic": ["热情洋溢", "积极", "更积极", "有活力", "充满活力", "活力", "激情", "兴奋", "振奋", "乐观",
                             "更乐观"],
            "persuasive": ["说服力", "有说服力", "更有说服力", "打动人", "更打动人", "令人信服"],
            "creative": ["创意", "有创意", "更有创意", "创造性", "想象力", "富有想象力", "生动", "更生动", "形象生动",
                         "更形象", "画面感", "文学性"],
            "playful": ["俏皮", "更俏皮", "幽默", "更幽默", "风趣", "诙谐", "好玩", "轻松幽默", "活泼", "更活泼", "逗趣",
                        "搞笑"],
            "better": ["更好", "好一点", "改进", "改善", "优化", "润色", "打磨", "完善", "修饰", "提升"],
            "cleaner": ["整洁", "更整洁", "干净", "更干净", "清理", "整理一下", "规整", "错别字"],
            "academic": ["学术", "更学术", "学术化", "学术性", "学术风格", "论文", "论文风格", "严谨", "更严谨"],
            "humanize": ["人性化", "更人性化", "像人写的", "不像ai", "别像ai", "ai味", "去ai味", "ai感", "人味", "有人味"],
            "beginners": ["初学者", "新手", "入门", "外行", "门外汉", "小白", "零基础", "大众读者", "普通读者",
                          "非专业人士"],
            "experts": ["专家", "专业人士", "业内人士", "内行", "工程师", "技术人员"],
            "executives": ["领导", "老板", "高管", "管理层", "上司", "决策者", "董事会", "利益相关者"],
        ]),
    ]
}
