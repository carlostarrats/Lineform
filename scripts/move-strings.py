#!/usr/bin/env python3
"""Move String Catalog entries from the app catalog to the LineformCore package catalog.

Usage:
    scripts/move-strings.py KEY_FILE
    scripts/move-strings.py --keep-in-app KEY_FILE
    scripts/move-strings.py --roundtrip-check CATALOG

KEY_FILE lists one catalog key per line, exactly as it appears in the catalog (the English
text). Blank lines are ignored. A key that contains a newline or a leading/trailing space can
be written as a JSON string literal on its own line, e.g. "Line one\\nLine two".

For every listed key the whole catalog entry -- every localization, comment, extraction state
and variation -- is copied into the package catalog and then removed from the app catalog.
With --keep-in-app the entry is copied but also left in the app catalog: use it for a key that
app code still uses ("a key still used by app code stays in the app catalog too").

The script fails loudly, and writes nothing, when a key is missing from the app catalog, when
an entry lacks any of en, es, fr, de, ja, zh-Hans, or when the package catalog already holds a
different entry under the same key. In this catalog many keys have no explicit "en"
localization because the key itself is the English text; a missing "en" is therefore treated
as satisfied by the key. The five other languages must be present.

Formatting is preserved as written: key order, 2-space indentation, the file's own
key/value separator (" : " as Xcode writes it, or ": "), Xcode's blank line inside empty
objects, raw (unescaped) non-ASCII text, and the file's trailing newline. Only the moved
entries change, so diffs stay minimal. Moved keys are appended to the package catalog in the
order they appear in the app catalog. --roundtrip-check parses CATALOG, rewrites it in memory
and exits non-zero unless the result is byte-identical to the file.

Standard library only.
"""

import argparse
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_CATALOG = os.path.join(REPO_ROOT, "Lineform", "Localizable.xcstrings")
PACKAGE_CATALOG = os.path.join(
    REPO_ROOT, "Packages", "LineformCore", "Sources", "LineformCore", "Resources", "Localizable.xcstrings"
)
REQUIRED_LANGUAGES = ["en", "es", "fr", "de", "ja", "zh-Hans"]


class Catalog:
    """A parsed .xcstrings file plus the formatting needed to write it back unchanged."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as handle:
            self.raw = handle.read()
        text = self.raw.decode("utf-8")
        self.data = json.loads(text, object_pairs_hook=dict)  # dicts keep file order
        self.separator = " : " if '" : ' in text else ": "
        self.trailing_newline = text.endswith("\n")

    def serialize(self):
        out = encode(self.data, 0, self.separator)
        if self.trailing_newline:
            out += "\n"
        return out.encode("utf-8")

    def write(self):
        data = self.serialize()
        temp = self.path + ".tmp"
        with open(temp, "wb") as handle:
            handle.write(data)
        os.replace(temp, self.path)


def encode(value, level, separator):
    """Pretty-print like Xcode: 2-space indent, empty containers hold a blank line."""
    indent = "  " * (level + 1)
    closing = "  " * level
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + closing + "}"
        items = [
            indent + encode_string(key) + separator + encode(item, level + 1, separator)
            for key, item in value.items()
        ]
        return "{\n" + ",\n".join(items) + "\n" + closing + "}"
    if isinstance(value, list):
        if not value:
            return "[\n\n" + closing + "]"
        items = [indent + encode(item, level + 1, separator) for item in value]
        return "[\n" + ",\n".join(items) + "\n" + closing + "]"
    if isinstance(value, str):
        return encode_string(value)
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    return json.dumps(value)


def encode_string(text):
    return json.dumps(text, ensure_ascii=False)


def read_keys(path):
    keys = []
    with open(path, "r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.rstrip("\r\n")
            if not line.strip():
                continue
            if line.startswith('"') and line.endswith('"') and len(line) >= 2:
                try:
                    line = json.loads(line)
                except json.JSONDecodeError as error:
                    sys.exit(f"error: {path}:{number}: not a valid JSON string literal: {error}")
            keys.append(line)
    if not keys:
        sys.exit(f"error: {path} lists no keys")
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        sys.exit("error: duplicate keys in key file:\n" + "\n".join(f"  {key!r}" for key in duplicates))
    return keys


def missing_languages(entry):
    localizations = entry.get("localizations", {})
    # The key is the English text, so an absent "en" localization is satisfied by the key.
    return [lang for lang in REQUIRED_LANGUAGES if lang != "en" and lang not in localizations]


def roundtrip_check(path):
    catalog = Catalog(path)
    if catalog.serialize() == catalog.raw:
        print(f"round-trip OK: {path} is byte-identical after parse + rewrite")
        return 0
    print(f"round-trip FAILED: {path} changes when rewritten", file=sys.stderr)
    return 1


def move(keys, keep_in_app, app_path, package_path):
    app = Catalog(app_path)
    package = Catalog(package_path)
    app_strings = app.data.get("strings")
    package_strings = package.data.setdefault("strings", {})
    if app_strings is None:
        sys.exit(f"error: {app_path} has no \"strings\" object")

    errors = []
    for key in keys:
        if key not in app_strings:
            errors.append(f"missing from app catalog: {key!r}")
            continue
        entry = app_strings[key]
        missing = missing_languages(entry)
        if missing:
            errors.append(f"{key!r} lacks localizations: {', '.join(missing)}")
        if key in package_strings and package_strings[key] != entry:
            errors.append(f"{key!r} already in the package catalog with different content")
    if errors:
        sys.exit("error: nothing was written.\n" + "\n".join("  " + line for line in errors))

    wanted = set(keys)
    for key in [k for k in app_strings if k in wanted]:  # app-catalog order
        package_strings[key] = app_strings[key]
        if not keep_in_app:
            del app_strings[key]

    package.write()
    if not keep_in_app:
        app.write()
    action = "copied (kept in app catalog)" if keep_in_app else "moved"
    shown = os.path.relpath(package_path, REPO_ROOT) if package_path.startswith(REPO_ROOT + os.sep) else package_path
    print(f"{action} {len(keys)} key(s) to {shown}")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n", 1)[0],
        epilog=__doc__.split("\n\n", 1)[1],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("key_file", nargs="?", metavar="KEY_FILE", help="file listing one key per line")
    parser.add_argument("--keep-in-app", action="store_true",
                        help="copy the entries but leave them in the app catalog too")
    parser.add_argument("--roundtrip-check", metavar="CATALOG",
                        help="verify CATALOG survives parse + rewrite byte-for-byte, then exit")
    parser.add_argument("--app-catalog", default=APP_CATALOG, help=argparse.SUPPRESS)
    parser.add_argument("--package-catalog", default=PACKAGE_CATALOG, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.roundtrip_check:
        return roundtrip_check(args.roundtrip_check)
    if not args.key_file:
        parser.error("KEY_FILE is required")
    return move(read_keys(args.key_file), args.keep_in_app, args.app_catalog, args.package_catalog)


if __name__ == "__main__":
    sys.exit(main())
