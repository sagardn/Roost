#!/usr/bin/env python3
"""Keeps Roost's translations in step with English, and English with the code.

    python3 Tools/i18n.py          check: every language has exactly en.lproj's
                                   keys, and keeps each %0, %1 ... placeholder
    python3 Tools/i18n.py fix      rewrite every language in en.lproj's order,
                                   filling a missing key with the English text
                                   and dropping keys English no longer has
    python3 Tools/i18n.py scan     en.lproj against the code: every
                                   localized("...") has a key, and every key is
                                   still used

Each command exits non-zero when it finds a problem, which is what CI reads.

Standard library only, so CI needs nothing but a Python. There is no
`translate` command: translations are written and reviewed as text, not
generated on every run, so a run of this script never changes what a user
reads except through `fix`, and `fix` only ever copies English in.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRINGS_DIR = os.path.join(ROOT, "Roost", "Supporting Files")
SOURCE_DIRS = [os.path.join(ROOT, "Roost"), os.path.join(ROOT, "LaunchAtLogin")]
FILE_NAME = "Localizable.strings"

# One entry per line: "key" = "value";  -- the only shape these files use.
# Escaped quotes inside either side are allowed, and so is a trailing comment.
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*(?://.*)?$')
# The helper in Roost/UI/Localized.swift, and Foundation's, which is still
# legal to call. A literal first argument is a key the code asks for.
CALL = re.compile(r'\b(?:localized|NSLocalizedString)\(\s*"((?:[^"\\]|\\.)*)"')
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
PLACEHOLDER = re.compile(r"%\d+")


def read(path):
    """The entries of one .strings file, in file order, and any line that is
    neither an entry, a comment nor blank -- which is a mistake worth naming
    rather than skipping."""
    entries, junk = [], []
    in_block = False
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            stripped = line.strip()
            if in_block:
                in_block = "*/" not in stripped
                continue
            if stripped.startswith("/*"):
                in_block = "*/" not in stripped
                continue
            if not stripped or stripped.startswith("//"):
                continue
            match = ENTRY.match(line)
            if match:
                entries.append((match.group(1), match.group(2)))
            else:
                junk.append(number)
    return entries, junk


def languages():
    for name in sorted(os.listdir(STRINGS_DIR)):
        path = os.path.join(STRINGS_DIR, name, FILE_NAME)
        if name.endswith(".lproj") and os.path.isfile(path):
            yield name[: -len(".lproj")], path


def english():
    entries, junk = read(os.path.join(STRINGS_DIR, "en.lproj", FILE_NAME))
    if junk:
        sys.exit(f"en.lproj: unreadable line(s) {junk}")
    return entries


def check():
    reference = english()
    keys = [key for key, _ in reference]
    placeholders = {key: sorted(PLACEHOLDER.findall(value)) for key, value in reference}
    problems = 0
    count = 0

    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        print(f"en: duplicate keys {duplicates}")
        problems += 1

    for language, path in languages():
        if language == "en":
            continue
        count += 1
        entries, junk = read(path)
        found = dict(entries)
        missing = [key for key in keys if key not in found]
        extra = [key for key in found if key not in placeholders]
        # A translation that drops or invents a placeholder shows the user a
        # literal "%0" or loses the number it was meant to carry.
        broken = [key for key, value in entries
                  if key in placeholders
                  and sorted(PLACEHOLDER.findall(value)) != placeholders[key]]
        for label, items in (("unreadable lines", junk), ("missing", missing),
                             ("not in en", extra), ("placeholders differ", broken)):
            if items:
                print(f"{language}: {label}: {items}")
                problems += 1

    if problems:
        print(f"\n{problems} problem(s). `python3 Tools/i18n.py fix` repairs "
              "missing and extra keys; placeholders have to be fixed by hand.")
        return 1
    print(f"All {count} languages have the same {len(keys)} keys as en.lproj.")
    return 0


def escape(value):
    # Values are stored escaped already; only a bare newline needs care, and
    # the files never contain one.
    return value.replace("\n", "\\n")


def fix():
    reference = english()
    changed = 0
    for language, path in languages():
        if language == "en":
            continue
        entries, _ = read(path)
        found = dict(entries)
        with open(path, encoding="utf-8") as handle:
            header = []
            for line in handle:
                if ENTRY.match(line):
                    break
                header.append(line)
        lines = header + [f'"{key}" = "{escape(found.get(key, value))}";\n'
                          for key, value in reference]
        new = "".join(lines)
        with open(path, encoding="utf-8") as handle:
            old = handle.read()
        if new != old:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(new)
            changed += 1
            print(f"{language}: rewritten")
    print(f"{changed} file(s) changed.")
    return 0


def swift_files():
    for directory in SOURCE_DIRS:
        for folder, _, names in os.walk(directory):
            for name in names:
                if name.endswith(".swift"):
                    yield os.path.join(folder, name)


def scan():
    asked, literals = set(), set()
    for path in swift_files():
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        asked.update(CALL.findall(text))
        literals.update(LITERAL.findall(text))

    keys = {key for key, _ in english()}
    # A key passed through a variable -- localized(level.label) -- is still
    # used as long as the string it resolves to is written down somewhere,
    # so any literal in the source counts, not only localized()'s argument.
    # `asked` is added to it rather than assumed inside it: a call nested in
    # an interpolation -- "\(localized("hottest")) ..." -- sits inside the
    # outer literal's quotes, so LITERAL never sees it on its own.
    missing = sorted(asked - keys)
    unused = sorted(keys - literals - asked)

    print(f"{len(asked)} localized string(s) in the code, {len(keys)} key(s) in en.lproj.")
    if missing:
        print("\nAsked for by the code but not in en.lproj:")
        for key in missing:
            print(f"  {key}")
    if unused:
        print("\nIn en.lproj but used nowhere in the code:")
        for key in unused:
            print(f"  {key}")
    if missing or unused:
        return 1
    print("en.lproj and the code agree.")
    return 0


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    actions = {"check": check, "fix": fix, "scan": scan}
    if command not in actions:
        sys.exit(f"usage: {sys.argv[0]} [check|fix|scan]")
    sys.exit(actions[command]())
