#!/bin/bash
# Static guard: /ai-review must strip the gate's per-commit permalink
# (` · [open](…)`, LADR-112) before writing Skip Areas bullets or summary-table
# rows. A copied SHA would make the same skip read as new text every round and
# break the cross-round match (LADR-101). The rule lives in SKILL.md prose, so
# the check is a grep over the Non-Copilot Skip Areas step.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$SCRIPT_DIR/../SKILL.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$SKILL" ] || fail "SKILL.md not found at $SKILL"
step="$(awk '/MANDATORY — update the "Skip Areas \/ Known Issues" bullets/{f=1} /^3\. \*\*Verify the edit landed/{f=0} f' "$SKILL")"
[ -n "$step" ] || fail 'could not locate the Skip Areas bullet step in SKILL.md'
rule="$(printf '%s\n' "$step" | grep -F 'Strip the permalink first' || true)"
[ -n "$rule" ] || fail 'the Skip Areas step has no strip-the-permalink rule'
printf '%s' "$rule" | grep -qF ' · [open](' || fail 'the rule does not name the exact ` · [open](…)` suffix'
printf '%s' "$rule" | grep -qi 'Skip Areas bullet' || fail 'the rule does not cover Skip Areas bullets'
printf '%s' "$rule" | grep -qi 'summary-table row' || fail 'the rule does not cover summary-table rows'
printf 'PASS: /ai-review strips finding permalinks before writing skips\n'
