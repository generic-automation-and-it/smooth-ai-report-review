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
# The "None found." clause keeps a bare literal ON PURPOSE: there the marker IS
# the content — it is the complete statement the template asks for when there
# is nothing to report — and a response cut off inside it does not match.
predicate_case reject "a truncated None found placeholder" \
  '**Issues Found:**\n- None fou'
predicate_case reject "empty output" ''
echo "✓ shape predicate: narration rejected, real findings accepted"

echo "✓ opencode-with-fallback target tests passed"
