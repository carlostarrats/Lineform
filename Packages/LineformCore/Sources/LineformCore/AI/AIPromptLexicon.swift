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
public struct AIPromptWord: Sendable, Equatable, Identifiable {
    public enum Group: String, CaseIterable, Sendable {
        case tone, length, clarity, energy, polish, audience
    }

    /// One concrete meaning of the word: a short chip label and the direction sent to the model.
    public struct Refinement: Sendable, Equatable, Identifiable {
        public var id: String { label }
        public let label: String
        public let direction: String
    }

    /// Stable identity (the word's base form). Never shown, never persisted.
    public let id: String
    public let group: Group
    /// Phrases and word forms that match, lower case ("more professional", "professionally").
    public let forms: [String]
    /// The options card's heading ("Professional how?").
    public let question: String
    public let refinements: [Refinement]
    /// Labels of the refinements preselected (and sent while the writer has not chosen).
    public let defaults: [String]

    public func refinement(_ label: String) -> Refinement? {
        refinements.first { $0.label == label }
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

public enum AIPromptLexicon {
    /// The fixed keep-constraint appended to every request built from the drawer's input.
    public static let keepConstraint = "Keep the meaning, facts, numbers and every Markdown mark; change only the selected passage."

    /// The words for an interface language. Only English ships (2026-11-24): each language needs
    /// its OWN list built from how people write requests in it (German "sachlich", the T–V
    /// pronouns, Japanese keigo), never a translation of this one. Add a language by returning its
    /// list here; until then that language underlines nothing.
    public static func words(forLanguage code: String) -> [AIPromptWord] {
        let base = code.split(separator: "-").first.map(String.init)?.lowercased() ?? code.lowercased()
        switch base {
        case "en": return english
        default: return []
        }
    }

    /// The words for the interface language the app is running in.
    public static var current: [AIPromptWord] {
        words(forLanguage: Bundle.module.preferredLocalizations.first ?? "en")
    }

    public static func word(_ id: String, in words: [AIPromptWord] = english) -> AIPromptWord? {
        words.first { $0.id == id }
    }

    /// Every curated word in `text`: longest forms first, case- and diacritic-insensitive, whole
    /// words only (a letter or digit on either side is no match), never overlapping. Sorted by
    /// position. Pure and cheap: it runs on every keystroke, with no network.
    public static func matches(in text: String, words: [AIPromptWord] = current) -> [AIPromptWordMatch] {
        guard !text.isEmpty, !words.isEmpty else { return [] }
        let ns = text as NSString
        var forms: [(word: String, form: String)] = []
        for word in words { for form in word.forms { forms.append((word.id, form)) } }
        forms.sort { ($0.form as NSString).length > ($1.form as NSString).length }

        var taken = IndexSet()
        var found: [AIPromptWordMatch] = []
        for (wordID, form) in forms {
            var searchStart = 0
            while searchStart < ns.length {
                let range = ns.range(of: form, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: NSRange(location: searchStart, length: ns.length - searchStart))
                guard range.location != NSNotFound, range.length > 0 else { break }
                searchStart = NSMaxRange(range)
                guard isBoundary(before: range.location, in: ns), isBoundary(after: NSMaxRange(range), in: ns),
                      !taken.intersects(integersIn: range.location..<NSMaxRange(range)) else { continue }
                taken.insert(integersIn: range.location..<NSMaxRange(range))
                found.append(AIPromptWordMatch(wordID: wordID, range: range))
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The direction lines for the words matched in an instruction: for each word (once, in the
    /// order typed), the refinements the writer chose, or the word's defaults when they never
    /// opened it. The writer's word is kept ("“professional” means: …"): it carries intent the
    /// checklist can miss.
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

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true } // a surrogate: part of a letter
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isBoundary(before index: Int, in text: NSString) -> Bool {
        index == 0 || !isWordCharacter(text.character(at: index - 1))
    }

    private static func isBoundary(after index: Int, in text: NSString) -> Bool {
        index >= text.length || !isWordCharacter(text.character(at: index))
    }
}

// MARK: - The English list

extension AIPromptLexicon {
    private static func word(_ id: String, _ group: AIPromptWord.Group, _ forms: [String], _ question: String,
                             _ refinements: [(String, String)], defaults: [Int]) -> AIPromptWord {
        let list = refinements.map { AIPromptWord.Refinement(label: $0.0, direction: $0.1) }
        return AIPromptWord(id: id, group: group, forms: forms, question: question, refinements: list,
                            defaults: defaults.map { list[$0].label })
    }

    /// 33 words in six groups. Directions are plain English instructions to the model (never shown);
    /// labels and questions are what the writer sees.
    public static let english: [AIPromptWord] = [
        // MARK: Tone
        word("professional", .tone,
             ["professional", "professionally", "more professional", "businesslike", "less casual", "polished"],
             "Professional how?", [
                ("no slang or emoji", "Replace slang and idioms with standard wording, and remove emoji."),
                ("fewer jokes", "Remove jokes and playful asides."),
                ("no exclamation marks", "Use no exclamation marks."),
                ("fewer adjectives", "Cut decorative adjectives and adverbs; keep only ones that carry meaning."),
                ("shorter sentences", "Shorten long sentences."),
                ("keep it warm", "Keep a warm, human tone; do not become cold or bureaucratic."),
             ], defaults: [0, 2]),
        word("formal", .tone,
             ["formal", "formally", "more formal", "formalize", "formalise", "less informal"],
             "Formal how?", [
                ("no contractions", "Expand contractions (don't becomes do not)."),
                ("standard punctuation", "Use standard capitalization and punctuation; no repeated punctuation."),
                ("no fillers", "Remove fillers such as like, basically and so yeah."),
                ("complete sentences", "Use complete sentences; no fragments."),
                ("no slang", "Replace slang with standard words."),
             ], defaults: [0, 3]),
        word("casual", .tone,
             ["casual", "casually", "more casual", "informal", "relaxed", "less formal", "laid-back", "chatty", "conversational"],
             "Casual how?", [
                ("use contractions", "Use contractions (it's, we'll)."),
                ("shorter sentences", "Use shorter sentences; a fragment now and then is fine."),
                ("everyday words", "Use everyday words instead of formal ones (use, not utilize)."),
                ("speak to “you”", "Address the reader directly as “you”."),
                ("a touch of humour", "Allow at most one light touch of humour."),
             ], defaults: [0, 2]),
        word("friendly", .tone,
             ["friendly", "friendlier", "more friendly", "warm", "warmer", "warmly", "nicer", "kinder", "approachable"],
             "Friendlier how?", [
                ("add a thank-you", "Add one short greeting or thank-you where it fits naturally."),
                ("use “you” and “we”", "Use “you” and “we”."),
                ("use contractions", "Use contractions."),
                ("softer requests", "Phrase requests as invitations (could you…, would it help to…)."),
                ("acknowledge the reader", "Acknowledge the reader's situation in one line."),
                ("no new promises", "Do not add new claims or promises."),
             ], defaults: [2, 3]),
        word("polite", .tone,
             ["polite", "politer", "more polite", "politely", "courteous", "respectful"],
             "Polite how?", [
                ("requests, not commands", "Turn commands into requests (could you…)."),
                ("add thanks", "Add a brief thank-you."),
                ("please mid-sentence", "If you use please, put it mid-sentence, not at the start."),
                ("drop “actually”", "Remove “in fact” and “actually”."),
                ("keep the request", "Keep the request itself unchanged."),
             ], defaults: [0, 4]),
        word("softer", .tone,
             ["softer", "soften", "gentler", "gentle", "less harsh", "less blunt", "less aggressive", "milder"],
             "Softer how?", [
                ("add light hedges", "Add light hedges such as I think or perhaps."),
                ("“I” statements", "Turn statements of fault into “I” statements (I couldn't find… rather than You forgot…)."),
                ("suggest, don't demand", "Turn demands into questions or suggestions."),
                ("no absolutes", "Remove absolute words such as always, never and obviously."),
                ("keep the deadline", "Keep the core message and any deadline intact."),
             ], defaults: [2, 4]),
        word("diplomatic", .tone,
             ["diplomatic", "more diplomatic", "diplomatically", "tactful", "more tactful", "tactfully"],
             "Diplomatic how?", [
                ("lead with what works", "Lead with what is agreed or what works."),
                ("criticism as suggestion", "Frame criticism as a suggestion."),
                ("no blame words", "Remove blame words such as failed, wrong and mistake."),
                ("hedge disagreement", "Hedge disagreements gently."),
                ("keep the facts", "Keep facts and decisions unchanged."),
             ], defaults: [1, 4]),
        word("direct", .tone,
             ["direct", "more direct", "directly", "straightforward", "to the point", "get to the point", "blunter"],
             "Direct how?", [
                ("point first", "Put the main point or request in the first sentence."),
                ("no hedges", "Remove hedges such as I think, maybe and just."),
                ("no preamble", "Remove apologies and preambles."),
                ("a clear ask", "End with a clear ask."),
                ("shorter sentences", "Use shorter sentences."),
                ("stay polite", "Stay polite; no blame."),
             ], defaults: [0, 5]),
        word("confident", .tone,
             ["confident", "more confident", "confidently", "assertive", "more assertive", "less hedgy", "less unsure", "surer"],
             "Confident how?", [
                ("no hedges", "Remove hedges and qualifiers such as I think, sort of and might."),
                ("no needless apologies", "Remove unnecessary apologies."),
                ("active voice", "Use the active voice."),
                ("“will”, not “try to”", "Use will instead of would like to try to."),
                ("statements, not questions", "Prefer statements to questions."),
                ("don't overstate", "Do not overstate any fact."),
             ], defaults: [0, 5]),
        word("natural", .tone,
             ["natural", "more natural", "naturally", "less stiff", "stiff", "robotic", "less robotic", "wooden", "more human"],
             "More natural how?", [
                ("use contractions", "Use contractions."),
                ("everyday words", "Replace formal words with everyday ones."),
                ("vary sentence length", "Vary sentence length."),
                ("verbs, not nouns", "Turn nominalizations into verbs (make a decision becomes decide)."),
                ("no stock phrases", "Remove stock phrases such as I hope this email finds you well."),
                ("same politeness", "Keep the same level of politeness."),
             ], defaults: [1, 3]),
        word("neutral", .tone,
             ["neutral", "more neutral", "neutrally", "objective", "more objective", "unbiased", "less biased", "impartial"],
             "Neutral how?", [
                ("no loaded words", "Remove opinion words and loaded adjectives."),
                ("no intensifiers", "Remove intensifiers such as very, extremely and incredibly."),
                ("no exclamation marks", "Use no exclamation marks."),
                ("attribute claims", "Attribute claims (according to…) rather than asserting them."),
                ("both sides", "If the text argues one side, present both sides evenly."),
             ], defaults: [0, 1]),

        // MARK: Length
        word("shorter", .length,
             ["shorter", "shorten", "short", "trim", "trimmed", "condense", "condensed", "less long", "briefer"],
             "Shorter how?", [
                ("about a third shorter", "Make it about a third shorter."),
                ("about half", "Make it about half as long."),
                ("no repeated points", "Remove repeated points."),
                ("no intro or sign-off", "Remove intros and sign-off padding."),
                ("drop examples", "Drop examples, keeping the main point."),
                ("keep every fact", "Keep every key fact, number, date and name."),
             ], defaults: [0, 5]),
        word("concise", .length,
             ["concise", "more concise", "concisely", "succinct", "brief", "tighter", "tighten", "tight", "less verbose", "less wordy"],
             "Concise how?", [
                ("no filler words", "Remove filler words such as really, just, actually and basically."),
                ("fewer adverbs", "Remove adverbs where the verb is enough."),
                ("no wordy phrases", "Replace wordy phrases (in order to becomes to)."),
                ("unhide verbs", "Unhide verbs (conduct an analysis becomes analyze)."),
                ("active voice", "Use the active voice."),
                ("cut words, not ideas", "Keep all content: cut words, not ideas."),
             ], defaults: [0, 5]),
        word("longer", .length,
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
        word("clearer", .clarity,
             ["clear", "clearer", "more clear", "clarify", "clarity", "readable", "more readable", "easier to follow", "less confusing"],
             "Clearer how?", [
                ("one idea per sentence", "One idea per sentence."),
                ("under 20 words", "Keep sentences under about 20 words."),
                ("say who does what", "Use the active voice and name who does what."),
                ("define jargon", "Define or replace jargon."),
                ("main point first", "Put the main point first."),
                ("keep it accurate", "Keep the meaning and technical accuracy."),
             ], defaults: [0, 5]),
        word("simpler", .clarity,
             ["simple", "simpler", "simplify", "simplified", "plain", "plainer", "plain english", "easier to read", "easier"],
             "Simpler how?", [
                ("everyday words", "Use everyday words instead of long ones."),
                ("short sentences", "Use short sentences."),
                ("explain acronyms", "Explain or remove jargon and acronyms."),
                ("present tense", "Use the present tense where possible."),
                ("speak to “you”", "Address the reader as “you”."),
                ("keep every fact", "Keep every fact."),
             ], defaults: [0, 5]),
        word("jargon", .clarity,
             ["jargon", "less jargon", "jargony", "less jargony", "less technical", "fewer buzzwords", "buzzwords"],
             "Less jargon how?", [
                ("plain words", "Replace technical terms with plain words."),
                ("spell out acronyms", "Spell out acronyms on first use."),
                ("explain kept terms", "Add a short explanation where a term must stay."),
                ("no buzzwords", "Remove buzzwords such as leverage and synergy."),
                ("keep needed terms", "Keep the terms the reader must know."),
             ], defaults: [0, 3]),
        word("flow", .clarity,
             ["flow", "flows", "flows better", "better flow", "smooth", "smoother", "smooth this out", "more coherent", "reads better"],
             "What makes it flow?", [
                ("better transitions", "Add or improve transitions between sentences."),
                ("vary sentence length", "Vary sentence length and openings."),
                ("fix awkward phrasing", "Rewrite awkward or clunky phrasing."),
                ("clear pronouns", "Fix pronouns that do not clearly refer to anything."),
                ("no new content", "Add no new ideas."),
             ], defaults: [0, 4]),
        word("specific", .clarity,
             ["specific", "more specific", "precise", "more precise", "less vague", "vague", "concrete", "more concrete"],
             "Specific how?", [
                ("replace vague words", "Replace vague words such as things, stuff and soon with specifics."),
                ("use the text's numbers", "Use numbers, dates and names already in the text."),
                ("mark missing details", "Mark missing details with a placeholder such as [date] rather than inventing them."),
                ("a concrete example", "Replace a general claim with a concrete example from the text."),
                ("no filler qualifiers", "Remove filler qualifiers."),
             ], defaults: [0, 2]),
        word("structured", .clarity,
             ["structured", "more structured", "organized", "organised", "better organized", "better organised", "logical"],
             "Structured how?", [
                ("one topic per paragraph", "Reorder so each paragraph has one topic."),
                ("logical order", "Put the points in a logical order."),
                ("topic sentence first", "Open each paragraph with its topic sentence."),
                ("signpost the steps", "Signpost steps with words such as first, then and finally."),
                ("no new content", "Add no new ideas."),
             ], defaults: [1, 4]),

        // MARK: Energy
        word("punchier", .energy,
             ["punchy", "punchier", "snappy", "snappier", "more impact", "more impactful", "stronger", "bolder", "crisper", "crisp"],
             "Punchier how?", [
                ("shorter sentences", "Use shorter sentences; fragments are allowed."),
                ("strong verbs", "Use strong verbs instead of adverb plus verb."),
                ("cut the warm-up", "Cut the first sentence if it is a warm-up."),
                ("end strong", "End on the strongest line."),
                ("no hedges", "Remove hedges."),
                ("no hype words", "Add no hype words or exclamation marks."),
             ], defaults: [0, 4]),
        word("engaging", .energy,
             ["engaging", "more engaging", "interesting", "more interesting", "compelling", "more compelling", "less boring", "boring"],
             "Engaging how?", [
                ("a strong opening", "Open with a question, a surprising fact or a concrete example from the text."),
                ("speak to “you”", "Speak to the reader as “you”."),
                ("vary sentence length", "Vary sentence length."),
                ("concrete images", "Use concrete images instead of abstractions."),
                ("keep the facts", "Keep claims and facts unchanged."),
             ], defaults: [2, 4]),
        word("enthusiastic", .energy,
             ["enthusiastic", "more enthusiastic", "excited", "more excited", "upbeat", "more upbeat", "energetic", "livelier", "lively"],
             "Enthusiastic how?", [
                ("upbeat words", "Use upbeat word choice."),
                ("one exclamation mark", "Allow at most one exclamation mark."),
                ("lead with the positive", "Lead with the positive."),
                ("emoji allowed", "One fitting emoji is allowed."),
                ("don't exaggerate", "Do not exaggerate facts."),
             ], defaults: [0, 4]),
        word("persuasive", .energy,
             ["persuasive", "more persuasive", "persuasively", "convincing", "more convincing", "salesy"],
             "Persuasive how?", [
                ("benefit first", "Lead with the benefit to the reader."),
                ("a call to action", "End with a clear call to action."),
                ("back the claims", "Back claims with reasons or evidence from the text."),
                ("answer the objection", "Answer the likely objection."),
                ("no hedges", "Remove hedges."),
                ("no invented claims", "Invent no statistics or claims."),
             ], defaults: [0, 5]),
        word("creative", .energy,
             ["creative", "more creative", "imaginative", "more imaginative", "vivid", "more vivid", "colorful", "colourful", "descriptive"],
             "Creative how?", [
                ("sensory detail", "Use concrete sensory detail."),
                ("one comparison", "Allow one metaphor or comparison."),
                ("replace clichés", "Replace clichés."),
                ("vary the rhythm", "Vary rhythm and sentence openings."),
                ("keep the facts", "Keep the events and facts the same."),
             ], defaults: [2, 4]),
        word("playful", .energy,
             ["playful", "more playful", "fun", "more fun", "funnier", "humorous", "witty", "wittier", "lighter", "light-hearted", "lighthearted"],
             "Playful how?", [
                ("one light joke", "Add light humour: one joke at most."),
                ("casual words", "Use contractions and casual words."),
                ("wordplay allowed", "Wordplay is allowed."),
                ("emoji allowed", "One fitting emoji is allowed."),
                ("keep the information", "Keep the information complete."),
             ], defaults: [1, 4]),

        // MARK: Polish
        word("better", .polish,
             ["better", "improve", "improved", "polish", "refine", "refined", "make it better", "nicer wording"],
             "Better how?", [
                ("grammar and spelling only", "Fix grammar and spelling only."),
                ("better word choice", "Also improve word choice."),
                ("tighter", "Also tighten the wording."),
                ("smoother flow", "Also smooth the flow."),
                ("keep my voice", "Keep the writer's voice: do not change the tone."),
                ("same length", "Keep the length within about ten percent."),
             ], defaults: [1, 4]),
        word("cleaner", .polish,
             ["clean", "cleaner", "clean up", "clean it up", "tidy", "tidier", "tidy up", "neater"],
             "Cleaner how?", [
                ("fix grammar", "Fix grammar, spelling and punctuation."),
                ("consistent style", "Make capitalization and spacing consistent."),
                ("no repetition", "Remove repeated words and phrases."),
                ("no filler words", "Remove filler words."),
                ("keep the wording", "Otherwise keep the wording as it is."),
             ], defaults: [0, 4]),
        word("academic", .polish,
             ["academic", "more academic", "scholarly", "more scholarly", "scientific", "for a paper"],
             "Academic how?", [
                ("no contractions", "Use no contractions."),
                ("careful claims", "Hedge claims appropriately (suggests, may)."),
                ("precise terms", "Prefer precise terms to everyday ones."),
                ("third person", "Write in the third person; no “you”."),
                ("no exclamations", "No rhetorical questions or exclamation marks."),
                ("keep the data", "Keep citations and data unchanged."),
             ], defaults: [2, 5]),
        word("humanize", .polish,
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
        word("beginners", .audience,
             ["beginners", "for beginners", "non-experts", "non-technical", "laypeople", "a general audience", "newcomers"],
             "Beginners how?", [
                ("explain every term", "Explain every technical term in plain words."),
                ("one step at a time", "Take one step at a time."),
                ("an everyday example", "Add one everyday example."),
                ("no assumed knowledge", "Assume no prior knowledge."),
                ("keep it accurate", "Keep it accurate; simplify without dumbing down."),
             ], defaults: [0, 4]),
        word("experts", .audience,
             ["experts", "for experts", "expert", "more technical", "for engineers", "specialists"],
             "Experts how?", [
                ("precise terms", "Use precise technical terms."),
                ("skip the basics", "Skip explanations of the basics."),
                ("denser", "Make it denser: fewer words per idea."),
                ("numbers first", "Lead with numbers and specifics already in the text."),
                ("keep it accurate", "Keep it accurate; add no new claims."),
             ], defaults: [0, 4]),
        word("executives", .audience,
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
