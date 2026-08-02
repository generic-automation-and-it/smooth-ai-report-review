#!/bin/bash
set -e

# Test script for the structured-findings prompt guard (LADR-055 / LADR-058).
#
# `OPENCODE_REVIEW_REPORT_ENABLE_STRUCTURED_FINDINGS` can be set falsy, in which
# case review-in-chunks.sh omits the sidecar instruction entirely — no schema,
# no JSON block, no field names. Any prompt prose that survives that switch must
# therefore be field-agnostic: telling a model to "set `pre_existing: true`" when
# nothing ever asked it for JSON is an instruction it cannot follow, and the
# failure is completely silent (the review still posts, it is just worse).
#
# This is a STATIC check on the script source rather than a runtime one, because
# the invariant is structural: every prompt heredoc that names a findings-schema
# field must sit inside an `if structured_findings_enabled; then` block. A static
# check catches it at the point of edit and needs no model call, no fixture repo,
# and no network.
#
# Guard structure assumed (and asserted below): the guards in this file are flat,
# `if structured_findings_enabled; then` ... `fi`, never nested.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/review-in-chunks.sh"

echo "=========================================="
echo "Testing structured-findings prompt guard"
echo "=========================================="
echo ""

pass=0
fail=0

ok()   { echo "✅ $1"; pass=$((pass + 1)); }
bad()  { echo "❌ $1"; fail=$((fail + 1)); }

[ -f "$TARGET" ] || { echo "❌ missing $TARGET"; exit 1; }

# Field names from assets/findings-schema.json that only exist when the sidecar
# is requested. `confidence` is deliberately excluded: it is also an ordinary
# English word used by the unconditional [VERIFIED]/[SPECULATIVE] tagging prose.
# The anchors block that gives `confidence` its schema meaning is guarded, and
# test 3 below pins that separately.
FIELDS='pre_existing|residual_risks|testing_gaps|autofix_class|why_it_matters|first_evidence|graph_evidence|requires_verification|suggested_fix'

# Walk the source tracking two states: inside a guard, and inside a prompt
# heredoc. Report any heredoc content line that names a field while unguarded.
LEAKS="$(awk -v fields="$FIELDS" '
  /^[[:space:]]*if structured_findings_enabled; then[[:space:]]*$/ { guard = 1; next }
  guard && /^[[:space:]]*fi[[:space:]]*$/                         { guard = 0; next }
  /cat >>? ci_temp\/chunk_\$\{chunk_num\}_prompt\.txt <</           { heredoc = 1; next }
  heredoc && /^EOF$/                                              { heredoc = 0; next }
  heredoc && !guard && $0 ~ fields                                { printf "%d: %s\n", NR, substr($0, 1, 110) }
' "$TARGET")"

if [ -z "$LEAKS" ]; then
  ok "no schema field name appears in an unguarded chunk-prompt heredoc"
else
  bad "schema field name(s) leak into the prompt when structured findings are disabled"
  printf '%s\n' "$LEAKS" | sed 's/^/     /'
fi

# The guard helper itself must exist and be the single decision point.
if grep -q '^structured_findings_enabled() {' "$TARGET"; then
  ok "structured_findings_enabled() is defined in review-in-chunks.sh"
else
  bad "structured_findings_enabled() is missing — the guard has been renamed or removed"
fi

# The three blocks that are meaningless without the sidecar must stay guarded.
# Each is identified by a phrase unique to it; each must be inside a guard.
check_guarded() {
  local label="$1" needle="$2"
  local line
  line="$(grep -n -- "$needle" "$TARGET" | head -n1 | cut -d: -f1)"
  if [ -z "$line" ]; then
    bad "$label — anchor phrase not found (block renamed?)"
    return
  fi
  # Count guard opens and closes above this line; inside a flat guard iff opens > closes.
  local opens closes
  opens="$(head -n "$line" "$TARGET" | grep -c '^[[:space:]]*if structured_findings_enabled; then[[:space:]]*$' || true)"
  closes="$(awk -v stop="$line" '
    NR > stop { exit }
    /^[[:space:]]*if structured_findings_enabled; then[[:space:]]*$/ { g = 1; next }
    g && /^[[:space:]]*fi[[:space:]]*$/ { g = 0; c++ }
    END { print c + 0 }
  ' "$TARGET")"
  if [ "$opens" -gt "$closes" ]; then
    ok "$label is inside the structured-findings guard"
  else
    bad "$label is OUTSIDE the structured-findings guard (line $line)"
  fi
}

check_guarded "confidence anchors block"  '\*\*Confidence Anchors (MANDATORY'
check_guarded "sidecar JSON instruction"  'FINDINGS_JSON_BEGIN'
check_guarded "soft-bucket routing block" '\*\*Soft-bucket routing'

# Upstream's P-scale must not leak into our prompt — this repo's vocabulary is
# critical/high/medium/low with emoji, and a model told to route "P2/P3" items
# has no way to map that onto the severities it was asked to emit.
if grep -qE 'P0/P1|P2/P3|\bP[0-3]\b' "$TARGET"; then
  # The one legitimate mention is the sidecar rule forbidding the P-scale.
  OFFENDERS="$(grep -nE 'P0/P1|P2/P3|\bP[0-3]\b' "$TARGET" | grep -v 'never P0/P1/P2/P3' || true)"
  if [ -z "$OFFENDERS" ]; then
    ok "no upstream P-scale vocabulary in the prompt (only the rule forbidding it)"
  else
    bad "upstream P-scale vocabulary leaked into the prompt"
    printf '%s\n' "$OFFENDERS" | sed 's/^/     /'
  fi
else
  ok "no upstream P-scale vocabulary in the prompt"
fi

echo ""
echo "=========================================="
if [ "$fail" -gt 0 ]; then
  echo "Prompt guard tests FAILED ($fail failed, $pass passed)"
  exit 1
fi
echo "Prompt guard tests passed ($pass checks)"
echo "=========================================="
