# Font License Review

Lineform uses native macOS fonts for SF Pro, New York, Monospaced, and Comic Sans MS. It also bundles selected open font files for reader accessibility and portability.

## Bundled Font Set

- Atkinson Hyperlegible, copyright 2020 Braille Institute of America, Inc.
- OpenDyslexic, copyright Abbie Gonzalez, with Reserved Font Name OpenDyslexic.

### Math rendering (SwiftMath)

Lineform renders LaTeX math via the SwiftMath Swift package (MIT, code copyright
Computer Inspirations). SwiftMath vendors a set of open math fonts inside its
`mathFonts.bundle`; Lineform uses Latin Modern Math by default. Their licenses:

- Latin Modern Math, TeX Gyre Termes — GUST Font License (a LaTeX Project Public
  License variant; free to use and redistribute).
- XITS Math, KpMath, and the other bundled math fonts — SIL Open Font License 1.1.

## License Files

The bundled font licenses are included in `Resources/Fonts`:

- `OFL-AtkinsonHyperlegible.txt`
- `OFL-OpenDyslexic.txt`
- `SwiftMath-LICENSE.txt` (MIT — the SwiftMath library code)
- `OFL-SwiftMathFonts.txt` (SIL OFL 1.1 — SwiftMath's OFL math fonts)
- `GUST-FontLicense.txt` (GUST Font License — Latin Modern Math / TeX Gyre Termes)

## Review Result

The bundled reader fonts are distributed under the SIL Open Font License 1.1. The
SwiftMath library is MIT-licensed and its bundled math fonts are covered by the SIL
Open Font License 1.1 and the GUST Font License — all free to bundle and
redistribute. New York, SF Pro, Monospaced, and Comic Sans MS remain system font
choices and are not bundled.
