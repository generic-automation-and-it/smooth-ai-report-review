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

echo "✓ opencode-with-fallback target tests passed"
