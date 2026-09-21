#!/usr/bin/env python3
"""Filter per-chunk context files by their declared scope.

stdin  : JSON {"chunk_files": [...], "candidates": [...], "mandatory": [...]}
stdout : the candidates that apply to this chunk, one path per line
stderr : one warning line per candidate whose frontmatter could not be parsed

Why this exists
---------------
`review-in-chunks.sh` used to force-include every dot-prefixed context path in
every chunk. That was written when "dot-prefixed" meant a handful of root-level
mandatory files. Once whole rule trees (`.github/instructions/**`,
`.agents/rules/**`) started arriving through the same channel, a five-file CI
workflow PR was handed eight backend rules it could not possibly need.

The rule files already declare their own scope, in the GitHub Copilot
convention the consuming repos use:

    applyTo: 'src/*.Infrastructure/Persistence/Migrations/**/*.cs'
    alwaysApply: false

so the fix is to read what they say rather than to guess from the path.

Fail-open, on purpose
---------------------
A candidate that declares nothing, or whose frontmatter will not parse, is
INCLUDED. Dropping a rule the model needed is silent and changes review
output; including one it did not need costs a path in a list. Those are not
symmetric, so every uncertain case resolves toward inclusion.
"""
import json
import re
import sys

SCOPE_KEYS = ("applyto", "globs", "paths")  # lowercased; applyTo wins, then globs, then paths


def split_patterns(entry: str):
    """Split a comma-separated scope entry, ignoring commas INSIDE braces.

    `applyTo: '**/*.{ts,tsx}'` is one pattern, not two. Splitting it blindly
    yielded `**/*.{ts` and `tsx}`, neither of which can ever match -- so the
    rule was dropped from every chunk while the filter reported success
    (review 5271520178, finding 2).
    """
    parts, buf, depth = [], [], 0
    for ch in entry:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
    parts.append("".join(buf))
    return [p.strip() for p in parts if p.strip()]


class UnsupportedGlob(Exception):
    """The pattern uses syntax this translator cannot represent faithfully."""


def glob_to_regex(pattern: str) -> str:
    """VS Code / Copilot glob semantics: ** spans directories, * does not.

    Brace alternation `{a,b}` and character classes `[abc]` / `[!abc]` are part
    of that syntax and were previously escaped into literals, which silently
    dropped every rule that used them. Anything still untranslatable raises
    UnsupportedGlob so the caller can fail OPEN -- a rule reaching a chunk that
    did not need it costs a path in a list; a rule silently not reaching one
    changes review output with no signal at all.
    """
    out, i, n = [], 0, len(pattern)
    depth = 0
    while i < n:
        c = pattern[i]
        if c == "*":
            if pattern.startswith("**/", i):
                out.append("(?:.*/)?")
                i += 3
                continue
            if pattern.startswith("**", i):
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "{":
            depth += 1
            out.append("(?:")
        elif c == "}":
            if depth == 0:
                raise UnsupportedGlob(pattern)
            depth -= 1
            out.append(")")
        elif c == "," and depth > 0:
            out.append("|")
        elif c == "[":
            j = i + 1
            if j < n and pattern[j] in "!^":
                j += 1
            if j < n and pattern[j] == "]":  # a literal ] as the first member
                j += 1
            while j < n and pattern[j] != "]":
                j += 1
            if j >= n:
                raise UnsupportedGlob(pattern)  # unterminated class
            body = pattern[i + 1:j]
            if body[:1] in ("!", "^"):
                body = "^" + body[1:]
            out.append("[" + body + "]")
            i = j + 1
            continue
        else:
            out.append(re.escape(c))
        i += 1
    if depth != 0:
        raise UnsupportedGlob(pattern)  # unbalanced brace
    return "^" + "".join(out) + "$"


def parse_frontmatter(path):
    """Return (scope_globs, always_apply, ok). ok=False means unparseable."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            first = fh.readline()
            if first.strip() != "---":
                return [], False, True  # no frontmatter is not an error
            body = []
            for line in fh:
                if line.strip() == "---":
                    break
                body.append(line)
            else:
                return [], False, False  # unterminated block
    except OSError:
        return [], False, False

    always, scopes = False, {}
    current_scope_key = None
    for raw in body:
        m = re.match(r"\s*([A-Za-z_]+)\s*:\s*(.*)$", raw)
        if m:
            key, val = m.group(1).lower(), m.group(2).strip()
            current_scope_key = None
            if key == "alwaysapply":
                always = val.strip("'\"").lower() == "true"
            elif key in SCOPE_KEYS:
                current_scope_key = key
                scopes.setdefault(key, [])
                if val:
                    scopes[key].append(val.strip("'\""))
            continue
        m = re.match(r"\s*-\s*(.+)$", raw)  # YAML list item under `paths:`
        if m and current_scope_key:
            scopes[current_scope_key].append(m.group(1).strip().strip("'\""))

    for key in SCOPE_KEYS:  # applyTo first, then globs, then paths
        if scopes.get(key):
            pats = []
            for entry in scopes[key]:
                pats.extend(split_patterns(entry))
            return pats, always, True
    return [], always, True


def main() -> int:
    data = json.load(sys.stdin)
    chunk_files = data.get("chunk_files", [])
    mandatory = set(data.get("mandatory", []))

    for cand in data.get("candidates", []):
        if cand in mandatory:
            print(cand)  # the consuming repo chose this one explicitly
            continue
        globs, always, ok = parse_frontmatter(cand)
        if not ok:
            print(f"  ⚠ Unreadable frontmatter, including anyway: {cand}", file=sys.stderr)
            print(cand)
            continue
        if always or not globs:
            print(cand)
            continue
        # Fail OPEN on a pattern this translator cannot represent, matching how
        # unreadable frontmatter is already handled. Dropping a rule the model
        # needed is silent and changes review output; including one it did not
        # need costs a path in a list. Those are not symmetric.
        try:
            rx = [re.compile(glob_to_regex(g)) for g in globs]
        except (UnsupportedGlob, re.error) as exc:
            print(f"  ⚠ Untranslatable scope glob ({exc}), including anyway: {cand}",
                  file=sys.stderr)
            print(cand)
            continue
        if any(r.match(f) for f in chunk_files for r in rx):
            print(cand)
    return 0


if __name__ == "__main__":
    sys.exit(main())
