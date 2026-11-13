#!/usr/bin/env python3
"""Zero-dependency YAML subset linter (offline, for this project).

Why: the server does yaml.safe_load(rules/*.yaml) at import time; one bad
indent and it refuses to boot. CI has the real parser, but on a box without
PyYAML and without network we still want the low-level mistakes caught.

Supported subset: block mappings, block sequences, plain/single/double quoted
scalars, literal (|) and folded (>) block scalars, full-line comments.

Checks: tab characters, indentation not a multiple of 2, duplicate sibling
keys (full path scoped), unterminated quotes, empty key.

Usage: python yamlcheck.py server/rules/bloomberg.yaml ios/project.yml ...
Exit code 0 = all clean.
"""
from __future__ import annotations

import re
import sys


def check(path: str):
    errs = []
    try:
        text = open(path, encoding="utf-8").read()
    except Exception as e:
        return ["cannot read: %s" % e], 0

    lines = text.split("\n")
    # stack of (indent, label); label "<item@Lx>" marks a sequence item scope
    stack = [(-1, "<root>")]
    seen = {}
    block_indent = None
    keys = 0

    def scope() -> str:
        return "/".join(lbl for _, lbl in stack[1:])

    for i, raw in enumerate(lines, 1):
        if "\t" in raw:
            errs.append("L%d: tab character (illegal in YAML)" % i)
        line = raw.rstrip()
        if not line.strip():
            continue

        # inside a block scalar: everything more indented is data
        if block_indent is not None:
            ind = len(line) - len(line.lstrip(" "))
            if ind > block_indent:
                continue
            block_indent = None

        stripped = line.lstrip(" ")
        ind = len(line) - len(stripped)
        if ind % 2:
            errs.append("L%d: indent not a multiple of 2 (got %d)" % (i, ind))
        if stripped.startswith("#"):
            continue

        while len(stack) > 1 and ind <= stack[-1][0]:
            stack.pop()

        content = stripped
        if content == "-" or content.startswith("- "):
            content = content[1:].strip()
            stack.append((ind, "<item@L%d>" % i))   # fresh scope per item
            if not content:
                continue

        # "key: |" or "key: >" -> following deeper lines are a block scalar
        if re.match(r"^[^\s#'\"][^:]*:\s*[|>][+-]?\s*$", content):
            keys += 1
            block_indent = ind
            stack.append((ind, content.partition(":")[0].strip()))
            continue

        # a quoted scalar item ("80:80") must not be parsed as a mapping
        if content[0] in ("'", '"'):
            for q in ('"', "'"):
                if content.count(q) % 2:
                    errs.append("L%d: unterminated quote: %s" % (i, content[:48]))
            continue

        if ":" in content:
            key, _, val = content.partition(":")
            key = key.strip()
            val = val.strip()
            if not key:
                errs.append("L%d: empty key" % i)
                continue
            sig = (scope(), key)
            if sig in seen:
                errs.append('L%d: duplicate key "%s" (first at L%d)'
                            % (i, key, seen[sig]))
            seen[sig] = i
            keys += 1
            for q in ('"', "'"):
                if val.count(q) % 2:
                    errs.append("L%d: unterminated quote: %s" % (i, val[:48]))
            stack.append((ind, key))
        else:
            for q in ('"', "'"):
                if content.count(q) % 2:
                    errs.append("L%d: unterminated quote: %s" % (i, content[:48]))

    return errs, keys


def main(argv):
    if not argv:
        print("usage: python yamlcheck.py <file.yaml> [more ...]")
        return 2
    bad = 0
    for p in argv:
        errs, keys = check(p)
        if errs:
            bad += 1
            print("[FAIL] %s  (keys=%d)" % (p, keys))
            for e in errs:
                print("        - " + e)
        else:
            print("[ok]   %s  (keys=%d)" % (p, keys))
    print("\nresult: %d/%d passed" % (len(argv) - bad, len(argv)))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
