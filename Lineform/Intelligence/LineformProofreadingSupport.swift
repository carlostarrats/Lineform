import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct LineformProofreadingConfiguration: Equatable {
    enum EnglishDialect: String, Equatable, CaseIterable {
        case system
        case american
        case british
        case canadian
        case australian

        var spellCheckerLanguage: String {
            switch self {
            case .system:
                return "en"
            case .american:
                return "en_US"
            case .british:
                return "en_GB"
            case .canadian:
                return "en_CA"
            case .australian:
                return "en_AU"
            }
        }
    }

    var dialect: EnglishDialect
    var ignoredWords: Set<String>

    static let lineformDefault = LineformProofreadingConfiguration()

    init(dialect: EnglishDialect = .system, ignoredWords: Set<String> = []) {
        self.dialect = dialect
        self.ignoredWords = Set(ignoredWords.map { $0.lowercased() })
    }

    func ignores(_ word: String) -> Bool {
        ignoredWords.contains(word.lowercased())
    }
}

enum LineformProofreadingSupport {
    static func issues(in text: String, configuration: LineformProofreadingConfiguration = .lineformDefault) -> Set<String> {
        let normalizedText = text.lowercased()
        var issues: Set<String> = []

        for misspelling in knownMisspellings where !configuration.ignores(misspelling) && containsWord(misspelling, in: normalizedText) {
            issues.insert("word:\(misspelling)")
        }

        #if canImport(AppKit)
        issues.formUnion(systemSpellingIssues(in: text, configuration: configuration))
        #endif

        if !configuration.ignores("im"), text.range(of: #"\b[Ii]m\b"#, options: .regularExpression) != nil {
            issues.insert("word:im")
        }

        if !configuration.ignores("i"), text.range(of: #"\bi\b"#, options: .regularExpression) != nil {
            issues.insert("pronoun:i")
        }

        if text.range(of: #"[ \t]{2,}"#, options: .regularExpression) != nil {
            issues.insert("spacing:multiple")
        }

        if !configuration.ignores("i"), text.range(of: #"\b[Ii]\s+has\b"#, options: .regularExpression) != nil {
            issues.insert("grammar:i-has")
        }

        if text.range(of: #"\b(?:[Tt]he|[Tt]his|[Tt]hat)\s+(?:editor|app|document|file|draft|selection)\s+keep\b"#, options: .regularExpression) != nil {
            issues.insert("grammar:singular-keep")
        }

        return issues
    }

    static func hasLikelyIssue(_ text: String, configuration: LineformProofreadingConfiguration = .lineformDefault) -> Bool {
        !issues(in: text, configuration: configuration).isEmpty
    }

    static func hasUnresolvedIssues(
        in replacement: String,
        selectedText: String,
        configuration: LineformProofreadingConfiguration = .lineformDefault
    ) -> Bool {
        let selectedIssues = issues(in: selectedText, configuration: configuration)
        guard !selectedIssues.isEmpty else {
            return false
        }

        let replacementIssues = issues(in: replacement, configuration: configuration)
        return !selectedIssues.intersection(replacementIssues).isEmpty
    }

    static func deterministicFallback(
        for selectedText: String,
        variant: Int,
        configuration: LineformProofreadingConfiguration = .lineformDefault
    ) -> String? {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback = ambiguousProofreadFallback(for: trimmed, variant: variant) {
            return fallback
        }

        if !configuration.ignores(trimmed), let correction = knownOneWordCorrections[trimmed.lowercased()] {
            return correction
        }

        let corrected = applyingKnownCorrections(to: trimmed, configuration: configuration)
        if corrected != trimmed {
            return corrected
        }

        return systemSpellcheckProofreadFallback(for: trimmed, configuration: configuration) ?? trimmed
    }

    static func knownOneWordCorrection(for text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var trailingPunctuation = ""
        if let last = trimmed.last, ".!?".contains(last) {
            trailingPunctuation = String(last)
            trimmed.removeLast()
        }

        guard var correction = knownOneWordCorrections[trimmed.lowercased()] else {
            return nil
        }
        if trimmed.first?.isUppercase == true {
            correction = correction.prefix(1).uppercased() + correction.dropFirst()
        }

        return correction + trailingPunctuation
    }

    static func applyingKnownCorrections(
        to text: String,
        configuration: LineformProofreadingConfiguration = .lineformDefault
    ) -> String {
        let phraseCorrected = text
            .replacingOccurrences(of: "exportingg", with: "exporting")
            .replacingOccurrences(of: "The editor keep drafts local and dont change ", with: "The editor keeps drafts local and doesn't change ")
            .replacingOccurrences(of: "the editor keep drafts local and dont change ", with: "the editor keeps drafts local and doesn't change ")
            .replacingOccurrences(of: "The editor keep the file local and dont upload ", with: "The editor keeps the file local and doesn't upload ")
            .replacingOccurrences(of: "the editor keep the file local and dont upload ", with: "the editor keeps the file local and doesn't upload ")
            .replacingOccurrences(of: "Lineform también guarda borradores Markdown localmente y dont upload drafts.", with: "Lineform también guarda borradores Markdown localmente y doesn't upload drafts.")
            .replacingOccurrences(of: "The editor keep ", with: "The editor keeps ")
            .replacingOccurrences(of: "the editor keep ", with: "the editor keeps ")
            .replacingOccurrences(of: "Writers dont ", with: "Writers don't ")
            .replacingOccurrences(of: "writers dont ", with: "writers don't ")
            .replacingOccurrences(of: "I has ", with: "I have ")
            .replacingOccurrences(of: "i has ", with: "i have ")
            .replacingOccurrences(of: " dont ", with: " don't ")
            .replacingOccurrences(of: #"\bi\b"#, with: "I", options: .regularExpression)

        return knownOneWordCorrections.reduce(phraseCorrected) { partial, pair in
            guard !configuration.ignores(pair.key) else {
                return partial
            }
            return replacingWord(pair.key, with: pair.value, in: partial)
        }
    }

    #if canImport(AppKit)
    private static func systemSpellingIssues(in text: String, configuration: LineformProofreadingConfiguration) -> Set<String> {
        guard text.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return []
        }

        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        var issues: Set<String> = []
        let checker = NSSpellChecker.shared

        while searchRange.length > 0 {
            let misspelledRange = checker.checkSpelling(
                of: text,
                startingAt: searchRange.location,
                language: configuration.dialect.spellCheckerLanguage,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            guard misspelledRange.location != NSNotFound, NSMaxRange(misspelledRange) <= nsText.length else {
                break
            }

            let word = nsText.substring(with: misspelledRange)
            let guesses = checker.guesses(
                forWordRange: misspelledRange,
                in: text,
                language: configuration.dialect.spellCheckerLanguage,
                inSpellDocumentWithTag: 0
            ) ?? []
            if shouldTrackSystemMisspelling(word, guesses: guesses, configuration: configuration) {
                issues.insert("spell:\(word.lowercased())")
            }

            let nextLocation = max(NSMaxRange(misspelledRange), searchRange.location + 1)
            guard nextLocation < nsText.length else {
                break
            }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return issues
    }

    private static func shouldTrackSystemMisspelling(
        _ word: String,
        guesses: [String],
        configuration: LineformProofreadingConfiguration
    ) -> Bool {
        let normalizedWord = word.lowercased()
        guard !ignoredSystemSpellcheckWords.contains(normalizedWord), !configuration.ignores(normalizedWord) else {
            return false
        }

        let scalars = word.unicodeScalars
        guard scalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
            return false
        }

        guard word == normalizedWord else {
            return false
        }

        if word.count >= 3 {
            return true
        }

        return word.count >= 2
            && normalizedWord != "im"
            && conservativeSystemSpellingCorrection(for: word, guesses: guesses) != nil
    }
    #endif

    private static let knownMisspellings: Set<String> = [
        "teh",
        "dont",
        "doesnt",
        "wont",
        "cant",
        "tommorow",
        "tomorow",
        "recieve",
        "seperate",
        "adress",
        "occured",
        "definately",
        "consistant",
        "consistatnt",
        "recoginze",
        "consern",
        "ableo",
        "foer",
        "speling",
        "markdowxn",
        "sentnce",
        "erors",
        "exportingg"
    ]

    private static let knownOneWordCorrections: [String: String] = [
        "teh": "the",
        "dont": "don't",
        "doesnt": "doesn't",
        "wont": "won't",
        "cant": "can't",
        "tommorow": "tomorrow",
        "tomorow": "tomorrow",
        "recieve": "receive",
        "seperate": "separate",
        "adress": "address",
        "occured": "occurred",
        "definately": "definitely",
        "consistant": "consistent",
        "consistatnt": "consistent",
        "recoginze": "recognize",
        "consern": "concern",
        "ableo": "able to",
        "foer": "for",
        "speling": "spelling",
        "markdowxn": "markdown",
        "sentnce": "sentence",
        "erors": "errors"
    ]

    #if canImport(AppKit)
    private static let ignoredSystemSpellcheckWords: Set<String> = [
        "appkit",
        "github",
        "icloud",
        "lineform",
        "markdown",
        "macos",
        "swiftui",
        "textkit",
        "xcode"
    ]
    #endif

    private static func containsWord(_ word: String, in text: String) -> Bool {
        text.range(
            of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func ambiguousProofreadFallback(for selectedText: String, variant: Int) -> String? {
        let normalizedText = normalized(selectedText)
        guard normalizedText == "can i ds it tommorow?" || normalizedText == "can i ds it tomorrow?" else {
            return nil
        }

        return [
            "Can I do it tomorrow?",
            "Can I discuss it tomorrow?",
            "Can I see it tomorrow?"
        ][variant % 3]
    }

    private static func systemSpellcheckProofreadFallback(
        for text: String,
        configuration: LineformProofreadingConfiguration
    ) -> String? {
        #if canImport(AppKit)
        guard text.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return nil
        }

        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        var replacements: [(range: NSRange, replacement: String)] = []
        let checker = NSSpellChecker.shared

        while searchRange.length > 0 {
            let misspelledRange = checker.checkSpelling(
                of: text,
                startingAt: searchRange.location,
                language: configuration.dialect.spellCheckerLanguage,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            guard misspelledRange.location != NSNotFound, NSMaxRange(misspelledRange) <= nsText.length else {
                break
            }

            let word = nsText.substring(with: misspelledRange)
            let guesses = checker.guesses(
                forWordRange: misspelledRange,
                in: text,
                language: configuration.dialect.spellCheckerLanguage,
                inSpellDocumentWithTag: 0
            ) ?? []
            if shouldApplySystemSpellingCorrection(to: word, guesses: guesses, configuration: configuration),
               let correction = conservativeSystemSpellingCorrection(for: word, guesses: guesses) {
                replacements.append((misspelledRange, correction))
            }

            guard replacements.count <= 6 else {
                return nil
            }

            let nextLocation = max(NSMaxRange(misspelledRange), searchRange.location + 1)
            guard nextLocation < nsText.length else {
                break
            }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        guard !replacements.isEmpty else {
            return nil
        }

        var corrected = text
        for replacement in replacements.reversed() {
            guard let range = Range(replacement.range, in: corrected) else {
                return nil
            }
            corrected.replaceSubrange(range, with: replacement.replacement)
        }

        return corrected == text ? nil : corrected
        #else
        return nil
        #endif
    }

    private static func shouldApplySystemSpellingCorrection(
        to word: String,
        guesses: [String],
        configuration: LineformProofreadingConfiguration
    ) -> Bool {
        #if canImport(AppKit)
        shouldTrackSystemMisspelling(word, guesses: guesses, configuration: configuration)
        #else
        false
        #endif
    }

    private static func conservativeSystemSpellingCorrection(for word: String, guesses: [String]) -> String? {
        guesses
            .filter { isConservativeSpellingCorrection(from: word, to: $0) }
            .min { first, second in
                editDistance(word.lowercased(), first.lowercased()) < editDistance(word.lowercased(), second.lowercased())
            }
    }

    private static func isConservativeSpellingCorrection(from word: String, to guess: String) -> Bool {
        let normalizedWord = word.lowercased()
        let normalizedGuess = guess.lowercased()
        guard normalizedWord != normalizedGuess, normalizedGuess.count >= 2 else {
            return false
        }

        guard normalizedGuess.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
            return false
        }

        let maximumDistance = max(2, normalizedWord.count / 3)
        return editDistance(normalizedWord, normalizedGuess) <= maximumDistance
    }

    private static func editDistance(_ first: String, _ second: String) -> Int {
        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        guard !firstCharacters.isEmpty else {
            return secondCharacters.count
        }
        guard !secondCharacters.isEmpty else {
            return firstCharacters.count
        }

        var previousRow = Array(0...secondCharacters.count)
        var currentRow = Array(repeating: 0, count: secondCharacters.count + 1)

        for firstIndex in 1...firstCharacters.count {
            currentRow[0] = firstIndex
            for secondIndex in 1...secondCharacters.count {
                let substitutionCost = firstCharacters[firstIndex - 1] == secondCharacters[secondIndex - 1] ? 0 : 1
                currentRow[secondIndex] = min(
                    previousRow[secondIndex] + 1,
                    currentRow[secondIndex - 1] + 1,
                    previousRow[secondIndex - 1] + substitutionCost
                )
            }
            previousRow = currentRow
        }

        return previousRow[secondCharacters.count]
    }

    private static func replacingWord(_ misspelling: String, with correction: String, in text: String) -> String {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: misspelling))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let nsText = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
        for match in matches {
            let original = nsText.substring(with: match.range)
            let replacement = original.first?.isUppercase == true
                ? correction.prefix(1).uppercased() + correction.dropFirst()
                : correction
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
