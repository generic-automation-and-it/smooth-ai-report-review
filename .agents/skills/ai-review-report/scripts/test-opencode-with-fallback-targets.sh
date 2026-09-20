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

# --- Output marker beats the byte floor (LADR-087) ---------------------------
# A correct review of a clean file is short. The 200-byte floor was calibrated
# against v1, which leaked the model's chain-of-thought onto stdout; v2 routes
# it to stderr, so valid reviews started falling under the floor — rejected,
# then re-asked from every model in the chain, then fail-closed as a "silent
# failure". Eval run 35525187790 lost three fixtures exactly this way.
# OPENCODE_OUTPUT_MARKER lets a caller name the string that proves the model
# reached its template; unset, every call site keeps the pure byte floor.
marker_dir="${tmp_dir}/marker"
mkdir -p "${marker_dir}/bin"
cat > "${marker_dir}/bin/opencode" <<'SHORTSTUB'
#!/bin/bash
cat >/dev/null
printf 'call\n' >> "$OPENCODE_STUB_CALLS"
cat <<'REV'
### 📄 File: `src/Ftp/FtpHelper.cs`

**Issues Found:**
- None found.
REV
SHORTSTUB
chmod +x "${marker_dir}/bin/opencode"

marker_case() { # marker_case <label> <marker>
  : > "${marker_dir}/$1.calls"
  PATH="${marker_dir}/bin:$PATH" \
    OPENCODE_STUB_CALLS="${marker_dir}/$1.calls" \
    OPENCODE_REVIEW_REPORT_PROVIDER_ID=openai \
    OPENCODE_OUTPUT_MARKER="$2" \
    bash "$HELPER" m1 m2 m3 -- "$prompt" > "${marker_dir}/$1.out" 2>/dev/null
  echo "$?:$(wc -c < "${marker_dir}/$1.out" | tr -d ' '):$(wc -l < "${marker_dir}/$1.calls" | tr -d ' ')"
}

# Unset marker: unchanged from before — rejected, and the whole chain is burned
# re-asking. Pinning the old behaviour proves the change is additive, so the
# summary / semantic-grouping / analyse callers cannot be affected by it.
actual="$(marker_case no_marker "")"
[ "$actual" = "1:0:3" ] || {
  echo "FAIL: without a marker a short answer must still be rejected after trying every model (got '$actual')" >&2
  exit 1
}
echo "✓ no marker: short output still rejected, chain still exhausted (unchanged)"

actual="$(marker_case with_marker '### 📄 File:')"
[ "$actual" = "0:71:1" ] || {
  echo "FAIL: a marked short review must be accepted on the first model (got '$actual')" >&2
  exit 1
}
echo "✓ marker present: short review accepted, no fallback model burned"

# A marker the output does not carry must not rescue it — otherwise the option
# would accept anything from a caller that sets it.
actual="$(marker_case wrong_marker 'ZZ-NOT-IN-OUTPUT')"
[ "$actual" = "1:0:3" ] || {
  echo "FAIL: a marker absent from the output must not rescue it (got '$actual')" >&2
  exit 1
}
echo "✓ marker absent from output: falls back to the byte floor"

# The gate's chunk call sites must actually pass one, or the fix is inert.
grep -q 'OPENCODE_OUTPUT_MARKER="$CHUNK_OUTPUT_MARKER" timeout' "${SCRIPT_DIR}/review-in-chunks.sh" || {
  echo "FAIL: review-in-chunks.sh does not declare an output marker for its chunk reviews" >&2
  exit 1
}
[ "$(grep -c 'OPENCODE_OUTPUT_MARKER="$CHUNK_OUTPUT_MARKER" timeout' "${SCRIPT_DIR}/review-in-chunks.sh")" = "2" ] || {
  echo "FAIL: both chunk-review invocations (primary stage and secondary stage) must declare the marker" >&2
  exit 1
}
echo "✓ both chunk-review call sites declare the marker"

echo "✓ opencode-with-fallback target tests passed"
