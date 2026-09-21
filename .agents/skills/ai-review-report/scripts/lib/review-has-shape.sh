#!/bin/bash
# review-has-shape.sh — does this text contain a COMPLETED chunk review?
#
# Usage:  review-has-shape.sh <file>     # or pipe the text on stdin
# Exit 0 = yes, 1 = no. Prints nothing.
# Optional env: OPENCODE_EXPECTED_CHUNK_FILES — newline-separated paths the
# chunk asked the model to review; with two or more, each must be mentioned.
#
# One predicate, two callers, on purpose. `review-in-chunks.sh` uses it to
# decide whether a chunk was reviewed at all (LADR-031 fail-closed), and
# `lib/opencode-with-fallback.sh` uses it — when a caller opts in via
# OPENCODE_OUTPUT_SHAPE_CHECK — to decide whether a short answer is a real
# review or a silent failure. They MUST agree: when the transport accepted
# something the chunk gate then rejected, the transport had already spent the
# LADR-002 fallback on it, so the secondary model never ran and the chunk
# fail-closed with rescue capacity unused. A single literal marker could not
# express this (the "None found." placeholder and a severity line are
# alternatives, and one of them is a regex), which is how the two drifted apart
# in the first place.
#
# The three clauses below are the completion signals the chunk prompt's output
# template guarantees: it mandates `**Issues Found:**` followed by either
# findings (severity emoji, or "… Priority" wording) or the literal
# "None found." placeholder. Deliberately NO heading-only clause — the heading
# is the template's FIRST line, so a response truncated right after it would
# match while containing no review, and an unreviewed chunk counted as clean is
# the one outcome this gate exists to prevent (LADR-087).
#
# Bash 3.2 safe: local-review.sh reaches both callers without a Bash >= 4 guard.
set -uo pipefail

# Clean up ONLY what this script created. `_rhs_src` is the CALLER's file when
# a path is passed — for `review-in-chunks.sh` that is `chunk_<n>.md` itself —
# so it must never be on the cleanup list. A one-line "fix" for the leaked
# stdin temp file (review 5261655825, finding 3) put `$_rhs_src` into the EXIT
# trap unconditionally, and every chunk review was deleted the moment the
# chunk gate finished validating it: the run log still said "✅ completed",
# aggregation then found no chunk files, and eval run 35535795942 reported
# INFRA on all 20 fixtures. Ownership is tracked in a separate variable, and
# `test-opencode-with-fallback-targets.sh` pins both directions (a passed file
# survives; a piped call leaves nothing behind).
_rhs_own_src=""
_rhs_tail=""
_rhs_cleanup() {
  [ -n "$_rhs_own_src" ] && rm -f "$_rhs_own_src" 2>/dev/null
  [ -n "$_rhs_tail" ] && rm -f "$_rhs_tail" 2>/dev/null
  return 0
}
trap _rhs_cleanup EXIT

_rhs_src="${1:-}"
if [ -n "$_rhs_src" ]; then
  [ -f "$_rhs_src" ] || exit 1
else
  _rhs_src="$(mktemp)"
  _rhs_own_src="$_rhs_src"
  cat > "$_rhs_src"
fi

# Completeness is decided by the LAST per-file section, then by two
# INDEPENDENT signals within it.
#
# Scope first, because a chunk is almost always MULTI-FILE and an earlier
# complete section says nothing about whether the model finished. A body that
# reports "None found." for file A and is then cut off part-way through file B
# is not a completed review of that chunk — but every earlier version of this
# predicate searched the whole body, so file A's result vouched for file B.
# Narrowing to the final section is what makes the signals mean "the model
# reached the end" rather than "the model started".
#
# Then two signals, because one marker is never enough. Four rounds of regex
# tuning each closed one truncation shape and the next round found a longer
# prefix, since the template emits its parts in order and every cut leaves a
# valid-looking prefix. The `file:line` anchor works because of WHERE it sits —
# at the end of a finding, after the description — so scaffolding cut short
# never reaches it, and the signals are orthogonal: narration can name a file,
# a truncated finding can carry a marker, neither produces both.
#
# Accepted cost, stated because it is a real fail-closed risk: a finding
# written with no `file:line` is rejected and takes the retry + fail-closed
# path. That shape is already off-contract — LADR-055 routes location-less
# items to `residual_risks`/`testing_gaps` — and fail-closed is the correct
# direction for a gate whose worst outcome is an unreviewed chunk counted clean.

# Omission, which scoping cannot see. The last-section rule catches a review
# cut off part-way through file B; it cannot catch a review that never
# mentions file B at all — file A's complete section is then the last one, and
# the chunk passes with a file unreviewed and no failure flag (review
# 5263305644, finding 2). So the caller may supply the chunk's file inventory
# in OPENCODE_EXPECTED_CHUNK_FILES (newline-separated paths), and every one
# must be MENTIONED somewhere in the body. Mentioned, not headed: a model that
# reviewed a file names it, in a heading or in a finding's `file:line`, while
# one that skipped it has no reason to. Matched on the basename, because the
# template's heading shows `filename` and models abbreviate the directory —
# requiring the full path would fail-close honest reviews. Applied only to
# chunks of two or more files: a single-file chunk keeps LADR-077's
# heading-free acceptance, where a `None found.` body need not name the file.
#
# Basename alone is not enough when two chunk files SHARE one — `src/api/index.ts`
# and `src/web/index.ts` — because a mention of either satisfies both, and the
# omitted one is counted reviewed (review 5263417133, finding 3). So the
# required mention is the SHORTEST trailing path that is unique among the
# expected files: `index.ts` when unique, `api/index.ts` when two collide,
# longer only if the parents collide too. That stays lenient for the common
# case and exact only where exactness is what disambiguates.
if [ -n "${OPENCODE_EXPECTED_CHUNK_FILES:-}" ]; then
  _rhs_expected_n=0
  _rhs_missing=""
  # Shortest unique suffix of <path> among all expected paths. Emits the
  # suffix on stdout.
  _rhs_unique_suffix() {
    _rhs_p="$1"; _rhs_suf="$(basename "$_rhs_p")"; _rhs_rest="$(dirname "$_rhs_p")"
    while :; do
      _rhs_clash=0
      while IFS= read -r _rhs_q; do
        [ -n "$_rhs_q" ] && [ "$_rhs_q" != "$_rhs_p" ] || continue
        case "$_rhs_q" in *"/$_rhs_suf"|"$_rhs_suf") _rhs_clash=1;; esac
      done <<EOF_ALL
${OPENCODE_EXPECTED_CHUNK_FILES}
EOF_ALL
      if [ "$_rhs_clash" -eq 0 ] || [ "$_rhs_rest" = "." ] || [ "$_rhs_rest" = "/" ] || [ -z "$_rhs_rest" ]; then
        printf '%s' "$_rhs_suf"; return 0
      fi
      _rhs_suf="$(basename "$_rhs_rest")/$_rhs_suf"; _rhs_rest="$(dirname "$_rhs_rest")"
    done
  }
  # A mention is the suffix as a whole token, not as a substring: `app.js`
  # must not be satisfied by `app.js.map` or `myapp.js` (review 5263727118,
  # finding 3). Path characters on either side disqualify; anything else —
  # a backtick, a colon before the line number, a space, end of line — is a
  # boundary. `/` before the suffix is allowed on purpose: `src/app.js` IS a
  # mention of `app.js`. Regex metacharacters in the suffix are escaped.
  _rhs_mentioned() { # _rhs_mentioned <suffix>
    _rhs_esc="$(printf '%s' "$1" | sed 's/[][\.^$*+?{}|()]/\\&/g')"
    grep -qE "(^|[^[:alnum:]_.-])${_rhs_esc}([^[:alnum:]_.-]|$)" "$_rhs_src"
  }
  while IFS= read -r _rhs_path; do
    [ -n "$_rhs_path" ] || continue
    _rhs_expected_n=$((_rhs_expected_n + 1))
    _rhs_mentioned "$(_rhs_unique_suffix "$_rhs_path")" || _rhs_missing="${_rhs_missing}${_rhs_path}
"
  done <<EOF_EXPECTED
${OPENCODE_EXPECTED_CHUNK_FILES}
EOF_EXPECTED
  if [ "$_rhs_expected_n" -ge 2 ] && [ -n "$_rhs_missing" ]; then
    exit 1
  fi
fi

# Narrow to the last per-file section. No heading at all means the whole body
# is the section, which keeps LADR-077's deliberate acceptance of findings
# written without the template scaffolding.
_rhs_tail="$(mktemp)"
awk '/^#+[[:space:]].*File:/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' \
  "$_rhs_src" > "$_rhs_tail" 2>/dev/null || cp "$_rhs_src" "$_rhs_tail"
[ -s "$_rhs_tail" ] || cp "$_rhs_src" "$_rhs_tail" 2>/dev/null

# The mandated placeholder for an empty severity section. Exempt from the
# anchor requirement: a clean result has no finding, so it has no location to
# cite. Scoped to the last section, so it can only vouch for itself.
#
# Not a bare substring, though. "none found" is ordinary prose — "checked the
# callers, none found so far, reading on" is narration, and a substring match
# accepted it as a completed clean review (review 5263305644, finding 1): the
# transport stopped the fallback and the chunk passed unreviewed, the exact
# hole the priority clause below had already been closed against. Two things
# must hold instead: the mandated `Issues Found` marker is present, and the
# placeholder is written AS the template writes it — a list item that ends in
# "None found" (`- None found.` or the per-severity
# `- 🔴 [VERIFIED] Critical: None found`), or inline after the marker
# (`**Issues Found:** None found.`). Narration emits neither shape. Both forms
# must END the line: the inline form was unanchored, so "**Issues Found:**
# None found so far, but let me still check…" — a placeholder with narration
# trailing off it, i.e. an unfinished response — was accepted (review
# 5264311874, finding 1). The list-item form already required line end.
if grep -qiF 'issues found' "$_rhs_tail"; then
  if grep -qiE '^[[:space:]]*[-*].*none found[.]?[[:space:]]*$' "$_rhs_tail" \
     || grep -qiE 'issues found[^[:alnum:]]{0,8}none found[.]?[[:space:]]*$' "$_rhs_tail"; then
    exit 0
  fi
fi

# Anchor: `some/file.ext:123`. Required for every finding-based acceptance —
# and required INSIDE the finding, not anywhere in the section. The two
# signals used to be tested independently over the whole tail, so narration
# carrying a location ("Reading auth.cs:12 next.") followed by a finding
# truncated at its severity label satisfied both and the cut-off review was
# accepted (review 5264172516, finding 1). A finding is a block: it starts at
# a line carrying a severity emoji or priority wording and runs to the next
# such line or a heading. Continuation lines are NOT required to be indented —
# models put the evidence line at column 0 often enough that demanding
# indentation would fail-close honest reviews — but nothing BEFORE the block's
# first line can vouch for it. Any anchored block accepts, not only the last
# one: a complete review may legitimately END with a location-less advisory
# ("an observation about naming in the same file") and the chunk-threshold
# suite's honest-review control pins exactly that shape. The residual gap —
# a complete finding followed by one truncated at its label — is the
# prefix-truncation family LADR-087(d) already accepts as unwinnable by
# inspection; closing it would fail-close honest reviews, which LADR-031
# makes the more expensive error.
#
# Severity emoji are matched by alternation, never a bracket expression: they
# are multi-byte and a bracket over them decomposes into bytes.
_rhs_blocks="$(awk '
  function close_block() { if (kind != "" && blk ~ A) hit[kind] = 1; kind = ""; blk = "" }
  BEGIN { A = "[A-Za-z0-9_./-]+[.][A-Za-z0-9]+:[0-9]+" }
  {
    low = tolower($0)
    if ($0 ~ /🔴|🟠|🟡|🔵/) { close_block(); kind = "e"; blk = $0; next }
    if (low ~ /(critical|high|medium|low)/ && low ~ /priority/) { close_block(); kind = "p"; blk = $0; next }
    if ($0 ~ /^#/) { close_block(); next }
    if (kind != "") blk = blk "\n" $0
  }
  END { close_block(); printf "%s%s", (hit["e"] ? "e" : ""), (hit["p"] ? "p" : "") }
' "$_rhs_tail" 2>/dev/null)"
case "$_rhs_blocks" in *e*) exit 0;; esac
# Priority wording additionally requires the mandated section marker. On its
# own it matches ordinary prose, and prose can carry a location too — "check
# the high priority areas in run-review.sh:1196" satisfied both signals while
# containing no review. Narration does not emit `Issues Found`.
case "$_rhs_blocks" in *p*) grep -qiF 'issues found' "$_rhs_tail" && exit 0;; esac
exit 1
