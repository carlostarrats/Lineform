import XCTest

/// Reads the .xcstrings source files from the repo (via #filePath), not the built
/// bundle — the gates protect the committed catalogs.
final class LocalizationCatalogTests: XCTestCase {
    private static let languages = ["es", "fr", "de", "ja", "zh-Hans"]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)          // …/LineformTests/LocalizationCatalogTests.swift
            .deletingLastPathComponent()          // …/LineformTests
            .deletingLastPathComponent()          // repo root
    }

    private func catalog(_ name: String) throws -> [String: [String: Any]] {
        let url = repoRoot().appendingPathComponent("Lineform/\(name).xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func translation(_ entry: [String: Any], _ language: String) -> String? {
        let localizations = entry["localizations"] as? [String: [String: Any]]
        let unit = localizations?[language]?["stringUnit"] as? [String: Any]
        // Plural entries nest under "variations"; any translated variation counts as present.
        if unit == nil, let variations = localizations?[language]?["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: [String: Any]],
           let anyForm = plural.values.first?["stringUnit"] as? [String: Any] {
            return anyForm["value"] as? String
        }
        return unit?["value"] as? String
    }

    /// `%#@token@` stands for the token's `argNum`-th argument formatted with its
    /// `formatSpecifier`. Expanding it lets an explicit-substitution translation be compared
    /// against its key on the same terms as a plain one — the gate gets stronger, not looser:
    /// it now asserts every source argument is consumed exactly once.
    private func expandingSubstitutions(_ value: String, _ localization: [String: Any]) -> String {
        guard let subs = localization["substitutions"] as? [String: [String: Any]] else { return value }
        var expanded = value
        for (token, spec) in subs {
            guard let argNum = spec["argNum"] as? Int,
                  let fmt = spec["formatSpecifier"] as? String else { continue }
            expanded = expanded.replacingOccurrences(of: "%#@\(token)@", with: "%\(argNum)$\(fmt)")
        }
        return expanded
    }

    /// EVERY translated string a language contributes for one key. `translation`'s
    /// `plural.values.first` picked an arbitrary form, so drift in the others was invisible.
    private func translations(_ entry: [String: Any], _ language: String) -> [String] {
        guard let loc = (entry["localizations"] as? [String: [String: Any]])?[language] else { return [] }
        var out: [String] = []
        if let v = (loc["stringUnit"] as? [String: Any])?["value"] as? String {
            out.append(expandingSubstitutions(v, loc))
        }
        if let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
            out += plural.values.compactMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
                                .map { expandingSubstitutions($0, loc) }
        }
        return out
    }

    private func isTranslatable(_ entry: [String: Any]) -> Bool {
        (entry["shouldTranslate"] as? Bool) ?? true
    }

    func testEveryKeyIsTranslatedInEveryLanguage() throws {
        for name in ["Localizable", "InfoPlist", "AppShortcuts"] {
            let strings = try catalog(name)
            for (key, entry) in strings where isTranslatable(entry) {
                for language in Self.languages {
                    XCTAssertNotNil(translation(entry, language),
                                    "\(name): '\(key)' missing \(language)")
                }
            }
        }
    }

    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let pattern = try NSRegularExpression(pattern: #"%(\d+\$)?(lld|@|d|ld|lu|f|s)"#)
        /// argument index → conversion. A bare specifier takes the next implicit position;
        /// `%2$lld` names its own. Comparing maps is what lets a substituted translation —
        /// which must use positional specifiers — validate against an implicitly-numbered key.
        func specifierMap(_ s: String) -> [Int: String] {
            var map: [Int: String] = [:]; var next = 1
            for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                let conversion = String(s[Range(m.range(at: 2), in: s)!])
                if m.range(at: 1).location != NSNotFound,
                   let n = Int(String(s[Range(m.range(at: 1), in: s)!]).dropLast()) { map[n] = conversion }
                else { map[next] = conversion; next += 1 }
            }
            return map
        }
        for name in ["Localizable", "InfoPlist", "AppShortcuts"] {
            for (key, entry) in try catalog(name) where isTranslatable(entry) {
                let source = specifierMap(key)
                for language in Self.languages {
                    for value in translations(entry, language) {
                        XCTAssertEqual(specifierMap(value), source,
                                       "\(name): '\(key)' \(language) placeholder drift")
                    }
                }
            }
        }
    }

    func testGlossaryTermsTranslateConsistently() throws {
        let glossaryURL = repoRoot().appendingPathComponent("docs/notes/lineform-glossary.json")
        let glossary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: glossaryURL)) as? [String: [String: String]])
        // Keys whose English is a whole glossary term used in a different sense may
        // be exempted here, with a comment saying why. Empty until proven needed.
        // Three keys use "write" as the ordinary verb, not as the name of Write mode. The
        // glossary rendering is a NOUN in every language ("Escritura", "Écriture",
        // "Schreiben", "執筆", "写作"), so forcing it in here would replace a natural verb
        // clause with the mode's label — "mientras escribes" would have to become
        // "durante la Escritura", and "Lineform no ha podido escribir" would claim the app
        // failed at the mode rather than at the file write. The mode itself is carried by
        // the "Write" and "Toggle Write / Read" keys, which are NOT exempt.
        let exemptions: Set<String> = [
            "Highlights the current line while you write.",
            "Keeps the current line centered as you write.",
            "Lineform couldn’t write “%@”. Choose a different location and try again.",
            // The VoiceOver label on the rendered text view. It describes what the user is
            // reading, and is never mapped back to a menu item the way a mode name is, so
            // German takes its natural compound "Markdown-Leseansicht" — the rule would have
            // forced the stiff "Markdown-Ansicht „Lesen“" for the sake of four literal
            // letters. The other four languages still carry the glossary term unforced.
            "Markdown read view",
        ]

        // Whole-word matching, not substring: "Tab" must not match "Table" and
        // "Read" must not match "Reading & Accessibility".
        func containsWholeWord(_ text: String, _ term: String) -> Bool {
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: term))\\b",
                options: .caseInsensitive) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        let strings = try catalog("Localizable")
        for (term, translations) in glossary {
            for (key, entry) in strings
            where isTranslatable(entry) && containsWholeWord(key, term) && !exemptions.contains(key) {
                for language in Self.languages {
                    guard let value = translation(entry, language),
                          let expected = translations[language] else { continue }
                    XCTAssertTrue(
                        value.localizedCaseInsensitiveContains(expected),
                        "'\(key)' \(language): expected glossary term '\(expected)' in '\(value)'")
                }
            }
        }
    }

    func testPluralCategoriesFollowEachLanguagesRules() throws {
        // es/fr/de need `one` AND `other`. ja/zh-Hans have no singular category at all —
        // an inherited `one` from a copy-paste is silently dead weight that never fires.
        let required: [String: Set<String>] = [
            "es": ["one", "other"], "fr": ["one", "other"], "de": ["one", "other"],
            "ja": ["other"], "zh-Hans": ["other"],
        ]
        for (key, entry) in try catalog("Localizable") where isTranslatable(entry) {
            guard let locs = entry["localizations"] as? [String: [String: Any]] else { continue }
            for (language, expected) in required {
                if let plural = (locs[language]?["variations"] as? [String: Any])?["plural"]
                    as? [String: [String: Any]] {
                    XCTAssertEqual(Set(plural.keys), expected, "'\(key)' \(language) plural categories")
                }
                // A multi-argument counted string keeps its plurals one level down, inside each
                // substitution variable. Without this the gate walks straight past exactly the
                // two keys it was written for: dropping `chars` back to a bare "%2$lld
                // caractères" would restore a sibling of the original French/Spanish defect
                // with every other gate still green.
                for (token, spec) in (locs[language]?["substitutions"] as? [String: [String: Any]] ?? [:]) {
                    guard let plural = (spec["variations"] as? [String: Any])?["plural"]
                            as? [String: [String: Any]] else {
                        // `XCTFail` returns Void, so `return XCTFail(…)` returned from the whole
                        // TEST — the first offending key silently ended the sweep and every key
                        // after it went unchecked.
                        XCTFail("'\(key)' \(language) substitution '\(token)' has no plural")
                        continue
                    }
                    XCTAssertEqual(Set(plural.keys), expected,
                                   "'\(key)' \(language) substitution '\(token)' plural categories")
                }
            }
        }
    }

    /// The shape of the two multi-argument counted strings, pinned by name. The gate above
    /// checks whatever variables it finds; this checks that the right variables EXIST, and
    /// that each one binds the argument it is named for — one per counted argument in the
    /// languages that inflect, none at all in the two that do not.
    ///
    /// Both of the mutations that motivated this are invisible to a gate that only inspects
    /// the variables already present and well-formed: DELETING one (collapsing back to a
    /// single variable) leaves nothing to iterate over, and SWAPPING their `argNum`s leaves
    /// two perfectly well-formed variables wired to each other's numbers.
    func testMultiArgumentCountedStringsVaryEveryArgumentIndependently() throws {
        let strings = try catalog("Localizable")
        for key in ["%lld words — %lld characters",
                    "Document contains %lld words and %lld characters"] {
            let entry = try XCTUnwrap(strings[key], "'\(key)' is no longer in the catalog")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]])

            for language in ["es", "fr", "de"] {
                let subs = try XCTUnwrap(locs[language]?["substitutions"] as? [String: [String: Any]],
                                         "'\(key)' \(language) lost its substitutions")
                XCTAssertEqual(Set(subs.values.compactMap { $0["argNum"] as? Int }), [1, 2],
                               "'\(key)' \(language) must vary BOTH counted arguments independently")
                // Which token binds WHICH argument, not merely that both indices are spoken
                // for. Swapping the two — names and text left in place — satisfies every
                // other check here and prints the character count beside "mot(s)" and the
                // word count beside "caractère(s)": the wrong number under the wrong noun,
                // worse than the inflection bug this whole round started from.
                XCTAssertEqual(subs["words"]?["argNum"] as? Int, 1,
                               "'\(key)' \(language) 'words' must bind argument 1")
                XCTAssertEqual(subs["chars"]?["argNum"] as? Int, 2,
                               "'\(key)' \(language) 'chars' must bind argument 2")
            }
            // ja and zh-Hans have no plural category, so a variable there would be a
            // single-branch indirection that never chooses anything.
            for language in ["ja", "zh-Hans"] {
                XCTAssertNil(locs[language]?["substitutions"],
                             "'\(key)' \(language) has no plural category to substitute on")
                XCTAssertNil(locs[language]?["variations"],
                             "'\(key)' \(language) has no plural category to vary on")
                XCTAssertNotNil((locs[language]?["stringUnit"] as? [String: Any])?["value"],
                                "'\(key)' \(language) must be a plain stringUnit")
            }
        }
    }
}
