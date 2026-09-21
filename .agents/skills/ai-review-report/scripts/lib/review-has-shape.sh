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
_rhs_stripped=""
_rhs_struct=""
_rhs_tail=""
_rhs_cleanup() {
  [ -n "$_rhs_own_src" ] && rm -f "$_rhs_own_src" 2>/dev/null
  [ -n "$_rhs_stripped" ] && rm -f "$_rhs_stripped" 2>/dev/null
  [ -n "$_rhs_struct" ] && rm -f "$_rhs_struct" 2>/dev/null
  [ -n "$_rhs_tail" ] && rm -f "$_rhs_tail" "$_rhs_tail".* 2>/dev/null
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

# Judge the PROSE, never the LADR-055 sidecar. The transport asks this
# predicate about the raw model output, sidecar included, while the chunk gate
# asks it after extract-findings-json.sh has stripped the sidecar — and a
# JSON block can carry priority wording, a `file:line` in an evidence string,
# even the words "Issues Found" in a title. So narration plus a sidecar passed
# here, spent the fallback, and was then rejected downstream with the secondary
# never run (review 5265814254, finding 2): the two gates disagreeing is the
# exact fault this shared predicate exists to prevent. The strip below follows
# the extractor's own rules (LADR-055/079) so both gates see identical text.
# The transport calls this predicate before extract-findings-json.sh has removed
# the structured sidecar. Validate the markdown view that the chunk gate will
# eventually see, not raw JSON whose values can contain priority wording and a
# file:line anchor. Use the extractor's delimiter rules: exact BEGIN, prefix END,
# the last complete pair, or a later unterminated JSON-looking block. Work on a
# temporary copy so a path supplied by the caller is never modified here.
_rhs_pair="$(awk \
  -v b='<!-- FINDINGS_JSON_BEGIN -->' \
  -v ep='<!-- FINDINGS_JSON_END' '
  { line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line) }
  line == b { cand = NR; candnext = ""; next }
  cand && index(line, ep) == 1 { bl = cand; el = NR; cand = 0; next }
  cand && candnext == "" && line != "" { candnext = line }
  END {
    if (cand && cand > bl && (candnext ~ /^```/ || candnext ~ /^[{[]/))
      print cand " 0"
    else if (bl)
      print bl " " el
  }
' "$_rhs_src" 2>/dev/null)"
if [ -n "$_rhs_pair" ]; then
  _rhs_begin="${_rhs_pair%% *}"
  _rhs_end="${_rhs_pair#* }"
  if [ "$_rhs_end" = "0" ]; then
    _rhs_end=$(( $(wc -l < "$_rhs_src") + 1 ))
  fi
  _rhs_stripped="$(mktemp)"
  if awk -v bl="$_rhs_begin" -v el="$_rhs_end" \
    'NR < bl || NR > el { print }' "$_rhs_src" > "$_rhs_stripped" 2>/dev/null; then
    _rhs_src="$_rhs_stripped"
  fi
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
  # A mention counts only in STRUCTURE: a heading line, or a line inside a
  # finding block (a severity-emoji or priority line and its continuation
  # lines — indented, list, bold-label, fenced or blank — up to the next
  # column-0 prose line, heading or block start). Narration is excluded:
  # "I will inspect src/b.cs next." named the file, satisfied the inventory,
  # and a response truncated right there passed as complete (review
  # 5266192686, finding 3).
  _rhs_struct="$(mktemp)"
  awk '
    { low = tolower($0) }
    /^#/ { print; inblk = 0; next }
    /🔴|🟠|🟡|🔵/ || (low ~ /(critical|high|medium|low)/ && low ~ /priority/) { print; inblk = 1; next }
    inblk && ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]+/ || $0 ~ /^[-*`|]/ || $0 ~ /^\*\*/) { print; next }
    { inblk = 0 }
  ' "$_rhs_src" > "$_rhs_struct" 2>/dev/null || cp "$_rhs_src" "$_rhs_struct"
  _rhs_mentioned() { # _rhs_mentioned <suffix>
    _rhs_esc="$(printf '%s' "$1" | sed 's/[][\.^$*+?{}|()]/\\&/g')"
    grep -qE "(^|[^[:alnum:]_.-])${_rhs_esc}([^[:alnum:]_.-]|$)" "$_rhs_struct"
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

# The `file:line` anchor regex, built ONCE. With an inventory, the path token
# must END in one of the chunk's files (basename, preceded by nothing or a
# path separator) — `HTTP:500`, `status:404` and `confidence:75` are
# `label:number` prose, not evidence, and the generic path rule accepted them
# (review 5266893822, finding 1). Without an inventory (ad-hoc callers) the
# token must contain a dot or a slash, which still excludes those labels;
# an extensionless `Dockerfile:12` is then accepted only through the
# inventory, which is how the gate always calls this predicate. Passed to awk
# through the environment, not -v, because -v processes backslash escapes and
# would strip the escaping the basenames need.
_rhs_anchor_re='[A-Za-z0-9_-]*[./][A-Za-z0-9_./-]*:[0-9]+'
if [ -n "${OPENCODE_EXPECTED_CHUNK_FILES:-}" ]; then
  _rhs_alt=""
  while IFS= read -r _rhs_p; do
    [ -n "$_rhs_p" ] || continue
    _rhs_b="$(basename "$_rhs_p" | sed 's/[][\.^$*+?{}|()]/\\&/g')"
    _rhs_alt="${_rhs_alt:+$_rhs_alt|}$_rhs_b"
  done <<EOF_ANCH
${OPENCODE_EXPECTED_CHUNK_FILES}
EOF_ANCH
  [ -z "$_rhs_alt" ] || _rhs_anchor_re="(^|[^A-Za-z0-9_.-])([A-Za-z0-9_./-]*/)?(${_rhs_alt}):[0-9]+"
fi
export RHS_ANCHOR_RE="$_rhs_anchor_re"

# Split into per-file sections and require EVERY section to be complete —
# not only the last one. The last-section rule caught a review truncated
# inside file B, but a heading for file A immediately followed by the heading
# for file B (no result at all for A) satisfied the inventory through the
# heading and was then judged only on B (review 5266762643, finding 1). The
# split is on `File:`/`Files:` headings (case-insensitive); text before the
# first such heading is a preamble, not a section; a body with no such heading
# is one section, which keeps LADR-077's acceptance of findings written without
# the template scaffolding. Section files are written beside the tail scratch
# file and removed with it.
_rhs_tail="$(mktemp)"
_rhs_nsec="$(awk -v base="$_rhs_tail" '
  { low = tolower($0) }
  low ~ /^#+[[:space:]].*files?:/ { n++; if (n > 1) close(base "." (n-1)) }
  n > 0 { print > (base "." n) }
  END { print n + 0 }
' "$_rhs_src" 2>/dev/null || echo 0)"
if [ "${_rhs_nsec:-0}" -eq 0 ]; then
  cp "$_rhs_src" "$_rhs_tail.1" 2>/dev/null; _rhs_nsec=1
fi

# Completion signals for ONE section. Exit 0 = complete.
_rhs_section_ok() { # _rhs_section_ok <section-file>
  _rhs_sec="$1"

  # The mandated placeholder for an empty severity section. Exempt from the
  # anchor requirement: a clean result has no finding, so it has no location to
  # cite. Scoped to the `Issues Found` SUBSECTION, not the whole section: the
  # template puts `**Pre-existing (informational):**` after it with its own
  # `- None found` placeholder, so an empty Issues Found followed by that
  # placeholder read as a clean review (review 5264530992, finding 1). The
  # subsection runs from the marker to the next bold `**Label:**` line or
  # heading; the inline form is on the marker line itself. Both placeholder
  # forms must END the line (an unfinished "None found so far, but…" is not a
  # placeholder — review 5264311874), and the list form is the DOCUMENTED
  # shapes only, never "any bullet ending in none found" (review 5266005570):
  # `- None found` or the per-severity `- 🔴 [VERIFIED] Critical: None found`,
  # the latter complete only when its LAST tier (Low) is present, because the
  # template emits the tiers in order and a cut after any earlier tier leaves
  # the rest unreviewed (review 5266682360). Emoji by alternation, never a
  # bracket expression (multi-byte).
  _rhs_issues="$(awk '
    { low = tolower($0) }
    low ~ /issues found/ { on = 1; print; next }
    on && ($0 ~ /^#/ || $0 ~ /^[[:space:]]*\*\*[^*]+\*\*/) { on = 0 }
    on { print }
  ' "$_rhs_sec" 2>/dev/null)"
  _rhs_ph_compact='^[[:space:]]*[-*][[:space:]]*none found[.]?[[:space:]]*$'
  _rhs_ph_tier='^[[:space:]]*[-*][[:space:]]*((🔴|🟠|🟡|🔵)[[:space:]]*)?(\[(VERIFIED|SPECULATIVE)\][[:space:]]*)?(critical|high|medium|low)( priority)?[[:space:]]*:[[:space:]]*none found[.]?[[:space:]]*$'
  _rhs_ph_low='^[[:space:]]*[-*][[:space:]]*((🔴|🟠|🟡|🔵)[[:space:]]*)?(\[(VERIFIED|SPECULATIVE)\][[:space:]]*)?low( priority)?[[:space:]]*:[[:space:]]*none found[.]?[[:space:]]*$'
  if [ -n "$_rhs_issues" ]; then
    if printf '%s\n' "$_rhs_issues" | grep -qiE "$_rhs_ph_compact" \
       || printf '%s\n' "$_rhs_issues" | grep -qiE 'issues found[^[:alnum:]]{0,8}none found[.]?[[:space:]]*$'; then
      return 0
    fi
    if printf '%s\n' "$_rhs_issues" | grep -qiE "$_rhs_ph_tier" \
       && printf '%s\n' "$_rhs_issues" | grep -qiE "$_rhs_ph_low"; then
      return 0
    fi
  fi

  # Anchor: `some/file.ext:123`, or an extensionless `Dockerfile:12` when the
  # inventory names it — see RHS_ANCHOR_RE above for what makes a token a
  # path rather than a clock reading, a ratio or a `label:number` (reviews
  # 5264629523 and 5266893822). Required for every finding-based
  # acceptance — and required INSIDE the finding, not anywhere in the section:
  # narration carrying a location followed by a finding truncated at its
  # severity label satisfied both signals when they were tested independently
  # (review 5264172516, finding 1). A finding is a block from a severity-emoji
  # or priority-wording line to the next such line or heading; continuation
  # lines need not be indented. Any anchored block accepts, not only the last:
  # an honest review may END with a location-less advisory, and the
  # chunk-threshold suite's honest-review control pins that shape. Severity
  # emoji are matched by alternation, never a bracket expression.
  _rhs_blocks="$(awk '
    function close_block() { if (kind != "" && blk ~ A) hit[kind] = 1; kind = ""; blk = "" }
    BEGIN { A = ENVIRON["RHS_ANCHOR_RE"] }
    {
      low = tolower($0)
      if ($0 ~ /^#/) { close_block(); next }
      if ($0 ~ /🔴|🟠|🟡|🔵/) { close_block(); kind = "e"; blk = $0; next }
      if (low ~ /(critical|high|medium|low)/ && low ~ /priority/) { close_block(); kind = "p"; blk = $0; next }
      if (kind != "") blk = blk "\n" $0
    }
    END { close_block(); printf "%s%s", (hit["e"] ? "e" : ""), (hit["p"] ? "p" : "") }
  ' "$_rhs_sec" 2>/dev/null)"
  case "$_rhs_blocks" in *e*) return 0;; esac
  # Priority wording additionally requires the mandated section marker. On its
  # own it matches ordinary prose, and prose can carry a location too — "check
  # the high priority areas in run-review.sh:1196" satisfied both signals while
  # containing no review. Narration does not emit `Issues Found`.
  case "$_rhs_blocks" in *p*) grep -qiF 'issues found' "$_rhs_sec" && return 0;; esac
  return 1
}

_rhs_i=1
while [ "$_rhs_i" -le "$_rhs_nsec" ]; do
  _rhs_section_ok "$_rhs_tail.$_rhs_i" || exit 1
  _rhs_i=$((_rhs_i + 1))
done
exit 0
