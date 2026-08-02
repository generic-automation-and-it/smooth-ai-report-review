#!/bin/bash
# filter-failing-test-findings.sh — withhold findings whose basis is a failing test.
#
# A failing test is a signal, not a defect. The autonomous fixer must not
# make a red test green by any route — including editing production code to
# satisfy a stale test. This filter removes such findings from the scope
# the model sees, so they cannot be acted on deterministically.
#
# stdin:  one severity section's text (the MEDIUM_SECTION / LOW_SECTION
#         strings the workflow already has).
# stdout: the same text with failing-test findings removed.
#
# Withheld findings are reported on stderr (human-readable) and, when a
# path is given as $1, also written to that file so the workflow can
# surface them in the summary comment.
#
# Matcher: case-insensitive, two tiers (see the regexes below).  A finding
# that merely contains the word "test" but carries no failure signature
# survives.  Prefer under-matching: a false withhold silently removes a real
# finding from the autonomous loop, which is the same class of harm this
# filter exists to prevent, so where unsure let it through and rely on the
# prompt rule (Layer 2).
set -euo pipefail

report_file="${1:-}"

# Tier 1 — signatures that name a test explicitly, or that no ordinary code
# review sentence produces. Sufficient on their own.
FAIL_RE_STRONG='(failing test|test fails|test failure|broken test|test is red|assertion failed|expected .+ but got)'

# Tier 2 — generic failure phrasings. These are ordinary code-review English
# and are NOT a failing-test signal on their own:
#
#   "resolve_provider does not pass the scope flag to the resolver"
#   "the retry loop is failing to back off between attempts"
#
# Both are real findings the fixer should see. Matching them on the bare
# phrase withheld them silently — the exact silent scope loss this filter is
# supposed to avoid. A tier-2 phrase only counts when the same line also
# names a test.
# `is red` sits here rather than tier 1 so it also catches "BazSpec is red on
# CI" and "the suite is red", not just the literal phrase "test is red".
FAIL_RE_WEAK="(is failing|are failing|does not pass|doesn't pass|fails to pass|is red|are red)"
# The tier-2 test word must be a word, not a substring: "the latest migration is
# failing" and "contest/attest/testify" are ordinary English that would otherwise
# withhold a real finding. Two alternations, because the boundary is asymmetric
# and CANNOT be expressed with `-i`:
#
#   1. `(^|[^A-Za-z])[Tt]est…`  — a word start (line start or a non-letter).
#   2. `[a-z](Test|Spec|…)`     — a CamelCase word start inside an identifier,
#      which is how test names actually appear: FooTests, IntegrationTest,
#      BazSpec. There is no non-letter before the capital, so alternation 1
#      cannot reach it.
#
# Alternation 2 needs the case distinction to tell `FooTests` (a test class)
# from `latest` (not), so this expression is matched CASE-SENSITIVELY — adding
# `-i` folds the two apart and re-admits every substring false positive above.
# The trailing `([^a-z]|$)` is the right-hand boundary: it keeps `Tests.` and
# `spec ` while rejecting `testify`.
TEST_WORD_RE='(^|[^A-Za-z])([Tt]est|[Ss]pec|[Ss]uite|[Ff]ixture)s?([^a-z]|$)|[a-z](Test|Spec|Suite|Fixture)s?([^a-z]|$)'

# Withhold when a tier-1 signature is present, or a tier-2 signature appears
# on a line that is actually about a test.
is_failing_test_finding() {
  local line="$1"
  printf '%s' "$line" | grep -qiE "$FAIL_RE_STRONG" && return 0
  if printf '%s' "$line" | grep -qiE "$FAIL_RE_WEAK"; then
    # No `-i` here — see TEST_WORD_RE above; the CamelCase leg depends on case.
    printf '%s' "$line" | grep -qE "$TEST_WORD_RE" && return 0
  fi
  return 1
}

# Read all input into a buffer so we can process bullet-by-bullet.
input="$(cat)"

# Empty input — clean no-op.
if [ -z "$input" ]; then
  exit 0
fi

# Process line by line, grouping each finding (its first line plus every
# continuation line) as a unit.
#
# A NEW finding starts at column 0 (or one space) with "- ". A line indented
# two or more spaces is a CONTINUATION, even when it also starts with "- ".
# That distinction is the whole ballgame here, because the section this filter
# reads is produced by render-findings-summary.sh, which emits:
#
#   - **#1** 🟡 [VERIFIED] Medium Priority: FooTests.Bar is failing — `a.cs:42`
#     - The assertion no longer matches the new return shape.
#
# The `why_it_matters` line is an INDENTED sub-bullet. Treating any "- " line
# as a new finding split that pair apart: the parent was withheld and its
# sub-bullet leaked into the model's scope as an orphan fragment — a
# nonsensical finding, carrying the very failing-test detail the parent was
# withheld for. Under-indented sub-bullets are the common case in this
# pipeline, not an edge case.
new_bullet_re='^[[:space:]]{0,1}- '
withheld=""
output=""
current_bullet=""
bullet_first_line=""

flush_bullet() {
  if [ -z "$current_bullet" ]; then
    return
  fi
  if is_failing_test_finding "$bullet_first_line"; then
    withheld+="$current_bullet"
  else
    output+="$current_bullet"
  fi
  current_bullet=""
  bullet_first_line=""
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
input_file="${scratch}/input"
printf '%s' "$input" > "$input_file"

while IFS= read -r line || [ -n "$line" ]; do
  if printf '%s' "$line" | grep -qE "$new_bullet_re"; then
    flush_bullet
    current_bullet="$line"$'\n'
    bullet_first_line="$line"
  else
    current_bullet+="$line"$'\n'
  fi
done < "$input_file"

flush_bullet

# Report withheld findings. The bullet count must use the SAME leading-
# whitespace tolerance as the bullet detector above, or an indented bullet is
# withheld but reported as zero.
if [ -n "$withheld" ]; then
  withheld_count="$(printf '%s' "$withheld" | grep -cE "$new_bullet_re" || true)"
  if [ -n "$report_file" ]; then
    printf '%s' "$withheld" > "$report_file"
    # Publish the canonical count alongside the report. The caller must NOT
    # re-derive it: the workflow originally counted the report with its own
    # `^[[:space:]]*- ` regex, which also matches indented sub-bullets, so a
    # normal finding (parent + `why_it_matters` sub-bullet) was announced as
    # two withheld findings while this script's own stderr said one. Two counts
    # for one run, from two copies of a regex that must agree — so there is now
    # one copy, and it lives here with the detector it has to match.
    printf '%s\n' "$withheld_count" > "${report_file}.count"
  fi
  printf '%s' "$withheld" >&2
  echo "Withheld ${withheld_count} failing-test finding(s) (failing test is a signal — human decision required)." >&2
fi

# Output filtered text to stdout.
printf '%s' "$output"