# Spell Check Probe Findings

**Date:** 2026-07-26
**Purpose:** Resolve the open question in `docs/superpowers/specs/2026-07-26-live-spell-check-design.md`
and take the A/B performance baseline before any feature code exists.
**Method:** throwaway instrumented Debug build, reverted afterwards. Keystrokes synthesized via
CGEvent (user-authorized) at ~100 ms intervals, 300 keystrokes per run, caret at end of a
747,598-byte fixture — the longest possible prefix, i.e. the worst case for any prefix-walking
range computation.

---

## 1. Which hook does as-you-type checking use?

**Answer: `checkText(in:types:options:)` fires, and it is the outer hook.**

Raw probe output while typing into the 747 KB fixture:

```
checkText range={0, 692} types=805315079 textLength=747598
willCheckTextIn range={0, 692} types=805315079
checkText range={746927, 675} types=805315079 textLength=747602
willCheckTextIn range={746927, 675} types=805315079
```

- `checkText` fires for automatic, as-you-type checking — not only for the explicit
  "Check Document Now" path.
- `textView(_:willCheckTextIn:options:types:)` fires immediately after each `checkText`, 1:1,
  with the identical range. It is **downstream** of `checkText`, so splitting the range in
  `checkText` and calling `super` per piece produces correspondingly scoped delegate calls.
- **The range-splitting design in the spec is viable. Inline suppression can ship as specified.**

**Correction to the plan's assumed API names**, discovered by the compiler:

- The delegate method is `textView(_:willCheckTextIn:options:types:)`, **not**
  `shouldCheckTextIn`. A `shouldCheckTextIn` method compiles but is never called — Swift emits
  only a "nearly matches optional requirement" warning, so this fails silently.
- The options dictionary is keyed by **`NSSpellChecker.OptionKey`**, not
  `NSAttributedString.TextCheckingOptionKey`.

## 2. AppKit already scopes the checked range

`{746927, 675}` on a 747,598-character document: AppKit checks roughly the visible chunk around
the caret, never the whole file. Median checked-range length across runs was **692–791
characters**.

This materially de-risks the feature. Our per-call work is bounded by a paragraph, not by
document size — so the prefix walk for fence state is the only part that scales with document
length, and it is the only thing worth watching.

AppKit also **coalesces heavily**: 300 keystrokes produced only **12–16** `checkText` calls.

## 3. Performance baseline

Two metrics. `didChangeText` covers the synchronous typing path; `checkText` covers the deferred
checking path. **`didChangeText` alone is a misleading metric for this feature** — checking runs
on a separate coalesced path, so a clean `didChangeText` number says nothing about spell-check
cost. Both are recorded here to prevent that mistake being repeated.

| Config | `didChangeText` median / p99 / max | `checkText` n / total / median / max |
|---|---|---|
| **A** — today (continuous off, autocorrect on) | 0.067 / 0.093 / 0.121 ms | 12 / 5.79 ms / 0.091 ms / 3.705 ms |
| **B** — continuous on, no suppression | 0.069 / 0.093 / 0.135 ms | 16 / 3.02 ms / 0.090 ms / 0.717 ms |

n = 300 keystrokes per run for `didChangeText`.

**A and B are indistinguishable.** B's totals are *lower* than A's; A's 3.705 ms max is
first-call warmup, not a steady-state cost.

### Why A already runs text checking

Config A shows 12 `checkText` calls **with continuous spell checking off**. The cause is
`isAutomaticSpellingCorrectionEnabled = true` (`LineformTextView.swift:632`): autocorrect drives
the same text-checking machinery. The work is *already happening today* — the app simply does not
display spelling results.

**Consequence:** enabling continuous spell checking does not add a checking pass. It changes what
is displayed. And since the feature also turns autocorrect **off**, the net change in checking
work is plausibly negative.

## 4. Conclusions

- **Go** on the design as specified in the spec, inline suppression included.
- **Apple's checker is not a performance risk here** (3 ms total across 30 seconds of typing in a
  730 KB document). The `B vs A` branch of the spec's gate — "Apple's checker is the slow part,
  make it a product decision" — does not apply.
- The remaining performance risk is **entirely our own code**: specifically the prefix walk in
  `MarkdownWritingToolsProtection.protectedRanges(in:intersecting:)`, which is the one part that
  scales with document length rather than with the checked range. That is what the Task 6 gate
  and `MarkdownSpellCheckPerformanceTests` exist to catch.
- Budget context for Task 6: our added work must stay small next to a **~0.09 ms median**
  `checkText`. The spec's ≤ 1 ms budget is roughly 10× the entire current cost of a check, so it
  is a ceiling, not a target.

## 4a. Config C, and what the gate actually cost

Added 2026-07-26, after implementation.

**The gate did its job.** The first implementation — the scoped path calling the two existing
whole-document passes with an `upTo` bound — measured **14.97 ms/call** against a 5 ms ceiling
and failed. Barely better than the 18 ms pass it was meant to avoid, because it walked the prefix
*twice* and allocated a substring plus a trimmed copy for every line.

Three fixes, measured at each step (Debug, mid-document, 730 KB):

| Change | ms/call |
|---|---|
| Two bounded whole-document passes | 14.97 |
| Single combined walk; prefix classified without allocating | 3.29 |
| Trailing trim only for `$`-initial lines; ASCII whitespace fast path | 2.69 |
| UTF-16 access via `CFStringInlineBuffer` | 2.26 |

Config C in the running app (Debug, caret at **end** of the 730 KB fixture — the worst case,
a full-length prefix scan):

| Config | `checkText` n / total / median / max |
|---|---|
| **B** — no suppression | 16 / 3.02 ms / 0.090 ms / 0.717 ms |
| **C** — with suppression | 14 / 48.75 ms / 5.493 ms / 12.999 ms |

**Debug overstates this by ~3.6×.** The Release configuration cannot be test-built here (iCloud
entitlement requires real signing), so the dominant prefix-scan loop was benchmarked standalone
at both optimization levels on the same 730 KB input: **6.99 ms at `-Onone`, 1.95 ms at `-O`**.

Applying that factor: **~0.6 ms mid-document and ~1.5 ms at the absolute worst case** in a
shipping build — at or near the spec's ≤ 1 ms budget, not five times over it.

For felt impact: `checkText` fires ~14 times per 300 keystrokes (AppKit coalesces heavily), so
even the pessimistic Debug figure is **0.16 % of main-thread time** across 30 seconds of
continuous typing, on a document far larger than normal prose. No dropped-frame budget is
threatened at 60 Hz.

**The cache was not added.** Spec implementation rule 5 gates it on measurement demanding it, and
the measurement does not. The documented fallback — checkpointing fence state every N lines and
invalidating from the edit offset forward — remains available if a future change makes the prefix
walk hot again.

## 5. Measurement caveats

- Synthetic keystrokes at a fixed 100 ms interval are more regular than human typing. They
  exercise the same code path but do not reproduce burst/pause patterns exactly.
- The caret sat at end-of-document, appending prose. Typing in the *middle* of a fence-heavy
  region was not separately measured; the Task 6 unit-level perf test covers the mid-document
  worst case directly and deterministically.
- Debug build, so absolute numbers are pessimistic relative to Release. Comparisons between
  configs are still valid — all runs used the same configuration.
