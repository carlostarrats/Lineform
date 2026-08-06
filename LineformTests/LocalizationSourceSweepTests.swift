import XCTest
@testable import Lineform

/// The gate the other five did not cover.
///
/// `LocalizationCatalogTests` asserts that the CATALOG is internally consistent — every key
/// translated, specifiers matching, plurals shaped per language. All five pass with a display
/// string that never reached the catalog at all, which is how ~40 strings shipped English with
/// every gate green. This test scans the SOURCE instead and asks the opposite question: is any
/// user-facing literal still un-localized?
///
/// Two rules, because SwiftUI has two overloads:
///
/// * At a `LocalizedStringKey` position (`Text("…")`, `Button("…")`, `.help("…")`, …) a bare
///   literal genuinely localizes, so it only has to BE a catalog key.
/// * Anywhere else — a `String` constant, an `NSAlert.messageText`, an `NSTextField` label —
///   the literal is a plain `String`. `Button(someString)` then selects the VERBATIM overload,
///   so catalog membership buys nothing: `"Rename"`, `"Cancel"` and `"Delete"` were all catalog
///   keys and all still drew English. Those must be `String(localized:)` **at their definition
///   site**.
///
/// Modelled on `MainMenuIconDecoratorTests.testEveryLocalizedMenuTitleLiteralIsInAllEnglishTitleKeys`:
/// read the sources from the repo via `#filePath`, and fail loudly rather than vacuously if the
/// scan ever stops matching.
final class LocalizationSourceSweepTests: XCTestCase {

    // MARK: - Allowlist
    //
    // Every entry needs a one-line reason. An over-broad allowlist recreates exactly the hole
    // this test exists to close, so prefer localizing the string to exempting it.

    /// Files where no literal is ever drawn.
    private static let exemptFiles: [String: String] = [
        "SystemMenuItemTitles.swift":
            "Generated table OF Apple's translations, keyed by English; regenerate with packaging/extract-system-menu-titles.py. Lineform never draws these.",
        "MainMenuIconDecorator.swift":
            "Icon lookup tables — normalized English titles and their per-language aliases. The decorator only ever sets NSMenuItem.image; it writes no titles.",
        "LineformCommandLine.swift":
            "`lineform` CLI diagnostics printed to stderr in a shell, outside the app's localized UI.",
        "LineformAppIntents.swift":
            "Every literal is a LocalizedStringResource / IntentDescription / @Parameter title / AppShortcut phrase. Those types localize a bare literal by construction and extract into Localizable.xcstrings and AppShortcuts.xcstrings, where LocalizationCatalogTests covers them.",
    ]

    /// `File.swift|declaration` — whole declarations that are deliberately English.
    private static let exemptDeclarations: [String: String] = [
        "AppCommands.swift|allEnglishTitleKeys":
            "The decorator's English lookup keys. They must stay byte-identical to the English source strings, so localizing them would break title matching in every language.",
        "ReadingExperiencePopover.swift|visibleControlLabels":
            "An English-pinned inventory of the drawer's controls, asserted by ReadingProfileStoreTests. The labels actually drawn are separate String(localized:) constants.",
    ]

    /// Calls whose string argument is a programmer-facing diagnostic, never UI.
    private static let exemptCallees: [String: String] = [
        "fatalError": "Programmer-facing trap message.",
        "assert": "Programmer-facing assertion message.",
        "assertionFailure": "Programmer-facing assertion message.",
        "precondition": "Programmer-facing precondition message.",
        "preconditionFailure": "Programmer-facing precondition message.",
    ]

    /// `File.swift|literal` — individual literals that are not display copy.
    private static let exemptLiterals: [String: String] = [
        // Identifiers and paths.
        "AnnouncementFetcher.swift|Accept": "HTTP request header field name.",
        "OutlineSidebarView.swift|Lineform": "The app name — never translated (plan Global Constraints).",
        "OutlineSidebarView.swift|Documents": "The `Documents` path component of the iCloud container URL.",
        "BundledFontRegistrar.swift|Fonts": "Bundle subdirectory name.",
        "DiagramLog.swift|Library/Application Support": "File-system path component.",

        // Typeface names. Never translated (plan Global Constraints); only the descriptive
        // "Monospaced" label is, and it is String(localized:) in the same array.
        "FontOption.swift|SF Pro": "Typeface name.",
        "FontOption.swift|New York": "Typeface name.",
        "FontOption.swift|Atkinson Hyperlegible": "Typeface name.",
        "FontOption.swift|Comic Sans MS": "Typeface name.",

        // Document content, which the CLAUDE.md invariant forbids translating.
        "MarkdownBlockGrouping.swift|Note": "GitHub callout label — document content, stays in the document's language.",
        "MarkdownBlockGrouping.swift|Tip": "GitHub callout label — document content.",
        "MarkdownBlockGrouping.swift|Important": "GitHub callout label — document content.",
        "MarkdownBlockGrouping.swift|Warning": "GitHub callout label — document content.",
        "MarkdownBlockGrouping.swift|Caution": "GitHub callout label — document content.",
        "CodeHighlighting.swift|None": "Language keyword highlighted inside a code block — document content.",
        "CodeHighlighting.swift|True": "Language keyword highlighted inside a code block — document content.",
        "CodeHighlighting.swift|False": "Language keyword highlighted inside a code block — document content.",
        "MarkdownReference.swift|flowchart LR":
            "Mermaid diagram syntax shown as an example — document content, never localized.",
        "MarkdownReference.swift|Return":
            "A keycap legend rendered as code, like the ⌘ glyphs in the explanations.",

        // Persisted identity. ReadingProfile is Codable and its `name` is written into the
        // stored active profile, so display goes through the localized ReadingPreset.title.
        "ReadingPreset.swift|Paper": "ReadingProfile.name — persisted Codable identity; ReadingPreset.title is the display name.",
        "ReadingPreset.swift|Quiet": "ReadingProfile.name — persisted Codable identity.",
        "ReadingPreset.swift|Code": "ReadingProfile.name — persisted Codable identity.",
        "ReadingPreset.swift|Calm": "ReadingProfile.name — persisted Codable identity.",
        "ReadingPreset.swift|Focus": "ReadingProfile.name — persisted Codable identity.",
        "ReadingPreset.swift|Accessible": "ReadingProfile.name — persisted Codable identity (not a built-in preset; never drawn).",
        "ReadingPreset.swift|Dyslexia": "ReadingProfile.name — persisted Codable identity (not a built-in preset).",
        "ReadingPreset.swift|Low Light": "ReadingProfile.name — persisted Codable identity (not a built-in preset).",
        "ReadingPreset.swift|High Contrast": "ReadingProfile.name — persisted Codable identity (not a built-in preset).",
        "ReadingProfile.swift|Original": "ReadingProfile.name — persisted Codable identity.",

        // Types with no UI consumer today. Recorded by the 2026-08-05 final review: nothing
        // reads them, so translating them would be dead copy — but a future picker that wires
        // one up must localize it first.
        "ReadingProfile.swift|No Focus": "FocusMode.displayName has no UI consumer (final review 2026-08-05).",
        "ReadingProfile.swift|Current Line": "FocusMode.displayName has no UI consumer.",
        "ReadingProfile.swift|Current Sentence": "FocusMode.displayName has no UI consumer.",
        "ReadingProfile.swift|Current Paragraph": "FocusMode.displayName has no UI consumer.",
        "Theme.swift|Original": "Theme.name has no UI consumer; drawn theme names come from ReadingPreset.title.",
        "Theme.swift|Paper": "Theme.name has no UI consumer.",
        "Theme.swift|Calm": "Theme.name has no UI consumer.",
        "Theme.swift|Quiet": "Theme.name has no UI consumer.",
        "Theme.swift|Night": "Theme.name has no UI consumer.",
        "Theme.swift|High Contrast": "Theme.name has no UI consumer.",
        "ExportTypographyPreset.swift|Normal": "ExportTypographyPreset.displayName has no UI consumer.",
        "ExportTypographyPreset.swift|Styled": "ExportTypographyPreset.displayName has no UI consumer.",
        // `testTheNoUIConsumerClaimsAreStillTrue` is what keeps the ten entries above honest:
        // "nothing reads this" is the claim, and the literal-existence check cannot make it.

        // Diagnostics written to the on-disk diagram log, never shown.
        "MathRendering.swift|Math render produced no image": "Diagram-log diagnostic.",
        "MermaidRendering.swift|unsupported mermaid type": "Diagram-log diagnostic.",
        "MermaidRendering.swift|Pie render produced no image": "Diagram-log diagnostic.",
        "MermaidRendering.swift|Mermaid orientation pass could not allocate": "Diagram-log diagnostic.",
        "MermaidRendering.swift|Mermaid render produced no image": "Diagram-log diagnostic.",
    ]

    /// Positions where SwiftUI (or App Intents) reads a bare literal as a `LocalizedStringKey`.
    /// A literal here localizes on its own and only has to be in the catalog.
    private static let localizedStringKeyCallees: Set<String> = [
        "Text", "Button", "Label", "Toggle", "Picker", "TextField", "SecureField", "Link",
        "Menu", "Stepper", "Section", "alert", "confirmationDialog", "help", "searchable",
        "accessibilityLabel", "accessibilityHint", "accessibilityValue", "navigationTitle",
        "tabItem",
    ]

    // MARK: - The gate

    func testNoUserFacingLiteralEscapesTheCatalog() throws {
        let sources = try Self.swiftSources()
        XCTAssertGreaterThan(sources.count, 60, "the source sweep found almost no files — it has gone blind")

        let catalogKeys = try Self.catalogKeys()
        XCTAssertGreaterThan(catalogKeys.count, 200, "the catalog read back almost empty — the scan would pass vacuously")

        var scannedDisplayLiterals = 0
        var failures: [String] = []

        for source in sources {
            if Self.exemptFiles[source.name] != nil { continue }
            for literal in Self.literals(in: source.text) {
                guard Self.isDisplayCopy(literal.text) else { continue }
                if literal.isLocalized { scannedDisplayLiterals += 1; continue }
                if literal.isEnumRawValue { continue }
                if let callee = literal.callee, Self.exemptCallees[callee] != nil { continue }
                if let declaration = literal.declaration,
                   Self.exemptDeclarations["\(source.name)|\(declaration)"] != nil { continue }
                if Self.exemptLiterals["\(source.name)|\(literal.text)"] != nil { continue }

                scannedDisplayLiterals += 1
                let site = "\(source.name):\(literal.line)"
                if let callee = literal.callee, Self.localizedStringKeyCallees.contains(callee) {
                    // A LocalizedStringKey literal localizes on its own — but only if the
                    // catalog carries it. Interpolated ones extract under a `%@`/`%lld` key
                    // this scan cannot reconstruct exactly; the completeness gate covers those.
                    if literal.isInterpolated { continue }
                    if !catalogKeys.contains(literal.text) {
                        failures.append("\(site): \(callee)(\"\(literal.text)\") is not a key in Localizable.xcstrings")
                    }
                } else {
                    failures.append(
                        "\(site): \"\(literal.text)\" is user-facing but plain — wrap it in "
                            + "String(localized:) at its definition site, or add it to "
                            + "exemptLiterals with a reason (enclosing call: \(literal.callee ?? "none"))"
                    )
                }
            }
        }

        XCTAssertGreaterThan(scannedDisplayLiterals, 150,
                             "the display-copy filter matched almost nothing — the scan has gone blind")
        XCTAssertEqual(failures, [], "un-localized user-facing literals:\n" + failures.joined(separator: "\n"))
    }

    /// The allowlist is only honest if it stays live. An entry that no longer matches anything
    /// is a rule nobody is reading any more.
    func testEveryAllowlistEntryStillMatchesSomething() throws {
        let sources = try Self.swiftSources()
        let names = Set(sources.map(\.name))
        for file in Self.exemptFiles.keys {
            XCTAssertTrue(names.contains(file), "exemptFiles: \(file) no longer exists")
        }

        var seenLiterals: Set<String> = []
        var seenDeclarations: Set<String> = []
        for source in sources {
            for literal in Self.literals(in: source.text) where !literal.isLocalized {
                seenLiterals.insert("\(source.name)|\(literal.text)")
                if let declaration = literal.declaration {
                    seenDeclarations.insert("\(source.name)|\(declaration)")
                }
            }
        }
        for entry in Self.exemptLiterals.keys {
            XCTAssertTrue(seenLiterals.contains(entry), "exemptLiterals: \(entry) matches nothing — delete it")
        }
        for entry in Self.exemptDeclarations.keys {
            XCTAssertTrue(seenDeclarations.contains(entry), "exemptDeclarations: \(entry) matches nothing — delete it")
        }
    }

    /// Ten allowlist entries above rest on a claim `testEveryAllowlistEntryStillMatchesSomething`
    /// cannot make: that nothing READS these symbols into a display position. Someone writing
    /// `Text(Theme.name)` — the exact regression fixed in `ReadingExperiencePopover`, where
    /// `Text(preset.profile.name)` drew an untranslated theme name — would leave the sweep green,
    /// because the literal never moves.
    ///
    /// Receiver-qualified textual probes, so this stays cheap. Not airtight: binding the value to
    /// a local first (`let t = theme; Text(t.name)`) slips past. It catches the direct form, which
    /// is the form that actually gets written.
    func testTheNoUIConsumerClaimsAreStillTrue() throws {
        let probes: [(declaredIn: String, pattern: String, symbol: String, positiveControl: String)] = [
            ("ReadingProfile.swift", #"\bfocusMode\s*\.\s*displayName\b|\bFocusMode\.\w+\.displayName\b"#,
             "FocusMode.displayName", "Text(profile.focusMode.displayName)"),
            ("ExportTypographyPreset.swift", #"\b\w*[tT]ypographyPreset\s*\.\s*displayName\b|\bpreset\s*\.\s*displayName\b"#,
             "ExportTypographyPreset.displayName", "Text(typographyPreset.displayName)"),
            ("Theme.swift", #"\btheme\s*\.\s*name\b|\bTheme\.\w+\.name\b"#,
             "Theme.name", "Text(theme.name)"),
        ]
        let sources = try Self.swiftSources()
        for probe in probes {
            let regex = try NSRegularExpression(pattern: probe.pattern)
            func matches(_ text: String) -> Bool {
                regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
            // A typo'd pattern would match nothing and pass vacuously.
            XCTAssertTrue(matches(probe.positiveControl),
                          "\(probe.symbol): the probe does not match its own positive control")
            for source in sources where source.name != probe.declaredIn {
                XCTAssertFalse(
                    matches(source.text),
                    "\(source.name) now reads \(probe.symbol). Its allowlist entry says it has no UI "
                        + "consumer — either that is no longer true and the string must be localized, "
                        + "or the entry's reason needs rewriting."
                )
            }
        }
    }

    // MARK: - Scanning

    private struct Source {
        let name: String
        let text: String
    }

    private struct Literal {
        let text: String
        let line: Int
        let callee: String?
        let declaration: String?
        let isLocalized: Bool
        let isInterpolated: Bool
        let isEnumRawValue: Bool
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func swiftSources() throws -> [Source] {
        let root = repoRoot().appendingPathComponent("Lineform")
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate \(root.path)")
            return []
        }
        var out: [Source] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            out.append(Source(name: url.lastPathComponent, text: try String(contentsOf: url, encoding: .utf8)))
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func catalogKeys() throws -> Set<String> {
        let url = repoRoot().appendingPathComponent("Lineform/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let strings = json?["strings"] as? [String: Any] ?? [:]
        return Set(strings.keys)
    }

    /// A deliberately small Swift lexer: it has to skip comments and multi-line literals, and
    /// it has to know which call a literal sits inside. Regex alone cannot do either — a `//`
    /// inside a URL string and a `Text(cond ? "a" : "b")` both defeat it.
    private static func literals(in source: String) -> [Literal] {
        let chars = Array(source)
        var out: [Literal] = []

        struct Frame { let isCall: Bool; let callee: String?; let isLocalized: Bool }
        struct OpenString { let start: Int; var body: String; let depth: Int; var interpolated: Bool }

        var frames: [Frame] = []
        var strings: [OpenString] = []
        var declaration: String?
        var lastWords: [String] = []      // trailing identifiers, for `case x = "…"` detection
        var sawEquals = false
        var index = 0

        func identifier(endingAt end: Int) -> String? {
            var i = end - 1
            while i >= 0, chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" { i -= 1 }
            let last = i
            while i >= 0, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i -= 1 }
            guard i < last else { return nil }
            let name = String(chars[(i + 1)...last])
            return name.first?.isNumber == true ? nil : name
        }

        func matches(_ text: String, at i: Int) -> Bool {
            let end = i + text.count
            guard end <= chars.count else { return false }
            return String(chars[i..<end]) == text
        }

        while index < chars.count {
            let inString = !strings.isEmpty && frames.count == strings[strings.count - 1].depth
            if inString {
                let c = chars[index]
                if c == "\\" {
                    if index + 1 < chars.count, chars[index + 1] == "(" {
                        strings[strings.count - 1].body += "%@"
                        strings[strings.count - 1].interpolated = true
                        frames.append(Frame(isCall: true, callee: nil, isLocalized: false))
                        index += 2
                        continue
                    }
                    if index + 1 < chars.count {
                        let escape = chars[index + 1]
                        switch escape {
                        case "n": strings[strings.count - 1].body += "\n"
                        case "t": strings[strings.count - 1].body += "\t"
                        case "u":
                            // \u{XXXX}
                            var j = index + 3
                            var hex = ""
                            while j < chars.count, chars[j] != "}" { hex.append(chars[j]); j += 1 }
                            if let scalar = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(scalar) {
                                strings[strings.count - 1].body.append(Character(unicode))
                            }
                            index = j + 1
                            continue
                        default: strings[strings.count - 1].body.append(escape)
                        }
                        index += 2
                        continue
                    }
                }
                if c == "\"" {
                    let open = strings.removeLast()
                    let enclosing = frames.last(where: \.isCall)
                    out.append(Literal(
                        text: open.body,
                        line: source.prefix(open.start).filter { $0 == "\n" }.count + 1,
                        callee: enclosing?.callee,
                        declaration: declaration,
                        isLocalized: frames.contains(where: \.isLocalized),
                        isInterpolated: open.interpolated,
                        isEnumRawValue: lastWords.suffix(2).first == "case" && sawEquals
                    ))
                    index += 1
                    continue
                }
                if c == "\n" { strings.removeLast(); index += 1; continue }
                strings[strings.count - 1].body.append(c)
                index += 1
                continue
            }

            let c = chars[index]
            if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                var depth = 1
                index += 2
                while index < chars.count, depth > 0 {
                    if matches("/*", at: index) { depth += 1; index += 2 }
                    else if matches("*/", at: index) { depth -= 1; index += 2 }
                    else { index += 1 }
                }
                continue
            }
            if matches("\"\"\"", at: index) {
                index += 3
                while index < chars.count, !matches("\"\"\"", at: index) { index += 1 }
                index = min(index + 3, chars.count)
                continue
            }
            if c == "\"" {
                strings.append(OpenString(start: index, body: "", depth: frames.count, interpolated: false))
                index += 1
                continue
            }
            if c == "(" || c == "[" || c == "{" {
                let callee = c == "(" ? identifier(endingAt: index) : nil
                var isLocalized = false
                if c == "(", let callee {
                    if callee == "NSLocalizedString" || callee == "LocalizedStringResource" {
                        isLocalized = true
                    } else if callee == "String" || callee == "AttributedString" {
                        let tail = String(chars[(index + 1)..<min(index + 40, chars.count)])
                        isLocalized = tail.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("localized:")
                    }
                }
                frames.append(Frame(isCall: c == "(", callee: callee, isLocalized: isLocalized))
                index += 1
                continue
            }
            if c == ")" || c == "]" || c == "}" {
                if !frames.isEmpty { frames.removeLast() }
                index += 1
                continue
            }
            if c.isLetter || c == "_" {
                var word = ""
                while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
                    word.append(chars[index]); index += 1
                }
                if word == "let" || word == "var" {
                    if let name = { () -> String? in
                        var j = index
                        while j < chars.count, chars[j] == " " { j += 1 }
                        var n = ""
                        while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                            n.append(chars[j]); j += 1
                        }
                        return n.isEmpty ? nil : n
                    }() {
                        declaration = name
                    }
                }
                lastWords.append(word)
                if lastWords.count > 4 { lastWords.removeFirst() }
                sawEquals = false
                continue
            }
            if c == "=" { sawEquals = true }
            index += 1
        }
        return out
    }

    // MARK: - "Is this display copy?"

    /// Conservative on purpose: it must not need updating for every new identifier string, and
    /// it must not silently drop a real sentence. Anything it rejects is either not a word at
    /// all or is shaped like an identifier.
    ///
    /// **This is a strong default-deny check, not an airtight one.** Known blind spots, so the
    /// next reader knows the shape of what it cannot see rather than trusting a green run:
    ///
    /// * any character outside `alnum` + `` ,.'?!:;&()-/ `` + curly quotes/ellipsis — an em
    ///   dash, a straight `"` or `'`, a stray `%`. A hypothetical: a literal like `"Draft — do
    ///   not ship"` would pass through undetected because the em dash hides it from this filter,
    ///   and the sweep going green would NOT be evidence it was cleared.
    /// * hyphen/slash single tokens (`Auto-Save`), which the identifier-shape rule drops;
    /// * intercapped single words (`AutoFill`), dropped by the PascalCase rule;
    /// * lowercase-initial copy of fewer than three words (`selected`, `iCloud`);
    /// * `"""` multi-line literals, which the lexer skips outright;
    /// * enum `rawValue`s, skipped structurally — correct while the paired `title` is what gets
    ///   drawn, wrong the moment someone draws a `rawValue` directly.
    ///
    /// Widening it is a trade against false positives on the ~500 identifier-shaped literals it
    /// currently filters out; do that deliberately, not reflexively.
    static func isDisplayCopy(_ literal: String) -> Bool {
        var core = literal
        for placeholder in ["%lld", "%ld", "%@", "%d", "%f"] {
            core = core.replacingOccurrences(of: placeholder, with: " ")
        }
        core = core.replacingOccurrences(of: #"%\d+\$"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard core.count >= 2 else { return false }
        guard core.contains(where: { $0.isLowercase && $0.isASCII }) else { return false }

        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " ,.'?!:;&()-/\n\u{2019}\u{201C}\u{201D}\u{2026}"))
        guard core.unicodeScalars.allSatisfy(allowed.contains) else { return false }

        // `some.dotted.token`, `Some-Hyphenated-File.ttf`, `a/path/component`.
        if core.range(of: #"^[A-Za-z0-9]+([./\-][A-Za-z0-9]+)+$"#, options: .regularExpression) != nil {
            return false
        }
        if !core.contains(" ") {
            guard core.first?.isUppercase == true else { return false }
            // `camelCase` / `PascalCaseIdentifier` — real display words are not spelled that way.
            let isBareWord = core.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil
            if isBareWord, core.dropFirst().contains(where: { $0.isUppercase }) { return false }
        } else if core.first?.isUppercase != true,
                  !core.contains(where: { $0.isUppercase }),
                  core.split(separator: " ").count < 3 {
            return false
        }
        return true
    }
}
