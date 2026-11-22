import LineformCore
import UIKit

/// Spell check that skips code, and the Writing Tools protection.
///
/// - **The pass.** `SpellCheckPass` checks the prose of the visible window plus its margin,
///   `SpellCheckPass.typingDelay` (0.4 s) after the last edit and after a scroll, never per
///   keystroke and never while an input method is composing (`markedTextRange != nil`). The
///   language is the keyboard's primary language; when it has no `UITextChecker` dictionary (the
///   emoji keyboard), the first preferred language that has one. With none, nothing is checked.
/// - **Check Document Now.** One whole-document pass, on or off. With the switch off, its
///   underlines last until the next edit.
/// - **Drawn, never stored.** Each misspelling gets a 1.5 pt dotted red line under its glyphs,
///   stroked by a shape layer above the text from TextKit 1 line fragments. Nothing is written
///   to the text storage, so copy, paste and the saved file never see it. An edit that touches a
///   misspelling drops its underline at once; one after it shifts it.
/// - **Edit menu.** On a misspelling, `textView(_:editMenuForTextIn:suggestedActions:)` leads
///   with up to five `UITextChecker` guesses, then Learn Spelling (the system dictionary) and
///   Ignore Spelling (this document). A guess replaces the word through `applyRuleEdit`: one undo
///   step, and the delegate hears it, so autosave does too.
/// - **Writing Tools.** `writingToolsBehavior = .none` (set in `configureForMarkdownEditing`, as
///   the Mac does), and the delegate's `writingToolsIgnoredRangesIn` returns
///   `MarkdownWritingToolsProtection.ignoredRanges`, so the protection holds if it is ever on.
extension LineformTextView {
    // MARK: - Scheduling

    /// Settings › Check spelling while typing (`AppSettings.checksSpellingWhileTyping`). Turning
    /// it off cancels a pending pass and clears the underlines; turning it on schedules a pass.
    var checksSpellingWhileTyping: Bool {
        get { state.checksSpellingWhileTyping }
        set {
            guard newValue != state.checksSpellingWhileTyping else { return }
            state.checksSpellingWhileTyping = newValue
            if newValue {
                scheduleSpellCheck()
            } else {
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(spellCheckAfterDelay), object: nil)
                spellCheck.misspelledRanges = []
                redrawSpellingUnderlines()
            }
        }
    }

    /// Schedules a pass `SpellCheckPass.typingDelay` from now, replacing any pending one. Nothing
    /// while Check spelling while typing is off.
    func scheduleSpellCheck() {
        guard checksSpellingWhileTyping else { return }
        let selector = #selector(spellCheckAfterDelay)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
        perform(selector, with: nil, afterDelay: SpellCheckPass.typingDelay, inModes: [.common])
    }

    @objc private func spellCheckAfterDelay() {
        runSpellCheckPass()
    }

    /// Checks the visible window now. Returns false, and changes nothing, while an input method
    /// is composing; the edit that ends the composition schedules the next pass.
    @discardableResult
    func runSpellCheckPass() -> Bool {
        guard checksSpellingWhileTyping, markedTextRange == nil else { return false }
        guard let language = spellCheckLanguage else {
            spellCheck.misspelledRanges = []
            redrawSpellingUnderlines()
            return false
        }
        let text = textStorage.string as NSString
        let visible = visibleCharacterRange()
            ?? NSRange(location: min(selectedRange.location, text.length), length: 0)
        spellCheck.misspelledRanges = SpellCheckPass.misspelledRanges(
            in: textStorage.string, visible: visible, language: language, checker: spellCheck.checker
        )
        redrawSpellingUnderlines()
        return true
    }

    /// The Menu's Check Document Now: one pass over the prose of the WHOLE document, run whether
    /// or not Check spelling while typing is on, as the Mac's command is. Every misspelling is
    /// underlined, and the first one after the selection (wrapping to the top) is selected and
    /// scrolled into view. False, selecting nothing, when there is none, no dictionary, or an
    /// input method is composing.
    @discardableResult
    func checkDocumentNow() -> Bool {
        guard markedTextRange == nil, let language = spellCheckLanguage else { return false }
        let found = SpellCheckPass.misspelledRangesInWholeDocument(
            in: textStorage.string, language: language, checker: spellCheck.checker
        )
        spellCheck.misspelledRanges = found
        redrawSpellingUnderlines()
        let after = NSMaxRange(selectedRange)
        guard let target = found.first(where: { $0.location >= after }) ?? found.first else { return false }
        selectedRange = target
        scrollRangeToVisible(target)
        return true
    }

    /// The keyboard's primary language, else the first preferred language with a dictionary, as a
    /// `UITextChecker` language; nil when none has one.
    var spellCheckLanguage: String? {
        SpellCheckPass.language(primary: textInputMode?.primaryLanguage)
    }

    // MARK: - Edits

    func observeTextStorageForSpellCheck() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textStorageDidProcessEditingForSpellCheck(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textStorage
        )
    }

    /// Shifts or drops the underlines an edit moved or touched. With Check spelling while typing
    /// off, no pass keeps underlines current, so the ones Check Document Now drew are a one-off:
    /// the next edit clears them all. Runs inside the storage's `processEditing`, where layout
    /// must not be asked for, so the redraw waits for the next layout pass (this same frame).
    @objc private func textStorageDidProcessEditingForSpellCheck(_ notification: Notification) {
        let storage = textStorage
        if storage.editedMask.contains(.editedCharacters) {
            if checksSpellingWhileTyping {
                spellCheck.textDidChange(editedRange: storage.editedRange, changeInLength: storage.changeInLength)
            } else if !spellCheck.misspelledRanges.isEmpty {
                spellCheck.misspelledRanges = []
            }
        }
        setNeedsSpellingUnderlineRedraw()
    }

    // MARK: - Underlines

    func setNeedsSpellingUnderlineRedraw() {
        needsSpellingUnderlineRedraw = true
        setNeedsLayout()
    }

    /// Called from `layoutSubviews`.
    func redrawSpellingUnderlinesIfNeeded() {
        guard needsSpellingUnderlineRedraw else { return }
        redrawSpellingUnderlines()
    }

    /// Strokes every misspelling's underline: one dotted segment per line fragment, 2 pt below
    /// the baseline.
    func redrawSpellingUnderlines() {
        needsSpellingUnderlineRedraw = false
        let layer = spellingUnderlineLayer()
        let path = UIBezierPath()
        let length = textStorage.length
        for range in spellCheck.misspelledRanges where NSMaxRange(range) <= length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { [layoutManager, textContainerInset] fragment, _, container, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                guard part.length > 0 else { return }
                let box = layoutManager.boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + layoutManager.location(forGlyphAt: part.location).y
                let y = baseline + Self.spellingUnderlineOffset + textContainerInset.top
                path.move(to: CGPoint(x: box.minX + textContainerInset.left, y: y))
                path.addLine(to: CGPoint(x: box.maxX + textContainerInset.left, y: y))
            }
        }
        // The Original theme's page colour is dynamic: read it with this view's traits.
        var usesDarkChrome = false
        traitCollection.performAsCurrent { usesDarkChrome = Theme.theme(for: profile).usesDarkChrome }
        layer.strokeColor = Self.spellingUnderlineColor(usesDarkChrome: usesDarkChrome).cgColor
        layer.path = path.isEmpty ? nil : path.cgPath
    }

    /// `systemRed` for the page's own light or dark (`Theme.usesDarkChrome`), not the system
    /// appearance: a dark theme in Light Mode gets the dark red, a light theme in Dark Mode the
    /// light one.
    static func spellingUnderlineColor(usesDarkChrome: Bool) -> UIColor {
        UIColor.systemRed.resolvedColor(with: UITraitCollection(userInterfaceStyle: usesDarkChrome ? .dark : .light))
    }

    /// The underline's stroke: 1.5 pt, round dots every 3 pt.
    static let spellingUnderlineWidth: CGFloat = 1.5
    static let spellingUnderlineOffset: CGFloat = 2

    /// The shape layer that strokes the underlines: a sublayer above the text, in content
    /// coordinates, so it scrolls with it. A path, not a bitmap, so a tall document costs nothing.
    func spellingUnderlineLayer() -> CAShapeLayer {
        if let existing = spellingUnderlines { return existing }
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineWidth = Self.spellingUnderlineWidth
        layer.lineCap = .round
        layer.lineDashPattern = [0, 3]
        layer.contentsScale = traitCollection.displayScale
        self.layer.addSublayer(layer)
        spellingUnderlines = layer
        return layer
    }

    // MARK: - Edit menu

    /// The spelling group for the edit menu at `range`, or nil when it is not on a misspelling:
    /// up to five guesses, then Learn Spelling and Ignore Spelling.
    func spellingMenu(for range: NSRange) -> UIMenu? {
        guard markedTextRange == nil, let word = spellCheck.misspelledRange(at: range) else { return nil }
        let text = textStorage.string
        let ns = text as NSString
        guard NSMaxRange(word) <= ns.length else { return nil }
        let spelled = ns.substring(with: word)
        let language = spellCheckLanguage ?? "en"
        let guesses = (spellCheck.checker.guesses(forWordRange: word, in: text, language: language) ?? [])
            .prefix(SpellCheckPass.maximumGuesses)

        var children: [UIMenuElement] = guesses.map { guess in
            UIAction(title: guess) { [weak self] _ in
                self?.applySpellingGuess(guess, replacing: word, word: spelled)
            }
        }
        children.append(UIAction(title: Self.learnSpellingTitle) { [weak self] _ in
            self?.learnSpelling(spelled)
        })
        children.append(UIAction(title: Self.ignoreSpellingTitle) { [weak self] _ in
            self?.ignoreSpelling(spelled)
        })
        return UIMenu(title: "", options: .displayInline, children: children)
    }

    static let learnSpellingTitle = String(localized: "Learn Spelling")
    static let ignoreSpellingTitle = String(localized: "Ignore Spelling")

    /// Replaces the misspelled `word` at `range` with `guess`, as one undo step through the shared
    /// edit path. Does nothing if the text there is no longer `word`.
    @discardableResult
    func applySpellingGuess(_ guess: String, replacing range: NSRange, word: String) -> Bool {
        let ns = textStorage.string as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == word else { return false }
        return applyRuleEdit(replacing: range, with: guess)
    }

    /// Adds `word` to the system dictionary and drops its underlines.
    func learnSpelling(_ word: String) {
        UITextChecker.learnWord(word)
        spellCheck.forget(word, in: textStorage.string as NSString)
        redrawSpellingUnderlines()
    }

    /// Ignores `word` in this document and drops its underlines.
    func ignoreSpelling(_ word: String) {
        spellCheck.checker.ignoreWord(word)
        spellCheck.forget(word, in: textStorage.string as NSString)
        redrawSpellingUnderlines()
    }

    // MARK: - Writing Tools

    /// The Markdown regions Writing Tools must leave alone (fenced code, front matter, …), the
    /// Mac's `writingToolsIgnoredRanges(in:)`. Never on the spell-check path: it is whole-document.
    func writingToolsIgnoredRanges(in enclosingRange: NSRange) -> [NSValue] {
        MarkdownWritingToolsProtection
            .ignoredRanges(in: textStorage.string, enclosingRange: enclosingRange)
            .map { NSValue(range: $0) }
    }
}
