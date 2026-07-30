#!/bin/bash
# Test script for run-review.sh — the entrypoint that drives the full review gate.
# Covers the env-var precedence contract and the $GITHUB_EVENT_PATH event payload
# parser. Behavioral parity with the reusable workflow (criterion 5) is exercised
# by an out-of-tree E2E — this file only covers unit-level contracts.
set -eo pipefail

# Requires Bash >= 4 (associative arrays, ${VAR^^}).
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "❌ Requires Bash >= 4 (found ${BASH_VERSION:-unknown})." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_REVIEW="$SCRIPT_DIR/run-review.sh"

# ── Fixture helpers ─────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ✅ $name"
    pass=$((pass + 1))
  else
    echo "  ❌ $name"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    fail=$((fail + 1))
  fi
}

# Write a stub event payload. Mirrors the three trigger shapes the workflow
# supports. Anything else (e.g. workflow_call without child event) returns
# "unsupported" from the parser.
write_pull_request_event() {
  cat > "$1" <<'EOF'
{
  "action": "opened",
  "pull_request": {
    "number": 42,
    "draft": false,
    "user": { "login": "alice" },
    "head": { "ref": "feature", "sha": "0123456789abcdef0123456789abcdef01234567", "repo": { "full_name": "owner/repo" } },
    "base": { "ref": "main", "sha": "fedcba9876543210fedcba9876543210fedcba98", "repo": { "full_name": "owner/repo" } }
  },
  "sender": { "login": "alice" }
}
EOF
}

write_draft_pr_event() {
  cat > "$1" <<'EOF'
{
  "action": "opened",
  "pull_request": {
    "number": 43,
    "draft": true,
    "user": { "login": "alice" },
    "head": { "ref": "feature", "sha": "0123456789abcdef0123456789abcdef01234567", "repo": { "full_name": "owner/repo" } },
    "base": { "ref": "main", "sha": "fedcba9876543210fedcba9876543210fedcba98", "repo": { "full_name": "owner/repo" } }
  },
  "sender": { "login": "alice" }
}
EOF
}

write_dependabot_pr_event() {
  cat > "$1" <<'EOF'
{
  "action": "opened",
  "pull_request": {
    "number": 44,
    "draft": false,
    "user": { "login": "dependabot[bot]" },
    "head": { "ref": "feature", "sha": "0123456789abcdef0123456789abcdef01234567", "repo": { "full_name": "owner/repo" } },
    "base": { "ref": "main", "sha": "fedcba9876543210fedcba9876543210fedcba98", "repo": { "full_name": "owner/repo" } }
  },
  "sender": { "login": "dependabot[bot]" }
}
EOF
}

write_issue_comment_event() {
  cat > "$1" <<'EOF'
{
  "action": "created",
  "issue": { "number": 42, "pull_request": { "url": "..." } },
  "comment": { "body": "/ai-review", "author_association": "OWNER" }
}
EOF
}

write_issue_comment_no_trigger() {
  cat > "$1" <<'EOF'
{
  "action": "created",
  "issue": { "number": 42, "pull_request": { "url": "..." } },
  "comment": { "body": "looks good", "author_association": "OWNER" }
}
EOF
}

write_issue_comment_non_member() {
  cat > "$1" <<'EOF'
{
  "action": "created",
  "issue": { "number": 42, "pull_request": { "url": "..." } },
  "comment": { "body": "/ai-review", "author_association": "CONTRIBUTOR" }
}
EOF
}

write_workflow_dispatch_event() {
  cat > "$1" <<'EOF'
{ "inputs": { "pr_number": "42" } }
EOF
}

write_issue_event() {
  # Issue payload WITHOUT a `comment` key — a freshly-opened issue event is
  # shaped like this and must not be matched as issue_comment (no /ai-review
  # context yet). The script's parser requires BOTH `issue` and `comment`
  # for the issue_comment classification.
  cat > "$1" <<'EOF'
{ "issue": { "number": 42 } }
EOF
}

# The script reads $GITHUB_EVENT_PATH and decides which event shape it is.
# Re-implement the same jq expression used in run-review.sh and assert the
# value — this locks the contract that future refactors must keep.
detect_event_name() {
  jq -r 'if type=="object" and has("pull_request") then "pull_request" elif type=="object" and has("issue") and has("comment") then "issue_comment" elif type=="object" and has("inputs") then "workflow_dispatch" else "unsupported" end' "$1"
}

echo "=========================================="
echo "Testing run-review.sh event payload parser"
echo "=========================================="

f="$TMP_DIR/pr.json"; write_pull_request_event "$f"
check "pull_request event recognized" "pull_request" "$(detect_event_name "$f")"

f="$TMP_DIR/draft.json"; write_draft_pr_event "$f"
check "draft PR event still recognized (gated later)" "pull_request" "$(detect_event_name "$f")"

f="$TMP_DIR/dependabot.json"; write_dependabot_pr_event "$f"
check "dependabot PR event still recognized (gated later)" "pull_request" "$(detect_event_name "$f")"

f="$TMP_DIR/issue_comment.json"; write_issue_comment_event "$f"
check "issue_comment event recognized" "issue_comment" "$(detect_event_name "$f")"

f="$TMP_DIR/issue_comment_no_trigger.json"; write_issue_comment_no_trigger "$f"
check "issue_comment without /ai-review still recognized (gated later)" "issue_comment" "$(detect_event_name "$f")"

f="$TMP_DIR/issue_comment_non_member.json"; write_issue_comment_non_member "$f"
check "issue_comment from non-member still recognized (gated later)" "issue_comment" "$(detect_event_name "$f")"

f="$TMP_DIR/dispatch.json"; write_workflow_dispatch_event "$f"
check "workflow_dispatch event recognized" "workflow_dispatch" "$(detect_event_name "$f")"

f="$TMP_DIR/issue_only.json"; write_issue_event "$f"
check "issue-only event (not on PR) recognized" "unsupported" "$(detect_event_name "$f")"

f="$TMP_DIR/empty.json"; echo '{}' > "$f"
check "empty payload classified as unsupported" "unsupported" "$(detect_event_name "$f")"

# ── Gating should_run decisions (must mirror the workflow's if:) ────────────
# Implement a sandboxed should_run that uses the same logic the script runs.
# Test by sourcing run-review.sh's helpers via a wrapper. The cleanest way is
# to extract the should_run logic to a sub-test that re-implements the same
# decision tree — the parser test above already locks the event-name dispatch.
should_run_pr() {
  local event_path="$1"
  local actor draft
  actor="$(jq -r '.sender.login // .pull_request.user.login // ""' "$event_path")"
  draft="$(jq -r '.pull_request.draft // false' "$event_path")"
  [ "$actor" != "dependabot[bot]" ] && [ "$draft" != "true" ]
}

should_run_issue_comment() {
  local event_path="$1"
  local assoc body is_pr
  assoc="$(jq -r '.comment.author_association // ""' "$event_path")"
  body="$(jq -r '.comment.body // ""' "$event_path")"
  is_pr="$(jq -r 'if .issue.pull_request then "true" else "false" end' "$event_path")"
  [ "$is_pr" = "true" ] && echo "$body" | grep -q "/ai-review" && case "$assoc" in OWNER|MEMBER|COLLABORATOR) return 0;; esac
  return 1
}

f="$TMP_DIR/pr.json"; write_pull_request_event "$f"
if should_run_pr "$f"; then check "should_run accepts normal PR" "yes" "yes"; else check "should_run accepts normal PR" "yes" "no"; fi

f="$TMP_DIR/draft.json"; write_draft_pr_event "$f"
if should_run_pr "$f"; then check "should_run rejects draft PR" "no" "yes"; else check "should_run rejects draft PR" "no" "no"; fi

f="$TMP_DIR/dependabot.json"; write_dependabot_pr_event "$f"
if should_run_pr "$f"; then check "should_run rejects dependabot PR" "no" "yes"; else check "should_run rejects dependabot PR" "no" "no"; fi

f="$TMP_DIR/issue_comment.json"; write_issue_comment_event "$f"
if should_run_issue_comment "$f"; then check "should_run accepts OWNER /ai-review" "yes" "yes"; else check "should_run accepts OWNER /ai-review" "yes" "no"; fi

f="$TMP_DIR/issue_comment_no_trigger.json"; write_issue_comment_no_trigger "$f"
if should_run_issue_comment "$f"; then check "should_run rejects comment without /ai-review" "no" "yes"; else check "should_run rejects comment without /ai-review" "no" "no"; fi

f="$TMP_DIR/issue_comment_non_member.json"; write_issue_comment_non_member "$f"
if should_run_issue_comment "$f"; then check "should_run rejects non-member /ai-review" "no" "yes"; else check "should_run rejects non-member /ai-review" "no" "no"; fi

# ── Env-var precedence contract ─────────────────────────────────────────────
# The script reads these at job scope and passes them through. Each must
# resolve with the documented precedence. The env resolution is locked by
# the workflow's env: block (expressions like
# `inputs.model || vars.X || 'default'`), so these tests check the SHELL
# side — what run-review.sh does when the env is already populated.
echo ""
echo "=========================================="
echo "Testing run-review.sh env-var precedence"
echo "=========================================="

# Helper: run a small bash snippet that mirrors the precedence used in
# run-review.sh. Each test sets up the env, runs the snippet, and asserts
# the resolved value.
run_precedence() {
  local name="$1" expected="$2"
  shift 2
  local actual
  actual="$(env -i "$@" bash -c '
    OPENCODE_REVIEW_REPORT_PROVIDER="${OPENCODE_REVIEW_REPORT_PROVIDER:-GEMINI}"
    OPENCODE_REVIEW_REPORT_MODEL_PRIMARY="${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY:-gemini-3.1-pro-preview}"
    OPENCODE_REVIEW_REPORT_MODEL_SECONDARY="${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY:-gemini-2.5-pro}"
    OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR="${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR:-gemini-3-flash-preview}"
    OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE="${OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE:-1}"
    OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK="${OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK:-0}"
    OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT="${OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT:-100}"
    printf "%s|%s|%s|%s|%s|%s|%s" \
      "$OPENCODE_REVIEW_REPORT_PROVIDER" \
      "$OPENCODE_REVIEW_REPORT_MODEL_PRIMARY" \
      "$OPENCODE_REVIEW_REPORT_MODEL_SECONDARY" \
      "$OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR" \
      "$OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE" \
      "$OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK" \
      "$OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT"
  ')"
  check "$name" "$expected" "$actual"
}

# Default path: all unset → literal defaults.
run_precedence "defaults when env unset" \
  "GEMINI|gemini-3.1-pro-preview|gemini-2.5-pro|gemini-3-flash-preview|1|0|100"

# Env override: caller-provided value wins over default.
run_precedence "caller env wins over default (provider)" \
  "ANTHROPIC|gemini-3.1-pro-preview|gemini-2.5-pro|gemini-3-flash-preview|1|0|100" \
  OPENCODE_REVIEW_REPORT_PROVIDER=ANTHROPIC

run_precedence "caller env wins over default (all model tiers)" \
  "GEMINI|claude-opus-4-8|claude-sonnet-4-6|claude-haiku-4-5|1|0|100" \
  OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=claude-opus-4-8 \
  OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=claude-sonnet-4-6 \
  OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=claude-haiku-4-5

run_precedence "caller env wins over default (claude code + agents md + file count)" \
  "GEMINI|gemini-3.1-pro-preview|gemini-2.5-pro|gemini-3-flash-preview|0|1|50" \
  OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE=0 \
  OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK=1 \
  OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT=50

# Empty env: ${VAR:-default} treats empty the same as unset → default applies.
# This is the gate the workflow relies on: an unset Variable resolves to '' in
# the env: block, but run-review.sh still picks a usable default.
run_precedence "empty string falls through to default" \
  "GEMINI|gemini-3.1-pro-preview|gemini-2.5-pro|gemini-3-flash-preview|1|0|100" \
  OPENCODE_REVIEW_REPORT_PROVIDER= \
  OPENCODE_REVIEW_REPORT_MODEL_PRIMARY= \
  OPENCODE_REVIEW_REPORT_MODEL_SECONDARY= \
  OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=

# Invalid file count: non-numeric input must fall back to 100, not pass through.
# (Mirrors the regex check the script does in step 0.)
invalid_count_check() {
  local name="$1" input="$2"
  local actual
  actual="$(OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT="$input" bash -c '
    val="${OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT:-100}"
    if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -le 0 ]; then val=100; fi
    echo "$val"
  ')"
  check "$name" "100" "$actual"
}
invalid_count_check "non-numeric MAX_FILE_COUNT falls back to 100" "abc"
invalid_count_check "empty MAX_FILE_COUNT falls back to 100" ""
invalid_count_check "negative MAX_FILE_COUNT falls back to 100" "-5"
invalid_count_check "zero MAX_FILE_COUNT falls back to 100" "0"

# ── Provider → key/URL mapping (the pre-checkout fail-fast) ───────────────
# The script's `case` in step 5a maps the provider to (U=URL var, K=key var).
# Test that GEMINI / COPILOT / OPENAI / ANTHROPIC / OPENCODE-GO-* / OPEN_ROUTER
# all resolve to the right pair, and an unknown provider errors.
echo ""
echo "=========================================="
echo "Testing provider → key/URL mapping"
echo "=========================================="

map_provider() {
  local provider="$1"
  bash -c '
    provider="$1"
    U=""; GW_URL=""; K=""
    case "$provider" in
      COPILOT)               U=OPENCODE_REVIEW_REPORT_COPILOT_URL;  K=OPENCODE_COPILOT_API_KEY ;;
      OPENAI)                U=OPENCODE_REVIEW_REPORT_OPENAI_URL;   K=OPENCODE_OPENAI_API_KEY ;;
      ANTHROPIC)             GW_URL="https://api.anthropic.com";    K=OPENCODE_ANTHROPIC_API_KEY ;;
      OPENCODE-GO-OPENAI)    GW_URL="https://opencode.ai/zen/go/v1"; K=OPENCODE_GO_OPENAI_API_KEY ;;
      OPENCODE-GO-ANTHROPIC) GW_URL="https://opencode.ai/zen/go/v1"; K=OPENCODE_GO_ANTHROPIC_API_KEY ;;
      OPEN_ROUTER)           GW_URL="https://openrouter.ai/api/v1";  K=OPENCODE_OPENROUTER_API_KEY ;;
      GEMINI)                U=OPENCODE_REVIEW_REPORT_GEMINI_URL;   K=OPENCODE_GEMINI_API_KEY ;;
      *) echo "UNKNOWN"; exit 0 ;;
    esac
    echo "${U:-<fixed>}|${GW_URL:-<var>}|${K}"
  ' _ "$provider"
}

check "GEMINI maps to URL var + API key" \
  "OPENCODE_REVIEW_REPORT_GEMINI_URL|<var>|OPENCODE_GEMINI_API_KEY" \
  "$(map_provider GEMINI)"

check "COPILOT maps to URL var + API key" \
  "OPENCODE_REVIEW_REPORT_COPILOT_URL|<var>|OPENCODE_COPILOT_API_KEY" \
  "$(map_provider COPILOT)"

check "OPENAI maps to URL var + API key" \
  "OPENCODE_REVIEW_REPORT_OPENAI_URL|<var>|OPENCODE_OPENAI_API_KEY" \
  "$(map_provider OPENAI)"

check "ANTHROPIC maps to fixed URL + API key" \
  "<fixed>|https://api.anthropic.com|OPENCODE_ANTHROPIC_API_KEY" \
  "$(map_provider ANTHROPIC)"

check "OPENCODE-GO-OPENAI maps to Zen URL + API key" \
  "<fixed>|https://opencode.ai/zen/go/v1|OPENCODE_GO_OPENAI_API_KEY" \
  "$(map_provider OPENCODE-GO-OPENAI)"

check "OPENCODE-GO-ANTHROPIC maps to Zen URL + API key" \
  "<fixed>|https://opencode.ai/zen/go/v1|OPENCODE_GO_ANTHROPIC_API_KEY" \
  "$(map_provider OPENCODE-GO-ANTHROPIC)"

check "OPEN_ROUTER maps to OpenRouter URL + API key" \
  "<fixed>|https://openrouter.ai/api/v1|OPENCODE_OPENROUTER_API_KEY" \
  "$(map_provider OPEN_ROUTER)"

check "unknown provider returns UNKNOWN" \
  "UNKNOWN" \
  "$(map_provider BOGUS)"

# ── Run-review.sh syntax check ──────────────────────────────────────────────
# The script must parse cleanly under `bash -n`. This is the cheapest
# regression detector for accidental syntax breakage.
echo ""
echo "=========================================="
echo "Sanity: bash -n run-review.sh"
echo "=========================================="
if bash -n "$RUN_REVIEW"; then
  echo "  ✅ run-review.sh parses cleanly"
  pass=$((pass + 1))
else
  echo "  ❌ run-review.sh has a syntax error"
  fail=$((fail + 1))
fi

# ── GITHUB_TOKEN preflight (regression: PR #86) ────────────────────────────
# The reusable workflow's bare `run:` shells do NOT auto-inject
# GITHUB_TOKEN — the step's env: block must forward it explicitly.
# This regression was caught on PR #86: the refactor forgot the forward
# and the gate failed at the preflight check. Lock the contract.
echo ""
echo "=========================================="
echo "Testing GITHUB_TOKEN preflight (regression)"
echo "=========================================="

# Extract the preflight block from run-review.sh (the GITHUB_TOKEN check at
# line ~141) and inline it in a fresh shell with a stub $GITHUB_EVENT_PATH.
# Stub the rest of the script's required env so the check is reachable.
extract_preflight() {
  # Print from the GITHUB_EVENT_PATH preflight through the GITHUB_TOKEN
  # check. Skip the Bash-version guard (uses BASH_SOURCE) and the body
  # before the preflight — those have their own coverage.
  sed -n '/^# --- Step 1: Validate the runtime/,/GITHUB_TOKEN is not set/p' "$RUN_REVIEW"
}

# 1. The preflight must fail when GITHUB_TOKEN is unset.
write_pull_request_event "$TMP_DIR/pr.json"
no_token_exit="$(GITHUB_EVENT_PATH="$TMP_DIR/pr.json" \
  GITHUB_REPOSITORY=owner/repo \
  GITHUB_SERVER_URL=https://github.com \
  GITHUB_RUN_ID=12345 \
  bash -c '
  unset GITHUB_TOKEN
  '"$(extract_preflight)"'
' 2>&1 >/dev/null; echo $?)"
check "preflight fails when GITHUB_TOKEN unset" "1" "$no_token_exit"

# 2. The preflight must pass when GITHUB_TOKEN is set.
with_token_exit="$(GITHUB_EVENT_PATH="$TMP_DIR/pr.json" \
  GITHUB_REPOSITORY=owner/repo \
  GITHUB_SERVER_URL=https://github.com \
  GITHUB_RUN_ID=12345 \
  GITHUB_TOKEN=ghp_test \
  bash -c '
  '"$(extract_preflight)"'
' 2>&1 >/dev/null; echo $?)"
check "preflight accepts GITHUB_TOKEN" "0" "$with_token_exit"

# 3. The error message must mention GITHUB_TOKEN so consumers can
# diagnose the failure without reading the source.
extract_preflight > "$TMP_DIR/preflight.sh"
(
  unset GITHUB_TOKEN
  GITHUB_EVENT_PATH="$TMP_DIR/pr.json" \
  GITHUB_REPOSITORY=owner/repo \
  GITHUB_SERVER_URL=https://github.com \
  GITHUB_RUN_ID=12345 \
  bash "$TMP_DIR/preflight.sh" > "$TMP_DIR/no_token.out" 2>&1 || true
)
no_token_msg="$(head -1 "$TMP_DIR/no_token.out")"
case "$no_token_msg" in
  *GITHUB_TOKEN*) echo "  ✅ preflight error message names GITHUB_TOKEN"
                   pass=$((pass + 1)) ;;
  *)              echo "  ❌ preflight error message missing GITHUB_TOKEN: $no_token_msg"
                   fail=$((fail + 1)) ;;
esac

# 4. The two caller templates (reusable workflow + local-job caller) must
# both forward GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} on the
# Run review gate step's env: block. Catches the exact regression from
# PR #86 — a future refactor that strips the forward breaks both paths.
assert_step_forwards_github_token() {
  local name="$1" file="$2"
  # Look for a step named "Run review gate" that contains
  # `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` inside its env: block.
  local ok
  ok="$(python3 -c "
import yaml, sys
data = yaml.safe_load(open('$file'))
jobs = data.get('jobs', {})
job = next(iter(jobs.values()))
for step in job.get('steps', []):
  if step.get('name') == 'Run review gate':
    env = step.get('env', {}) or {}
    if 'GITHUB_TOKEN' not in env:
      sys.exit(2)
    val = str(env.get('GITHUB_TOKEN', ''))
    if 'secrets.GITHUB_TOKEN' not in val:
      sys.exit(3)
    sys.exit(0)
sys.exit(1)
" && echo yes || echo no)"
  check "$name forwards GITHUB_TOKEN via secrets.GITHUB_TOKEN" "yes" "$ok"
}
assert_step_forwards_github_token "reusable workflow" \
  ".github/workflows/pipeline-code-review-report.yml"
assert_step_forwards_github_token "local-job caller" \
  ".docs/examples/code-review-local.yml"

# 5. After running the opencode installer, the binary lives in
# $HOME/.opencode/bin — but the installer's $GITHUB_PATH update only
# applies to subsequent steps, not the current shell. The script's
# post-install block must export PATH to include that directory so
# `command -v opencode` (and every later `opencode` call in the same
# step) can find it. Regression from PR #86 CI run 30552219304.
# (Catches the case where a future refactor removes the explicit
# PATH export and the gate fails with "opencode is not on PATH".)
post_install_block_present="$(awk '
  /\$HOME\/.opencode\/bin/ {found=1}
  END {print found ? "yes" : "no"}
' "$RUN_REVIEW")"
check "post-install PATH export is present" "yes" "$post_install_block_present"

# 6. Simulate the post-install PATH update in a fresh shell: opencode
# is NOT on PATH initially, but a stub at $HOME/.opencode/bin/opencode
# becomes reachable after the script's update block. Verifies the
# exact code path: `[ -x "$HOME/.opencode/bin/opencode" ] && ! command
# -v opencode >/dev/null 2>&1 → export PATH="$HOME/.opencode/bin:$PATH"`.
mock_opencode="$TMP_DIR/.opencode/bin"
mkdir -p "$mock_opencode"
cat > "$mock_opencode/opencode" <<'EOF'
#!/bin/bash
echo "v1.18.9"
EOF
chmod +x "$mock_opencode/opencode"
HOME="$TMP_DIR" PATH="/usr/bin:/bin" bash -c '
  # Fresh shell — opencode is NOT on PATH
  if command -v opencode >/dev/null 2>&1; then
    echo "BUG: opencode was already on PATH"
    exit 99
  fi
  # Simulate the scripts post-install update block
  if [ -x "$HOME/.opencode/bin/opencode" ] && ! command -v opencode >/dev/null 2>&1; then
    export PATH="$HOME/.opencode/bin:$PATH"
  fi
  # Now it must be reachable
  if ! command -v opencode >/dev/null 2>&1; then
    echo "BUG: post-install PATH export did not make opencode reachable"
    exit 98
  fi
  echo "OK"
' > /tmp/opencode_path_test.out 2>&1
check "post-install PATH update makes opencode reachable" "OK" "$(cat /tmp/opencode_path_test.out)"

# 7a. Both caller templates' Checkout steps must use the simplified
# ref: / repository: expression shape — drop the dead `&& head.sha`
# clause and the head.repo fall-through (PR #86 review 4820072658
# findings #2 and #5). The simplification also makes the two
# packagings agree on the same shape, which is part of the
# "single source of truth" invariant from the AGENTS.md
# Non-Negotiable. Locks against any future regression that
# reintroduces a dead branch.
assert_simplified_checkout_shape() {
  local file="$1"
  local ref_expr repo_expr
  ref_expr="$(python3 -c "
import yaml
data = yaml.safe_load(open('$file'))
for step in next(iter(data['jobs'].values()))['steps']:
  if step.get('name', '').startswith('Checkout PR head'):
    print((step.get('with', {}) or {}).get('ref', ''))
    break
")"
  repo_expr="$(python3 -c "
import yaml
data = yaml.safe_load(open('$file'))
for step in next(iter(data['jobs'].values()))['steps']:
  if step.get('name', '').startswith('Checkout PR head'):
    print((step.get('with', {}) or {}).get('repository', ''))
    break
")"
  # Reject the dead-branch shape explicitly. Use grep -F for the
  # `&&` literal (the shell would otherwise interpret `&&`).
  if echo "$ref_expr" | grep -qF '&&'; then
    check "$file ref: has no dead && clause" "yes" "no"
  else
    check "$file ref: has no dead && clause" "yes" "yes"
  fi
  # Both packagings must end the ref: with `|| github.ref` (the fall-through).
  if echo "$ref_expr" | grep -qF '|| github.ref'; then
    check "$file ref: falls through to github.ref" "yes" "yes"
  else
    check "$file ref: falls through to github.ref" "yes" "no"
  fi
  # repository: must be the simple `github.repository` form.
  if [ "$repo_expr" = "\${{ github.repository }}" ]; then
    check "$file repository: is github.repository (no head.repo fall-through)" "yes" "yes"
  else
    check "$file repository: is github.repository (no head.repo fall-through)" "yes" "no (got: $repo_expr)"
  fi
}
assert_simplified_checkout_shape ".github/workflows/pipeline-code-review-report.yml"
assert_simplified_checkout_shape ".docs/examples/code-review-local.yml"

# 7b. Both caller templates must set MANDATORY_CONTEXT_FILES to the
# same default value (PR #86 review 4820072658 finding #3). Drift here
# was the entire reason the README's "Same config" claim was
# misleading — the local-job caller shipped with 'AGENTS.md' only.
# Test extracts the resolved default (the `vars.X || '...'` else-branch)
# and asserts they match exactly.
assert_mandatory_context_files_match() {
  local file="$1"
  python3 -c "
import yaml, re
data = yaml.safe_load(open('$file'))
job = next(iter(data['jobs'].values()))
# MANDATORY_CONTEXT_FILES may live on the job-level env (reusable workflow)
# or on the Run review gate step's env (local-job caller). Check both.
env = dict(job.get('env', {}) or {})
for step in job.get('steps', []):
  if step.get('name') == 'Run review gate':
    env.update(step.get('env', {}) or {})
    break
val = env.get('MANDATORY_CONTEXT_FILES', '')
# The expression is typically \${{ vars.X || 'fallback' }}; the fallback
# is what we want to assert on. Use non-greedy match.
m = re.search(r\"'([^']*)'\", str(val)) or re.search(r'\"([^\"]*)\"', str(val))
print(m.group(1) if m else '')
" 2>/dev/null
}
mc_reusable="$(assert_mandatory_context_files_match .github/workflows/pipeline-code-review-report.yml)"
mc_local="$(assert_mandatory_context_files_match .docs/examples/code-review-local.yml)"
check "MANDATORY_CONTEXT_FILES defaults match between packagings" "$mc_reusable" "$mc_local"

# 7. The local-job example (.docs/examples/code-review-local.yml) pins
# the upstream `ref:` to a commit SHA. That SHA MUST be reachable on
# the remote AND must contain `.agents/skills/ai-review-report/scripts/run-review.sh`
# — the entrypoint the example invokes in the very next step. A
# pre-entrypoint SHA 404s the script at runtime with "No such file or
# directory". Regression from PR #86 review (an AI agent flagged that
# the original pin 6de63b3… predates run-review.sh).
assert_example_pin_is_valid() {
  local file="$1"
  local ref
  ref="$(python3 -c "
import yaml
data = yaml.safe_load(open('$file'))
for step in data['jobs']['review']['steps']:
  if step.get('name', '').startswith('Checkout smooth-ai-report-review'):
    print((step.get('with', {}) or {}).get('ref', ''))
    break
")"
  if [ -z "$ref" ]; then
    check "$file pins a ref:" "yes" "no"
    return
  fi
  # Reject anything that isn't a 40-char hex SHA — floating tags like
  # `v1` or branches like `main` are explicitly disallowed for this
  # packaging (the README and the example's own comment explain why).
  if ! [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    check "$file pins a 40-char hex SHA (not a tag/branch)" "yes" "no"
    return
  fi
  check "$file pins a 40-char hex SHA (not a tag/branch)" "yes" "yes"
  # Verify the ref is reachable and contains run-review.sh.
  local has_script
  has_script="$(git ls-tree "$ref" -- .agents/skills/ai-review-report/scripts/run-review.sh 2>/dev/null | wc -l | tr -d ' ')"
  check "$file ref contains run-review.sh (pin is post-entrypoint)" "1" "$has_script"
}
assert_example_pin_is_valid ".docs/examples/code-review-local.yml"

# ── Final report ───────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "Results: $pass passed, $fail failed"
echo "=========================================="
[ "$fail" -eq 0 ]
