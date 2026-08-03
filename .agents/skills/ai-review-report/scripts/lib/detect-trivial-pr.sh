#!/bin/bash
# detect-trivial-pr.sh — deterministic trivial-PR pre-check (LADR-059).
#
# Two stages:
#   1. Deterministic precondition (bash): every changed file must match
#      a conservative low-risk allowlist (lockfiles + dependency manifests).
#      One file outside the allowlist disqualifies the whole PR.
#   2. Model veto (only if stage 1 passes): one orchestrator-model call
#      receives PR title, body and changed path list, answers the
#      spec's question with the spec's asymmetric bias.
#
# Output (stdout): "trivial:<reason>" or "not_trivial"
# Exit code: 0 on success, non-zero only on usage error.
#
# The caller (run-review.sh) treats any non-"trivial" result — including
# a non-zero exit — as "proceed with the review". Fail open, never fail
# closed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR"

if [ "$#" -lt 3 ]; then
  echo "Usage: detect-trivial-pr.sh <changed-files.txt> <pr_title> <pr_body>" >&2
  exit 64
fi

CHANGED_FILES="$1"
PR_TITLE="$2"
PR_BODY="$3"

# --- Stage 1: deterministic precondition ----------------------------------
LOCKFILE_PATTERNS=(
  'package-lock.json'
  'yarn.lock'
  'pnpm-lock.yaml'
  'go.sum'
  'Cargo.lock'
  'poetry.lock'
  'Gemfile.lock'
  'composer.lock'
  'mix.lock'
  'Pipfile.lock'
)

MANIFEST_PATTERNS=(
  'package.json'
  'go.mod'
  '*.csproj'
  'pyproject.toml'
  'Gemfile'
  'Cargo.toml'
  'composer.json'
  'requirements*.txt'
)

is_low_risk() {
  local file="$1"
  local basename
  basename="$(basename "$file")"

  for pattern in "${LOCKFILE_PATTERNS[@]}"; do
    [ "$basename" = "$pattern" ] && return 0
  done

  for pattern in "${MANIFEST_PATTERNS[@]}"; do
    case "$basename" in
      $pattern) return 0 ;;
    esac
  done

  return 1
}

non_low_risk=""
while IFS= read -r -d '' file; do
  [ -z "$file" ] && continue
  if ! is_low_risk "$file"; then
    non_low_risk="$file"
    break
  fi
done < "$CHANGED_FILES"

if [ -n "$non_low_risk" ]; then
  echo "not_trivial"
  exit 0
fi

# Stage 1 passed — every changed file is low-risk. Ask the model.
# Constrain output to a single token (yes/no). Treat anything that is
# not an exact, case-insensitive "yes" as "no" — including empty output,
# a timeout, a fallback-chain exhaustion, or prose. Fail open (review
# runs), never fail closed (review skipped).

ORCHESTRATOR="${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR:-gemini-3-flash-preview}"

TMP_PROMPT="$(mktemp)"
trap 'rm -f "$TMP_PROMPT" "${TMP_PROMPT}.out"' EXIT

# Build the prompt file directly to avoid substitution issues with
# file paths containing / characters.
{
  echo "Is this an automated or trivial PR that does not warrant a code review?"
  echo "Consider dependency lock-file or manifest-only bumps, automated release commits, chore version increments with no substantive code changes."
  echo ""
  echo "PR Title: $PR_TITLE"
  echo ""
  echo "PR Description:"
  # Cap the body — a long PR description cannot change the answer for a
  # changeset that already passed the lockfile/manifest precondition, and
  # an unbounded body is an injection surface for a prompt this cheap.
  printf '%s\n' "$PR_BODY" | head -c 2000
  echo ""
  echo "Changed files:"
  tr '\0' '\n' < "$CHANGED_FILES" 2>/dev/null | head -50 || true
  echo ""
  echo "When in doubt, answer no — false negatives (skipped reviews that should have run) are more costly than false positives (unnecessary reviews)."
  echo ""
  echo "Answer with exactly one word: yes or no. Nothing else."
} > "$TMP_PROMPT"

# OPENCODE_MIN_OUTPUT_BYTES=1 because the only correct answers here are
# `yes` and `no`. The helper's default of 200 scores any shorter stdout as
# a failure, so the whole model chain would fall through and this detector
# could never return `trivial` — a silent, permanent no-op. It must be set
# on the call, not merely described in a comment.
RESPONSE=""
if OPENCODE_MIN_OUTPUT_BYTES=1 timeout 30s bash "$LIB_DIR/opencode-with-fallback.sh" \
    "$ORCHESTRATOR" \
    "${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY:-gemini-3.1-pro-preview}" \
    "" \
    -- "$TMP_PROMPT" \
    > "${TMP_PROMPT}.out" 2>/dev/null; then
  RESPONSE="$(tr '[:upper:]' '[:lower:]' < "${TMP_PROMPT}.out" 2>/dev/null | tr -d '[:space:]' || true)"
fi

rm -f "$TMP_PROMPT" "${TMP_PROMPT}.out"
trap - EXIT

if [ "$RESPONSE" = "yes" ]; then
  echo "trivial:model-veto"
else
  echo "not_trivial"
fi