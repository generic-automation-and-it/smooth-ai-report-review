#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/lib/opencode-with-fallback.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "${tmp_dir}/opencode" <<'STUB'
#!/bin/bash
# stdin handling is out of scope for this target-formatting test
cat >/dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      printf '%s\n' "$2" >> "${OPENCODE_STUB_MODELS_LOG}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'ok\n'
STUB
chmod +x "${tmp_dir}/opencode"

prompt="${tmp_dir}/prompt.md"
printf 'prompt\n' > "$prompt"

run_case() {
  local name="$1" provider="$2" expected="$3" model="$4"
  : > "${tmp_dir}/${name}.models"
  PATH="${tmp_dir}:$PATH" \
    OPENCODE_STUB_MODELS_LOG="${tmp_dir}/${name}.models" \
    OPENCODE_REVIEW_REPORT_PROVIDER_ID="$provider" \
    OPENCODE_MIN_OUTPUT_BYTES=1 \
    bash "$HELPER" "$model" "" "" -- "$prompt" >/dev/null
  actual="$(cat "${tmp_dir}/${name}.models")"
  [ "$actual" = "$expected" ] || {
    echo "FAIL: $name expected '$expected' but got '$actual'" >&2
    exit 1
  }
}

run_case bare_model openai 'openai/gpt-5.5' 'gpt-5.5'
run_case qualified_model go-anthropic 'go-openai/kimi-k2.7-code' 'go-openai/kimi-k2.7-code'
run_case responses_qualified go-openai 'go-responses/gpt-5.6-luna' 'go-responses/gpt-5.6-luna'
run_case openrouter_bare openrouter 'openrouter/deepseek/deepseek-v4-pro' 'deepseek/deepseek-v4-pro'
# Analyse path: job pre-prefixes the target; must not be re-prefixed with the review provider.
run_case analyse_path openai 'go-anthropic/minimax-m3' 'go-anthropic/minimax-m3'

# --- The shape predicate beats the byte floor (LADR-087) --------------------
# A correct review of a clean file is short. The 200-byte floor was calibrated
# against v1, which leaked chain-of-thought onto stdout; v2 routes it to
# stderr, so valid reviews started falling under the floor and being re-asked
# from every model in the chain. OPENCODE_OUTPUT_SHAPE_CHECK lets a caller
# supply the predicate that decides; unset, every call site keeps the pure floor.
SHAPE="${SCRIPT_DIR}/lib/review-has-shape.sh"
marker_dir="${tmp_dir}/marker"
mkdir -p "${marker_dir}/bin"

stub_emitting() { # stub_emitting <body-printf-format>
  cat > "${marker_dir}/bin/opencode" <<STUB
#!/bin/bash
cat >/dev/null
printf 'call\\n' >> "\$OPENCODE_STUB_CALLS"
printf '%s' "$1"
STUB
  chmod +x "${marker_dir}/bin/opencode"
}

shape_case() { # shape_case <label> <shape-check-path>
  : > "${marker_dir}/$1.calls"
  PATH="${marker_dir}/bin:$PATH" \
    OPENCODE_STUB_CALLS="${marker_dir}/$1.calls" \
    OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai \
    OPENCODE_OUTPUT_SHAPE_CHECK="$2" \
    bash "$HELPER" m1 m2 m3 -- "$prompt" > "${marker_dir}/$1.out" 2>/dev/null
  echo "$?:$(wc -l < "${marker_dir}/$1.calls" | tr -d ' ')"
}

CLEAN='### 📄 File: `src/Ftp/FtpHelper.cs`

**Issues Found:**
- None found.
'
stub_emitting "$CLEAN"

# Unchanged when no predicate is supplied: rejected, whole chain burned. This
# pins that the feature is additive, so the summary / semantic-grouping /
# analyse callers cannot be affected by it.
actual="$(shape_case no_check "")"
[ "$actual" = "1:3" ] || {
  echo "FAIL: without a shape check a short answer must still be rejected after trying every model (got '$actual')" >&2
  exit 1
}
echo "✓ no shape check: short output still rejected, chain still exhausted (unchanged)"

actual="$(shape_case with_check "$SHAPE")"
[ "$actual" = "0:1" ] || {
  echo "FAIL: a short but complete review must be accepted on the first model (got '$actual')" >&2
  exit 1
}
echo "✓ shape check passes: short complete review accepted, no fallback burned"

# Finding 2. A response truncated right after the `**Issues Found:**` marker is
# NOT a review. Accepting it here would SPEND the LADR-002 fallback — the
# secondary never runs — and the chunk gate would then fail-close it anyway,
# with rescue capacity available and unused. It must fall through instead.
stub_emitting '### 📄 File: `src/Ftp/FtpHelper.cs`

**Issues Found:**
'
actual="$(shape_case truncated_marker "$SHAPE")"
[ "$actual" = "1:3" ] || {
  echo "FAIL: a response truncated after the Issues Found marker must fall through to the fallback chain (got '$actual')" >&2
  exit 1
}
echo "✓ marker-only truncation falls through to the fallback instead of consuming it"

# The template's opening heading alone must not rescue it either.
stub_emitting '### 📄 File: `src/Ftp/FtpHelper.cs`
'
actual="$(shape_case truncated_heading "$SHAPE")"
[ "$actual" = "1:3" ] || {
  echo "FAIL: a response truncated after the file heading must not be accepted (got '$actual')" >&2
  exit 1
}
echo "✓ heading-only truncation is rejected, not mistaken for a clean review"

# Finding 1 of review 5261655825. The predicate must be AUTHORITATIVE, not an
# exemption from the byte floor. The first cut consulted it only for short
# output, so a narration-only answer of >= 200 bytes still passed here: the
# transport said "done" and spent the LADR-002 fallback on it, and the chunk
# gate then rejected the very same bytes and fail-closed with the secondary
# never run. Long narration must fall through the whole chain exactly like
# short narration does.
LONG_NARRATION='I will begin by loading the mandatory review standards and the project context files, then read the changed source and its callers, and check the high priority areas before writing the review. Let me start with the standards document and continue from there once I have the full picture of the change.
'
[ "${#LONG_NARRATION}" -ge 200 ] || { echo "FAIL: test fixture must exceed the 200-byte floor (got ${#LONG_NARRATION})" >&2; exit 1; }
stub_emitting "$LONG_NARRATION"
actual="$(shape_case long_narration_checked "$SHAPE")"
[ "$actual" = "1:3" ] || {
  echo "FAIL: narration above the byte floor must still be rejected by the shape predicate and exhaust the chain (got '$actual')" >&2
  exit 1
}
echo "✓ shape check fails: long narration is rejected, not accepted for being long"

# And the same bytes with NO predicate keep the pure byte floor — this is the
# additivity guarantee for the summary / semantic-grouping / trivial-PR /
# analyse callers, pinned from the long side as well as the short one.
actual="$(shape_case long_narration_unchecked "")"
[ "$actual" = "0:1" ] || {
  echo "FAIL: without a shape check, output above the floor must be accepted on the first model exactly as before (got '$actual')" >&2
  exit 1
}
echo "✓ no shape check: long output still accepted by the byte floor (unchanged)"

# A predicate path that is set but missing is a packaging fault, not a reason
# to reject every model in the chain: warn, then degrade to the byte floor.
actual="$(shape_case missing_predicate "${marker_dir}/does-not-exist.sh")"
[ "$actual" = "0:1" ] || {
  echo "FAIL: a set-but-missing predicate must degrade to the byte floor (got '$actual')" >&2
  exit 1
}
echo "✓ missing predicate path degrades to the byte floor instead of failing closed"

# The predicate is invoked through bash, so a copy-install that lost the exec
# bit cannot silently disable it (the chunk gate calls it the same way).
cp "$SHAPE" "${marker_dir}/shape-noexec.sh"; chmod -x "${marker_dir}/shape-noexec.sh"
stub_emitting "$CLEAN"
actual="$(shape_case noexec_predicate "${marker_dir}/shape-noexec.sh")"
[ "$actual" = "0:1" ] || {
  echo "FAIL: a non-executable predicate must still run via bash (got '$actual')" >&2
  exit 1
}
echo "✓ predicate without an exec bit still runs"

# Finding 3 of review 5261655825, and the regression its first fix caused. The
# helper must clean up ONLY the temp file it created for piped input. When a
# path is passed, that path is the CALLER's file — for the chunk gate it is
# chunk_<n>.md itself — and an EXIT trap that removed it deleted every chunk
# review right after validating it: the log still said "completed", the
# aggregation found no chunk files, and eval run 35535795942 reported INFRA on
# all 20 fixtures. Both directions are pinned: a passed file survives, and a
# piped call leaves nothing behind in TMPDIR.
owned_tmp="${marker_dir}/tmpdir"; mkdir -p "$owned_tmp"
printf '%s' "$CLEAN" > "${marker_dir}/callers-chunk.md"
TMPDIR="$owned_tmp" bash "$SHAPE" "${marker_dir}/callers-chunk.md" || {
  echo "FAIL: the clean fixture must satisfy the predicate when passed as a path" >&2
  exit 1
}
[ -f "${marker_dir}/callers-chunk.md" ] || {
  echo "FAIL: the predicate deleted the caller's file when given a path" >&2
  exit 1
}
[ -z "$(ls -A "$owned_tmp")" ] || {
  echo "FAIL: path mode leaked a temp file: $(ls -A "$owned_tmp")" >&2
  exit 1
}
printf '%s' "$CLEAN" | TMPDIR="$owned_tmp" bash "$SHAPE" || {
  echo "FAIL: the clean fixture must satisfy the predicate when piped" >&2
  exit 1
}
[ -z "$(ls -A "$owned_tmp")" ] || {
  echo "FAIL: stdin mode leaked a temp file: $(ls -A "$owned_tmp")" >&2
  exit 1
}
printf 'narration only\n' | TMPDIR="$owned_tmp" bash "$SHAPE" && {
  echo "FAIL: narration must be rejected" >&2
  exit 1
}
[ -z "$(ls -A "$owned_tmp")" ] || {
  echo "FAIL: a rejecting stdin call leaked a temp file: $(ls -A "$owned_tmp")" >&2
  exit 1
}
echo "✓ predicate cleans up only its own temp files; a passed chunk file survives"

# Both gates must ask the SAME question, or the gap this closed reopens.
grep -q 'lib/review-has-shape.sh' "${SCRIPT_DIR}/review-in-chunks.sh" || {
  echo "FAIL: review-in-chunks.sh no longer delegates to the shared shape predicate" >&2
  exit 1
}
[ "$(grep -c 'OPENCODE_OUTPUT_SHAPE_CHECK=' "${SCRIPT_DIR}/review-in-chunks.sh")" = "2" ] || {
  echo "FAIL: both chunk-review invocations must supply the shape check" >&2
  exit 1
}
echo "✓ both chunk-review call sites use the same predicate as the chunk gate"

# --- The predicate itself, directly (LADR-087) ------------------------------
# Unit-tested here rather than only through the gate, because the gate-level
# shape cases live in test-review-chunk-threshold.sh, which aborts early on
# this repo's known-red assertion and therefore never reaches them.
#
# The clause that matters is priority wording: it matches ORDINARY PROSE, so
# narration satisfied it while containing no review, and the chunk was
# aggregated as clean with zero findings. It now requires the mandated section
# marker to co-occur. Emoji and the "None found." placeholder stay standalone —
# narration emits neither, and LADR-077 chose a generous matcher on purpose
# because the flag forces REQUEST_CHANGES and a false positive blocks an
# honest PR.
predicate_case() { # predicate_case <expected accept|reject> <label> <body>
  local want="$1" label="$2" body="$3" got
  if printf '%b' "$body" | bash "$SHAPE"; then got=accept; else got=reject; fi
  [ "$got" = "$want" ] || {
    echo "FAIL: shape predicate should $want '$label' but returned $got" >&2
    exit 1
  }
}

predicate_case reject "narration mentioning a priority" \
  'Let me check the high priority areas before reviewing.\n'
predicate_case reject "narration mentioning several severities" \
  'I will look for critical priority and medium priority problems next.\n'
predicate_case accept "prose findings WITH the mandated section marker" \
  '**Issues Found:**\n- High Priority: the token is logged in plaintext at auth.cs:12.\n'
predicate_case accept "emoji findings without any heading (LADR-077)" \
  '\xf0\x9f\x9f\xa1 stale link in the doc header, alpha/a.txt:1 — retarget it.\n'
predicate_case accept "the mandated empty-section placeholder" \
  '**Issues Found:**\n- None found.\n'
predicate_case reject "the section marker alone (truncated)" \
  '**Issues Found:**\n'
# A marker is not a finding. `grep -qF` on the emoji character asked "is this
# byte present", not "did the model write a review", so a response truncated at
# the marker passed and an unreviewed chunk would be aggregated with no
# failed-coverage signal. Every clause was audited against truncation this
# time, not only the one that was reported.
predicate_case reject "a bare severity emoji with no newline" \
  '\xf0\x9f\x94\xb4'
predicate_case reject "a list marker and emoji, then nothing" \
  '- \xf0\x9f\x9f\xa0\n'
predicate_case reject "an emoji followed only by punctuation" \
  '- \xf0\x9f\x9f\xa0 :\n'
predicate_case accept "an emoji followed by actual finding text" \
  '- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: token logged at auth.cs:12\n'

# The family four rounds of regex tuning could not close: the template emits
# its parts in order, so every truncation point leaves a valid-looking prefix.
# The anchor closes it because of WHERE it sits — at the END of the finding,
# after the description — so a response cut off in the scaffolding never
# reaches it.
predicate_case reject "truncated at the severity label" \
  '- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority:'
predicate_case reject "truncated mid-tag" \
  '- \xf0\x9f\x9f\xa0 [VERIF'
predicate_case reject "section header plus a truncated finding" \
  '**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority:'
# The two signals are orthogonal, which is the point: narration can name a file
# and a truncated finding can carry a marker, but neither produces both.
predicate_case reject "narration that happens to name a file and line" \
  'Reading run-review.sh:1196 next.\n'
predicate_case reject "an anchor with no severity marker at all" \
  'The file auth.cs:12 was examined.\n'
# Review 5264629523, finding 2: the anchor is a PATH token followed by a line
# number, and a path need not have an extension. Requiring one rejected every
# complete finding on Dockerfile / Makefile / LICENSE as incomplete and
# fail-closed the chunk. What makes the token a path is a letter or a slash —
# a clock reading or a ratio has neither, and must not count.
predicate_case accept "a finding anchored on an extensionless file" \
  '**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: image runs as root — Dockerfile:12\n'
predicate_case accept "a finding anchored on an extensionless file in a directory" \
  '**Issues Found:**\n- \xf0\x9f\x9f\xa1 [VERIFIED] Medium Priority: phony target missing at build/Makefile:4\n'
predicate_case reject "a clock reading is not an anchor" \
  '**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: the job at 12:30 failed'
predicate_case reject "a ratio is not an anchor" \
  '**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: a 3:1 fan-out'
# Review 5265814254, finding 2: the LADR-055 sidecar is not evidence of a
# completed review. The transport sees the raw output (sidecar included) while
# the chunk gate sees it stripped, so a JSON block carrying priority wording,
# a file:line in an evidence string and even the words "Issues Found" let
# narration pass the transport, spend the fallback, and fail downstream. The
# predicate strips every sentinel range first, so both gates judge the prose.
SIDECAR='<!-- FINDINGS_JSON_BEGIN -->\n{"findings":[{"severity":"high","title":"Issues Found: High Priority token leak","file":"src/auth.cs","line":12,"evidence":"src/auth.cs:12 -- log.Info(token)"}]}\n<!-- FINDINGS_JSON_END -->\n'
predicate_case reject "narration followed by a complete sidecar" \
  "Let me read the handler and its callers before writing anything.\n${SIDECAR}"
predicate_case reject "narration, an unterminated sidecar" \
  'Reading the handler next.\n<!-- FINDINGS_JSON_BEGIN -->\n{"findings":[{"title":"Issues Found: High Priority x","evidence":"src/auth.cs:12"}]}'
predicate_case accept "a real review followed by its sidecar" \
  "**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: token logged at src/auth.cs:12\n\n${SIDECAR}"
predicate_case accept "a clean review followed by its sidecar" \
  "### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:**\n- None found.\n\n<!-- FINDINGS_JSON_BEGIN -->\n{\"findings\":[]}\n<!-- FINDINGS_JSON_END -->\n"
echo "✓ shape predicate: the findings sidecar is stripped before judging"

# Completeness is scoped to the LAST per-file section. A chunk is almost always
# multi-file, and an earlier complete section says nothing about whether the
# model finished — every earlier version searched the whole body, so file A's
# "None found." vouched for a file B that was never reviewed.
predicate_case reject "multi-file, truncated after the first file's result" \
  '### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60b.cs\x60\n\n**Issues Found:**\n'
predicate_case reject "multi-file, truncated mid-finding in the last file" \
  '### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:**\n- \xf0\x9f\x9f\xa0 x at a.cs:1\n\n### \xf0\x9f\x93\x84 File: \x60b.cs\x60\n\n**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority:'
predicate_case accept "multi-file, every section complete" \
  '### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60b.cs\x60\n\n**Issues Found:**\n- \xf0\x9f\x9f\xa0 token logged at b.cs:12\n'
# The CONJUNCTION, which is what the two-signal rule actually accepts. Both
# halves were tested separately and passed; the combination never was.
predicate_case reject "narration carrying a priority AND a location" \
  'Let me check the high priority areas in run-review.sh:1196 before reviewing.\n'
# Review 5264172516, finding 1: the two signals must come from the SAME
# finding. Narration with a location, then a finding cut off at its severity
# label, satisfied both when they were tested independently over the section.
predicate_case reject "narration anchor plus a truncated emoji finding" \
  '**Issues Found:**\nReading auth.cs:12 next.\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority:'
predicate_case reject "narration anchor plus a truncated priority-wording finding" \
  '**Issues Found:**\nReading auth.cs:12 next.\n- High Priority:'
# Any anchored finding accepts, not only the last: an honest review may end
# with a location-less advisory, and the chunk-threshold suite's honest-review
# control is exactly that shape. Fail-closing it blocks a clean PR (LADR-031).
predicate_case accept "an anchored finding followed by a location-less advisory" \
  '### Review\n\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: real finding with a location — `alpha/a.txt:1`.\n- \xf0\x9f\x94\xb5 [SPECULATIVE] Low Priority: an observation about naming in the same file.\n'
predicate_case accept "narration before a complete finding is harmless" \
  '**Issues Found:**\nReading auth.cs:12 next.\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: token logged at auth.cs:12\n'
predicate_case accept "anchor on an indented evidence line of the finding" \
  '**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: token logged in plaintext.\n  - Evidence: `src/auth.cs:12 -- log.Info(token)`\n'
predicate_case accept "anchor on an unindented continuation line of the finding" \
  '**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: token logged in plaintext.\n**Evidence:** `src/auth.cs:12`\n'
# The "None found." clause keeps a bare literal ON PURPOSE: there the marker IS
# the content — it is the complete statement the template asks for when there
# is nothing to report — and a response cut off inside it does not match.
predicate_case reject "a truncated None found placeholder" \
  '**Issues Found:**\n- None fou'
predicate_case reject "empty output" ''
# Review 5263305644, finding 1. "none found" is ordinary prose, and a bare
# substring match accepted narration as a completed clean review — the
# transport stopped the fallback and the chunk passed unreviewed. The
# placeholder must now sit under the mandated marker AND be written as the
# template writes it: a list item ending in "None found", or inline after the
# marker. Every real shape the chunk reviews emit is pinned as accepted.
predicate_case reject "narration that says none found" \
  'Checked the callers; none found so far, reading run-review.sh next.\n'
predicate_case reject "prose carrying both phrases" \
  'No issues found in the callers, none found so far.\n'
predicate_case reject "none found list item with no Issues Found marker" \
  '- None found.\n'
predicate_case accept "per-severity placeholders under the marker" \
  '### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:**\n- \xf0\x9f\x94\xb4 [VERIFIED] Critical: None found\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: None found\n'
predicate_case accept "inline placeholder after the marker" \
  '### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:** None found.\n\n**Pre-existing (informational):** None.\n'
predicate_case accept "placeholder with a trailing period" \
  '**Issues Found:**\n- None found.\n'
# Review 5264311874, finding 1: the inline placeholder must end the line, like
# the list-item form already did. Narration trailing off it is an unfinished
# response, not a clean review.
predicate_case reject "inline placeholder with narration trailing after it" \
  '### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:** None found so far, but let me still check the callers in b.cs before'
predicate_case reject "list placeholder with narration trailing after it" \
  '**Issues Found:**\n- None found yet, continuing to read the handler'
predicate_case accept "inline placeholder followed by the pre-existing section" \
  '### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:** None found.\n\n**Pre-existing (informational):** None.\n'
# Review 5264530992, finding 1: the placeholder must sit INSIDE the Issues
# Found subsection. The template's Pre-existing section carries its own
# "None found", and an empty Issues Found followed by it is not a clean review.
predicate_case reject "empty Issues Found vouched for by the Pre-existing placeholder" \
  '### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:**\n\n**Pre-existing (informational):**\n- None found\n'
predicate_case reject "Issues Found truncated, Pre-existing placeholder from an earlier draft" \
  '**Issues Found:**\n**Pre-existing (informational):** None found.\n'
predicate_case accept "list placeholder under Issues Found, then Pre-existing placeholder" \
  '### \xf0\x9f\x93\x84 File: \x60a.cs\x60\n\n**Issues Found:**\n- None found.\n\n**Pre-existing (informational):**\n- None found\n'
predicate_case accept "per-severity placeholders under Issues Found, then Pre-existing" \
  '**Issues Found:**\n- \xf0\x9f\x94\xb4 [VERIFIED] Critical: None found\n- \xf0\x9f\x94\xb5 [VERIFIED] Low Priority: None found\n\n**Pre-existing (informational):**\n- None found\n'

# Review 5263305644, finding 2. Scoping to the last section cannot see a file
# the model never mentioned: file A's complete section is then the last one
# and the chunk passes with file B unreviewed. With the chunk inventory
# supplied, every path must be mentioned somewhere in the body — by basename,
# in a heading or a finding anchor. Single-file chunks keep LADR-077's
# heading-free acceptance untouched.
inventory_case() { # inventory_case <expected> <label> <inventory> <body>
  local want="$1" label="$2" inv="$3" body="$4" got
  if printf '%b' "$body" | OPENCODE_EXPECTED_CHUNK_FILES="$inv" bash "$SHAPE"; then got=accept; else got=reject; fi
  [ "$got" = "$want" ] || {
    echo "FAIL: with inventory, shape predicate should $want '$label' but returned $got" >&2
    exit 1
  }
}
TWO=$'src/a.cs\nsrc/b.cs'
inventory_case reject "two files, only the first reviewed" "$TWO" \
  '### \xf0\x9f\x93\x84 File: \x60src/a.cs\x60\n\n**Issues Found:**\n- None found.\n'
inventory_case reject "two files, neither named" "$TWO" \
  '**Issues Found:**\n- None found.\n'
inventory_case accept "two files, both sections present" "$TWO" \
  '### \xf0\x9f\x93\x84 File: \x60src/a.cs\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60b.cs\x60\n\n**Issues Found:**\n- None found.\n'
inventory_case accept "two files, second named only in a finding anchor" "$TWO" \
  '### \xf0\x9f\x93\x84 File: \x60src/a.cs\x60\n\n**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: token logged at src/b.cs:12\n'
inventory_case accept "single file, heading-free clean body (LADR-077)" 'src/a.cs' \
  '**Issues Found:**\n- None found.\n'
inventory_case reject "two files, both named, but the last section is truncated" "$TWO" \
  '### \xf0\x9f\x93\x84 File: \x60src/a.cs\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60src/b.cs\x60\n\n**Issues Found:**\n'
echo "✓ shape predicate: an omitted file in a multi-file chunk is not a completed review"
# Review 5263417133, finding 3. Two chunk files with the SAME basename: a
# mention of `index.ts` must not vouch for both. The required mention is the
# shortest unique trailing path — `api/index.ts` / `web/index.ts` here — so a
# review naming only one of them is rejected, one naming both by parent dir is
# accepted, and a non-colliding sibling still needs only its basename.
DUP=$'src/api/index.ts\nsrc/web/index.ts\nsrc/util/helpers.ts'
inventory_case reject "duplicate basenames, only one index.ts reviewed" "$DUP" \
  '### \xf0\x9f\x93\x84 File: \x60index.ts\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60helpers.ts\x60\n\n**Issues Found:**\n- None found.\n'
inventory_case reject "duplicate basenames, full path for one, bare name for the other" "$DUP" \
  '### \xf0\x9f\x93\x84 File: \x60src/api/index.ts\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60index.ts\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60helpers.ts\x60\n\n**Issues Found:**\n- None found.\n'
inventory_case accept "duplicate basenames, both named by parent directory" "$DUP" \
  '### \xf0\x9f\x93\x84 File: \x60api/index.ts\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60web/index.ts\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60helpers.ts\x60\n\n**Issues Found:**\n- None found.\n'
inventory_case accept "duplicate basenames, both named by full path" "$DUP" \
  '### \xf0\x9f\x93\x84 File: \x60src/api/index.ts\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60src/web/index.ts\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60src/util/helpers.ts\x60\n\n**Issues Found:**\n- None found.\n'
DEEP=$'a/x/index.ts\nb/x/index.ts'
inventory_case reject "parents collide too: x/index.ts names neither" "$DEEP" \
  '### \xf0\x9f\x93\x84 File: \x60x/index.ts\x60\n\n**Issues Found:**\n- None found.\n'
inventory_case accept "parents collide too: both named with the distinguishing root" "$DEEP" \
  '### \xf0\x9f\x93\x84 File: \x60a/x/index.ts\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60b/x/index.ts\x60\n\n**Issues Found:**\n- None found.\n'
echo "✓ shape predicate: colliding basenames need the shortest unique trailing path"
# Review 5263727118, finding 3. A mention is a whole token: `app.js.map` and
# `myapp.js` are not mentions of `app.js`, while `src/app.js:12` and a
# backticked `app.js` are. Dots in the suffix are literal, not wildcards.
SUB=$'src/app.js\nsrc/app.js.map'
inventory_case reject "only the source map named; app.js itself omitted" "$SUB" \
  '### \xf0\x9f\x93\x84 File: \x60src/app.js.map\x60\n\n**Issues Found:**\n- None found.\n'
inventory_case accept "both named, the source with a line anchor" "$SUB" \
  '### \xf0\x9f\x93\x84 File: \x60src/app.js.map\x60\n\n**Issues Found:**\n- None found.\n\n**Issues Found:**\n- \xf0\x9f\x9f\xa0 [VERIFIED] High Priority: unused import at src/app.js:12\n'
PRE=$'lib/app.js\nlib/myapp.js'
inventory_case reject "myapp.js does not vouch for app.js" "$PRE" \
  '### \xf0\x9f\x93\x84 File: \x60lib/myapp.js\x60\n\n**Issues Found:**\n- None found.\n'
inventory_case accept "app.js and myapp.js each named" "$PRE" \
  '### \xf0\x9f\x93\x84 File: \x60app.js\x60\n\n**Issues Found:**\n- None found.\n\n### \xf0\x9f\x93\x84 File: \x60myapp.js\x60\n\n**Issues Found:**\n- None found.\n'
DOT=$'a/x.y\na/xzy'
inventory_case reject "a dot in the suffix is literal, not a wildcard" "$DOT" \
  '### \xf0\x9f\x93\x84 File: \x60a/xzy\x60\n\n**Issues Found:**\n- None found.\n'
echo "✓ shape predicate: a file mention is a whole token, not a substring"
# The sidecar is stripped before the inventory check too: a file that appears
# only in the JSON was not reviewed in the prose that gets posted.
inventory_case reject "a file named only inside the sidecar is not reviewed" $'src/a.cs\nsrc/b.cs' \
  "### \xf0\x9f\x93\x84 File: \x60src/a.cs\x60\n\n**Issues Found:**\n- None found.\n\n<!-- FINDINGS_JSON_BEGIN -->\n{\"findings\":[{\"file\":\"src/b.cs\",\"line\":3}]}\n<!-- FINDINGS_JSON_END -->\n"

# The transport honours the inventory too, so an omission falls through to the
# fallback instead of consuming it — and every call site hands it over.
stub_emitting "$CLEAN"
: > "${marker_dir}/inventory.calls"
PATH="${marker_dir}/bin:$PATH" OPENCODE_STUB_CALLS="${marker_dir}/inventory.calls" \
  OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai OPENCODE_OUTPUT_SHAPE_CHECK="$SHAPE" \
  OPENCODE_EXPECTED_CHUNK_FILES=$'src/Ftp/FtpHelper.cs\nsrc/Ftp/FtpClient.cs' \
  bash "$HELPER" m1 m2 m3 -- "$prompt" > /dev/null 2>&1 && rc=0 || rc=$?
calls="$(wc -l < "${marker_dir}/inventory.calls" | tr -d ' ')"
[ "$rc:$calls" = "1:3" ] || {
  echo "FAIL: a one-file review of a two-file chunk must fall through the whole chain (got '$rc:$calls')" >&2
  exit 1
}
[ "$(grep -c 'OPENCODE_EXPECTED_CHUNK_FILES="$_expected_files"' "${SCRIPT_DIR}/review-in-chunks.sh")" = "3" ] || {
  echo "FAIL: both transport calls and the chunk gate must pass the chunk inventory to the predicate" >&2
  exit 1
}
echo "✓ transport rejects an omitted file; all three call sites pass the inventory"
echo "✓ shape predicate: narration rejected, real findings accepted"

echo "✓ opencode-with-fallback target tests passed"
