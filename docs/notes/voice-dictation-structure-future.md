# Future idea: dictate Markdown *structure*, not just text

Status: **candidate, not scheduled.** Not V1 scope. Captured 2026-07-02.
This note is a placeholder to explore later, not a spec or a commitment. When we
return to it, treat the "Must research before building" list as gating — this is
a bigger interaction-design idea than it looks, and the hard part is UX, not code.

## The idea

As the user dictates (system Dictation, Wispr Flow, or any voice input), Lineform
recognizes spoken *structure* and lays it out as real Markdown — instead of
dumping a single block of prose the user then has to hand-format.

- "heading, Chapter Two" → `## Chapter Two`
- "bullet, buy milk" → `- buy milk`
- "numbered list" / "code block" / "new paragraph" → the corresponding structure

The goal is **usable structured output while speaking**, so Read mode, Preview
mode, and the Outline are immediately meaningful. This is a **writing +
accessibility** feature, on the writing side of the app — not an AI editor, and
explicitly **not** rewriting the user's words. The user's text is left verbatim;
only the *structure* is inferred, and the user can always edit afterward.

Why it's interesting: nobody does this in a Markdown editor today (see below), so
"the Markdown editor you can dictate structure into" is a distinctive, unclaimed
line — and it leans into the accessibility work the app already does
(OpenDyslexic, Atkinson Hyperlegible, contrast, reading experience).

## What exists today (so we know the gap is real)

- **Apple Dictation** does *inline* commands only — "new line," "new paragraph,"
  punctuation. It will **not** emit Markdown structure. Say "heading Chapter Two"
  and you get the literal words, not `## Chapter Two`.
- **Wispr Flow** is better at punctuation/tone but emits clean prose into whatever
  field has focus. It is Markdown-unaware — no `##`, no `-` bullets, no fences.

So "speak → Markdown structure forms" is a genuine gap. Confirm this is still
true at build time — dictation tools move fast.

## Key architectural insight (makes it source-independent)

**Parse the text *after* it lands, not the audio.** We can't tap Wispr's (or
Apple's) microphone — we only ever receive the text they type into the
`NSTextView`. A structure parser that watches the *incoming text stream* is
therefore automatically **source-independent**: Apple Dictation, Wispr, or any
future tool all just type text, and Lineform promotes structure the same way for
all of them. One mechanism, no dependency on any speech engine.

- **Deterministic, no AI (the 80%):** a spoken-command grammar over the received
  text stream → structure. This is squarely in the existing wheelhouse — the
  Outline heading parser, the Markdown formatting commands, and the TextKit
  bridge already exist; this is a new *input path* into machinery we have.
- **The genuinely hard part (design, not tech):** command vs. content
  disambiguation. Did "heading" mean *make an H2* or *type the word "heading"*?
  ("Write a heading about dogs" is ambiguous.) Getting the command grammar right
  — trigger words, pause handling, a modifier — *is* the feature. Wrong = rage;
  right = magic.

## The accessibility-editing question to answer first (user-raised)

Open question the user flagged and we did **not** resolve: how does someone edit
*by voice today* for accessibility — does correction/editing even exist, or is it
all one-way dictation?

- **Research macOS Voice Control** (Accessibility → Voice Control) specifically —
  it is distinct from Dictation and reportedly *does* support voice-driven
  selection, deletion, navigation, and correction. If so, the "editing gap" may
  be smaller than we assumed, and our correction UX should *compose* with Voice
  Control rather than reinvent it. Verify what it can actually do before
  designing anything.
- Regardless, a dead-simple **correction affordance** is load-bearing, not an
  afterthought: "no, that's not a header" → demote back to plain text, via one
  keystroke and/or a spoken "undo that." This is the accessibility safety net for
  when the command-grammar guesses wrong.

## Optional AI, later (not required for v1 of the idea)

Inferring structure the user did *not* explicitly announce — "that short line
before a paragraph was probably a heading." If ever added, it should be
**on-device only** (Apple's Foundation Models framework), **opt-in**, and
**additive** on top of the deterministic command grammar — never the core, and
never network/account (preserve local-first). Ship the deterministic version
first; it's already useful without any model.

## Must research before building

- Confirm the gap still holds: what do current Apple Dictation + Wispr Flow emit?
- **macOS Voice Control**: exact editing/correction capabilities; how our feature
  should compose with it rather than fight it.
- Command-grammar design: trigger words, pause detection, command-vs-content
  disambiguation, discoverability (how does a user learn the commands?).
- Correction UX: the "no, not a header" demote path (keystroke + spoken).
- Capture point: can we reliably observe the dictation text stream in the
  `NSTextView` well enough to promote structure without fighting autosave, live
  reload, syntax highlighting, or Writing Tools protection?
- Does this stay consistent with positioning? It's a *writing/accessibility* aid,
  not an AI rewriter — but "No AI inside" copy would need care if/when the
  optional inference layer lands. Decide framing before shipping public copy.
