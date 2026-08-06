#!/usr/bin/env python3
"""Extract Apple's own localized terminology from the macOS .loctable files.

Loctables key Chinese as zh_CN (not zh-Hans) and store plural rules as dicts;
plain-string values only are extracted. Values may contain non-breaking spaces —
they are preserved verbatim (Apple's es uses NBSP before numerals on purpose).
"""
import json, plistlib, subprocess, sys
from pathlib import Path

APPKIT = Path("/System/Library/Frameworks/AppKit.framework/Versions/C/Resources")
TABLES = ["MenuCommands", "Menus", "Document", "SavePanel", "Printing",
          "FindPanel", "Spelling", "TextSystem", "Toolbar", "Services",
          "WritingTools", "NSSpellChecker", "NSTextViewContextMenu"]
LANGS = {"es": "es", "fr": "fr", "de": "de", "ja": "ja", "zh_CN": "zh-Hans"}

def load(table):
    raw = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(APPKIT / f"{table}.loctable")],
        capture_output=True, check=True).stdout
    return json.loads(raw)

glossary = {}
for table in TABLES:
    path = APPKIT / f"{table}.loctable"
    if not path.exists():
        print(f"warning: {table}.loctable missing on this OS", file=sys.stderr)
        continue
    data = load(table)
    english = data.get("en", {})
    for key, en_value in english.items():
        if not isinstance(en_value, str):
            continue  # plural-rule dicts handled by the catalog, not the glossary
        entry = {}
        for loc_key, our_key in LANGS.items():
            value = data.get(loc_key, {}).get(key)
            if isinstance(value, str):
                entry[our_key] = value
        if len(entry) == len(LANGS):
            glossary.setdefault(en_value, entry)

out = Path(__file__).resolve().parent.parent / "docs/notes/apple-terminology-glossary.json"
out.write_text(json.dumps(glossary, ensure_ascii=False, indent=1, sort_keys=True))
print(f"{len(glossary)} terms -> {out}")
