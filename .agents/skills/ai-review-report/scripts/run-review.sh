#!/bin/bash
# run-review.sh — single-script entrypoint for the OpenCode PR review gate.
#
# Encapsulates the full review gate that .github/workflows/pipeline-code-review-report.yml
# expresses as ~30 inline `run:` blocks. Driven entirely by environment variables and
# $GITHUB_EVENT_PATH — NEVER reads `inputs.*`, `steps.*.outputs`, or GitHub Actions
# expression context. Two packagings drive the same code:
#
#   1. Reusable workflow (recommended for open consumers)
#      .github/workflows/pipeline-code-review-report.yml:
#        env: { OPENCODE_REVIEW_REPORT_PROVIDER, ... }   # from inputs / vars
#        run: bash ${REVIEW_SKILL_DIR}/scripts/run-review.sh
#
#   2. Local-job packaging (for consumers under allowed_actions: "selected")
#      .docs/examples/code-review-local.yml:
#        - uses: actions/checkout@<sha>                  # for the PR
#        - uses: actions/checkout@<sha>                  # for the tooling
#          with: { repository: ..., ref: <pinned-sha>, path: .review-tools }
#        - run: bash .review-tools/.agents/skills/ai-review-report/scripts/run-review.sh
#          env: { OPENCODE_REVIEW_REPORT_PROVIDER: ${{ vars.OPENCODE_REVIEW_REPORT_PROVIDER }}, ... }
#
# Both resolve to the same env-var contract. The local-job packaging is the
# fallback for restrictive Actions policies that refuse a cross-org reusable
# workflow call — see the README "Local-job packaging" section for the policy
# trade-off and the security sign-off the consumer must obtain.
#
# Trigger shapes (read from $GITHUB_EVENT_PATH, NOT from expressions):
#   - pull_request:      pr_number, base_ref/sha, head_ref/sha, head_repo, base_repo
#                        all live on the github.event.pull_request.* payload.
#   - issue_comment:     requires a /ai-review comment by OWNER/MEMBER/COLLABORATOR
#                        against a PR. PR metadata is fetched via gh api.
#   - workflow_dispatch: pr_number is a required input (passed via env PR_NUMBER).
#
# Required env (set by the caller; defaults shown in brackets):
#   GITHUB_EVENT_PATH      — set by GitHub Actions automatically
#   GITHUB_TOKEN           — MUST be forwarded explicitly in the step's
#                             env: block (the runner auto-injects it only
#                             into the GITHUB_ENV, not into bare `run:`
#                             shells). The preflight check at line ~134
#                             fails fast if it's missing. Both packagings
#                             (reusable workflow + local-job caller) set
#                             `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`
#                             on the Run review gate step.
#   GITHUB_REPOSITORY      — set by GitHub Actions automatically
#   GITHUB_SERVER_URL      — set by GitHub Actions automatically
#   GITHUB_RUN_ID          — set by GitHub Actions automatically
#   GITHUB_ACTIONS=true    — set by GitHub Actions automatically
#   OPENCODE_REVIEW_REPORT_PROVIDER  [GEMINI]  — provider selector
#   OPENCODE_REVIEW_REPORT_MODEL_PRIMARY / SECONDARY / ORCHESTRATOR — model chain
#   OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE  [1]   — disable .claude support
#   OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK  [0] — skip AGENTS.md validation
#   OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE  [0] — skip AGENTS.md checks + mandatory context file loading
#   OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT  [100]  — too-many-files threshold
#   OPENCODE_REVIEW_REPORT_CLI_VERSION  [unset → latest] — opencode version pin
#   OPENCODE_REVIEW_REPORT_CONFIG  [unset → committed opencode.json] — LADR-047
#   OPENCODE_REVIEW_REPORT_GEMINI_URL / _COPILOT_URL / _OPENAI_URL — gateway URLs
#   OPENCODE_GEMINI_API_KEY / _COPILOT_API_KEY / _OPENAI_API_KEY — provider keys
#   OPENCODE_ANTHROPIC_API_KEY / _GO_OPENAI_API_KEY / _GO_ANTHROPIC_API_KEY / _OPENROUTER_API_KEY
#   REVIEW_SKILL_DIR  [auto-detected] — path to the skill tree containing
#                         the review scripts and assets/opencode.json. When
#                         unset, the script tries the in-repo path
#                         `.agents/skills/ai-review-report` first, then the
#                         reusable-workflow side-checkout path
#                         `.smooth-ai-review-tools/.agents/skills/ai-review-report`.
#   MANDATORY_CONTEXT_FILES  [built-in list] — space-separated paths loaded
#                         into every review (see find-context-files.sh).
#   AGENTS_MD_EXEMPT_PATHS  ['.docs/release-notes'] — pipe-separated prefixes
#                         that bypass the AGENTS.md validation gate.
#   REVIEWER_INPUT  [unset] — Optional, non-secret operator input (e.g. pr_number
#                         for workflow_dispatch). Mirrors the reusable-workflow
#                         `pr_number` input. Must be a positive integer.
#                         Precedence: when set, REVIEWER_INPUT is authoritative
#                         for `workflow_dispatch` callers. When unset (or for
#                         `pull_request` / `issue_comment` events), the script
#                         reads `pr_number` from the `$GITHUB_EVENT_PATH` JSON
#                         payload's `.pull_request.number` or `.issue.number`.

set -euo pipefail

# Requires Bash >= 4 (associative arrays, ${VAR^^}).
# The workflow's ubuntu-latest runners ship Bash 5; this guard makes local macOS
# runs fail fast instead of producing wrong results from older Bash versions.
# (`mapfile` and `wait -n` are used by `review-in-chunks.sh`, not here.)
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "❌ run-review.sh requires Bash >= 4 (found ${BASH_VERSION:-unknown}). On macOS: 'brew install bash'." >&2
  exit 1
fi

# --- Resolve the script's own directory (REPO_ROOT for the skill tree) -------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# --- Step 0: env-var contract resolution --------------------------------------
# Each variable below is read once at script entry. Precedence is:
#   1. Explicit env (set by the caller's job: env: block or GHA Variables)
#   2. CI default (built-in literal — only valid defaults, not secrets)
# Anything empty after precedence is a configuration bug and is rejected below.

# Toggle defaults
OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE="${OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE:-1}"
export OPENCODE_DISABLE_CLAUDE_CODE="$OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE"
OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK="${OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK:-0}"
OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE="${OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE:-}"
OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT="${OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT:-100}"
if ! [[ "$OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT" =~ ^[0-9]+$ ]] || [ "$OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT" -le 0 ]; then
  echo "⚠️  Invalid OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT='${OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT}' (must be a positive integer). Using default: 100" >&2
  OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT=100
fi
OPENCODE_REVIEW_REPORT_CLI_VERSION="${OPENCODE_REVIEW_REPORT_CLI_VERSION:-}"
# Graph analysis (LADR-049) — opt-in code knowledge graph enrichment.
# When truthy, builds a Tree-sitter-based SQLite graph of the repo and runs
# detect-changes to produce risk-scored function-level analysis. The graph
# data enriches chunk prompts (Phase 2) and aggregation (Phase 4). Phase 1
# only builds the graph and produces the data; chunking/aggregation changes
# land in LADR-050/051/052.
OPENCODE_REVIEW_REPORT_ENABLE_GRAPH_ANALYSIS="${OPENCODE_REVIEW_REPORT_ENABLE_GRAPH_ANALYSIS:-1}"
OPENCODE_REVIEW_REPORT_GRAPH_VERSION="${OPENCODE_REVIEW_REPORT_GRAPH_VERSION:-}"
export OPENCODE_REVIEW_REPORT_ENABLE_GRAPH_ANALYSIS
export OPENCODE_REVIEW_REPORT_GRAPH_VERSION

# Provider / models — non-secret defaults from the reusable workflow's
# env: block. Override with repo/org Variables or job env.
OPENCODE_REVIEW_REPORT_PROVIDER="${OPENCODE_REVIEW_REPORT_PROVIDER:-GEMINI}"
OPENCODE_REVIEW_REPORT_MODEL_PRIMARY="${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY:-gemini-3.1-pro-preview}"
OPENCODE_REVIEW_REPORT_MODEL_SECONDARY="${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY:-gemini-2.5-pro}"
OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR="${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR:-gemini-3-flash-preview}"
export OPENCODE_REVIEW_REPORT_PROVIDER
export OPENCODE_REVIEW_REPORT_MODEL_PRIMARY
export OPENCODE_REVIEW_REPORT_MODEL_SECONDARY
export OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR

# Mandatory context files — copy-installed callers may set this via env. When
# unset, we use the reusable workflow's built-in default. find-context-files.sh
# warns-and-skips on missing paths, so exploratory local runs do not fail.
if [ -z "${MANDATORY_CONTEXT_FILES:-}" ]; then
  MANDATORY_CONTEXT_FILES=$'AGENTS.md\n.docs/nfr/PROJECT_SETUP_AGENTS.md\n.agents/skills/code-review-standards/SKILL.md\n.docs/nfr/TOOL_SETUP_AGENTS.md\n.agents/rules-scoped/backend/testing-standards.instructions.md\n.agents/rules-scoped/backend/dotnet-standards.instructions.md'
fi
export MANDATORY_CONTEXT_FILES
AGENTS_MD_EXEMPT_PATHS="${AGENTS_MD_EXEMPT_PATHS:-.docs/release-notes}"
export AGENTS_MD_EXEMPT_PATHS

# WORK_DIR — the gate's ephemeral scratch space. The downstream scripts
# (review-in-chunks.sh, aggregate-reviews.sh, find-context-files.sh) hardcode
# ci_temp/ paths directly, so this is NOT an overridable contract — it is
# locked to the historical name.
WORK_DIR="ci_temp"
mkdir -p "$WORK_DIR"

# GITHUB_OUTPUT — the workflow uses $GITHUB_OUTPUT for inter-step state. The
# entrypoint replaces that with files under $WORK_DIR so local-job callers do
# not need to plumb GITHUB_OUTPUT through. Each sub-step writes its own
# $WORK_DIR/<name> file as a KEY=VALUE list; later steps source them.
export GITHUB_OUTPUT="$WORK_DIR/github_output"
: > "$GITHUB_OUTPUT"

# --- Step 1: Validate the runtime --------------------------------------------
[ -n "${GITHUB_EVENT_PATH:-}" ] || { echo "❌ GITHUB_EVENT_PATH is not set — this entrypoint requires GitHub Actions context." >&2; exit 1; }
[ -f "$GITHUB_EVENT_PATH" ]   || { echo "❌ GITHUB_EVENT_PATH=$GITHUB_EVENT_PATH does not exist." >&2; exit 1; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "❌ GITHUB_REPOSITORY is not set." >&2; exit 1; }
[ -n "${GITHUB_TOKEN:-}" ]      || { echo "❌ GITHUB_TOKEN is not set (the caller must expose it via env)."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq is required (preinstalled on ubuntu-latest runners; install with 'apt install jq' for local)." >&2; exit 1; }
command -v gh >/dev/null 2>&1  || { echo "❌ gh CLI is required (preinstalled on ubuntu-latest runners; install with 'brew install gh' for local)." >&2; exit 1; }

# --- Step 2: Resolve REVIEW_SKILL_DIR -----------------------------------------
# Two sources, in this order:
#   1. Explicit REVIEW_SKILL_DIR env (a caller can override; mainly for local-job
#      packaging where the skill is checked out at .review-tools/.agents/...).
#   2. The reusable workflow's two-mode resolution: in-repo
#      `.agents/skills/ai-review-report` (copy-install) or the side-checkout
#      `.smooth-ai-review-tools/.agents/skills/ai-review-report` (reusable mode).
#      Both lookups are gated on the script `review-in-chunks.sh` being present
#      — a stale partial checkout fails fast instead of silently no-oping.
resolve_skill_dir() {
  if [ -n "${REVIEW_SKILL_DIR:-}" ] && [ -f "$REVIEW_SKILL_DIR/scripts/review-in-chunks.sh" ]; then
    echo "✓ Using review skill from REVIEW_SKILL_DIR=$REVIEW_SKILL_DIR" >&2
    printf '%s' "$REVIEW_SKILL_DIR"
    return 0
  fi
  if [ -f ".agents/skills/ai-review-report/scripts/review-in-chunks.sh" ]; then
    echo "✓ Using review skill from the repository under review (.agents/skills/ai-review-report)" >&2
    printf '%s' ".agents/skills/ai-review-report"
    return 0
  fi
  if [ -f ".smooth-ai-review-tools/.agents/skills/ai-review-report/scripts/review-in-chunks.sh" ]; then
    echo "✓ Using review skill from .smooth-ai-review-tools side checkout" >&2
    printf '%s' ".smooth-ai-review-tools/.agents/skills/ai-review-report"
    return 0
  fi
  echo "❌ Could not locate REVIEW_SKILL_DIR. Set REVIEW_SKILL_DIR explicitly, or place the skill at .agents/skills/ai-review-report (copy-install) or .smooth-ai-review-tools/.agents/skills/ai-review-report (reusable mode)." >&2
  return 1
}
REVIEW_SKILL_DIR="$(resolve_skill_dir)"
export REVIEW_SKILL_DIR
echo "REVIEW_SKILL_DIR=$REVIEW_SKILL_DIR"

# --- Step 3: Parse the GitHub event payload -----------------------------------
# $GITHUB_EVENT_PATH is the JSON payload GitHub Actions writes for every run.
# Three shapes we handle:
#   - pull_request:    carries head_ref, base_ref, head_sha, base_sha, head_repo, base_repo, pr_number
#   - issue_comment:   issue.number + comment.body — fetch PR metadata via gh api
#   - workflow_dispatch: inputs.pr_number — fetch PR metadata via gh api
# Anything else (e.g. workflow_call from a caller that does not also fire a
# child event) is unsupported by design — the reusable workflow's `if:` gate
# filters them out before this script runs. Local callers must dispatch one of
# the three supported shapes.
EVENT_NAME="$(jq -r 'if type=="object" and has("pull_request") then "pull_request" elif type=="object" and has("issue") and has("comment") then "issue_comment" elif type=="object" and has("inputs") then "workflow_dispatch" else "unsupported" end' "$GITHUB_EVENT_PATH" 2>/dev/null || echo "unsupported")"

# The reusable workflow's gating if: is the canonical source of truth for
# which event shapes are reviewable. Mirror it here so a local-job caller
# invoking this script directly (without the workflow's job-level guard) still
# honours the same author-association check on issue_comment.
should_run() {
  case "$EVENT_NAME" in
    pull_request)
      # Skip dependabot PRs and draft PRs.
      local actor draft
      actor="$(jq -r '.sender.login // .pull_request.user.login // ""' "$GITHUB_EVENT_PATH")"
      draft="$(jq -r '.pull_request.draft // false' "$GITHUB_EVENT_PATH")"
      if [ "$actor" = "dependabot[bot]" ]; then
        echo "Skipping: dependabot PR"
        return 1
      fi
      if [ "$draft" = "true" ]; then
        echo "Skipping: draft PR"
        return 1
      fi
      return 0
      ;;
    issue_comment)
      local assoc body is_pr
      assoc="$(jq -r '.comment.author_association // ""' "$GITHUB_EVENT_PATH")"
      body="$(jq -r '.comment.body // ""' "$GITHUB_EVENT_PATH")"
      is_pr="$(jq -r 'if .issue.pull_request then "true" else "false" end' "$GITHUB_EVENT_PATH")"
      if [ "$is_pr" != "true" ]; then
        echo "Skipping: comment is not on a PR"
        return 1
      fi
      if ! echo "$body" | grep -q "/ai-review"; then
        echo "Skipping: comment does not contain /ai-review"
        return 1
      fi
      case "$assoc" in
        OWNER|MEMBER|COLLABORATOR) return 0 ;;
        *)
          echo "Skipping: comment author association is $assoc (must be OWNER/MEMBER/COLLABORATOR)"
          return 1
          ;;
      esac
      ;;
    workflow_dispatch)
      # workflow_dispatch always runs (the dispatcher controls intent).
      return 0
      ;;
    *)
      echo "❌ Unsupported event shape at $GITHUB_EVENT_PATH (expected pull_request, issue_comment, or workflow_dispatch)." >&2
      return 1
      ;;
  esac
}
if ! should_run; then
  echo "Exiting — review gate should not run for this event."
  exit 0
fi

# --- Step 4: Resolve PR number + head/base SHAs + repos ------------------------
# Output: $WORK_DIR/pr_info has KEY=VALUE entries:
#   pr_number=N, base_ref=REF, base_sha=SHA, head_sha=SHA, head_ref=REF,
#   head_repo=OWNER/NAME, base_repo=OWNER/NAME, force_full_review=true|false
PR_INFO_FILE="$WORK_DIR/pr_info"
: > "$PR_INFO_FILE"

case "$EVENT_NAME" in
  pull_request)
    jq -r '
      [
        "pr_number=\(.pull_request.number)",
        "base_ref=\(.pull_request.base.ref)",
        "base_sha=\(.pull_request.base.sha)",
        "head_ref=\(.pull_request.head.ref)",
        "head_sha=\(.pull_request.head.sha)",
        "head_repo=\(.pull_request.head.repo.full_name)",
        "base_repo=\(.pull_request.base.repo.full_name)",
        "force_full_review=false"
      ] | .[]
    ' "$GITHUB_EVENT_PATH" > "$PR_INFO_FILE"
    ;;
  issue_comment|workflow_dispatch)
    # For these shapes, $GITHUB_EVENT_PATH carries the issue (for issue_comment)
    # or just an inputs blob (for workflow_dispatch). Fetch the PR via gh api.
    if [ "$EVENT_NAME" = "workflow_dispatch" ]; then
      # PR_NUMBER (the dispatch input) must be a positive integer — digit-only
      # validation, never interpolate into a shell assignment without it. The
      # reusable workflow passes it via inputs.pr_number; the local-job packaging
      # forwards it as REVIEWER_INPUT.
      PR_NUMBER_RAW="${REVIEWER_INPUT:-${PR_NUMBER:-}}"
    else
      PR_NUMBER_RAW="$(jq -r '.issue.number // ""' "$GITHUB_EVENT_PATH")"
    fi
    if [ -z "$PR_NUMBER_RAW" ] || ! [[ "$PR_NUMBER_RAW" =~ ^[1-9][0-9]*$ ]]; then
      echo "❌ PR number missing or not a positive integer: '$PR_NUMBER_RAW'" >&2
      exit 1
    fi
    PR_NUMBER="$PR_NUMBER_RAW"
    echo "Fetching PR details for PR #${PR_NUMBER}..."
    PR_JSON="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}")"
    if [ -z "$PR_JSON" ] || [ "$PR_JSON" = "null" ]; then
      echo "❌ Failed to fetch PR details for PR #${PR_NUMBER}" >&2
      exit 1
    fi
    {
      echo "pr_number=${PR_NUMBER}"
      echo "head_ref=$(echo "$PR_JSON" | jq -r .head.ref)"
      echo "base_ref=$(echo "$PR_JSON" | jq -r .base.ref)"
      echo "base_sha=$(echo "$PR_JSON" | jq -r .base.sha)"
      echo "head_sha=$(echo "$PR_JSON" | jq -r .head.sha)"
      echo "head_repo=$(echo "$PR_JSON" | jq -r .head.repo.full_name)"
      echo "base_repo=$(echo "$PR_JSON" | jq -r .base.repo.full_name)"
      echo "force_full_review=true"
    } > "$PR_INFO_FILE"
    ;;
esac

# Source it for current-shell use.
# shellcheck disable=SC1090
. "$PR_INFO_FILE"
echo "PR: #${pr_number} | ${head_repo}:${head_ref} → ${base_repo}:${base_ref}"
echo "Head SHA: ${head_sha:0:7} | Base SHA: ${base_sha:0:7}"
echo "Force full review: ${force_full_review}"

# --- Step 5: Provider / model resolution + opencode health probe --------------
# Mirrors the reusable workflow's `Install Dependencies` step + the
# `Resolve OPENCODE version` + `Restore OPENCODE cache` + `Initialize OPENCODE`
# steps. The probe output (selected_model, all_models_failed) is captured
# locally — later steps read $WORK_DIR/selected_model and $WORK_DIR/all_models_failed.

# 5a. Resolve the selected provider's gateway credentials. This is the
# pre-checkout bootstrap copy (lib/resolve-provider.sh needs REVIEW_SKILL_DIR
# to exist, so the check is inlined here). The same provider→creds mapping
# lives in lib/resolve-provider.sh (used by the rest of the pipeline); this
# is the "did the operator set the right secrets?" fail-fast.
U=""; GW_URL=""
case "${OPENCODE_REVIEW_REPORT_PROVIDER}" in
  COPILOT)               U=OPENCODE_REVIEW_REPORT_COPILOT_URL;  K=OPENCODE_COPILOT_API_KEY ;;
  OPENAI)                U=OPENCODE_REVIEW_REPORT_OPENAI_URL;   K=OPENCODE_OPENAI_API_KEY ;;
  ANTHROPIC)             GW_URL="https://api.anthropic.com";    K=OPENCODE_ANTHROPIC_API_KEY ;;
  OPENCODE-GO-OPENAI)    GW_URL="https://opencode.ai/zen/go/v1"; K=OPENCODE_GO_OPENAI_API_KEY ;;
  OPENCODE-GO-ANTHROPIC) GW_URL="https://opencode.ai/zen/go/v1"; K=OPENCODE_GO_ANTHROPIC_API_KEY ;;
  OPEN_ROUTER)           GW_URL="https://openrouter.ai/api/v1";  K=OPENCODE_OPENROUTER_API_KEY ;;
  GEMINI)                U=OPENCODE_REVIEW_REPORT_GEMINI_URL;   K=OPENCODE_GEMINI_API_KEY ;;
  *) echo "❌ Unknown OPENCODE_REVIEW_REPORT_PROVIDER='${OPENCODE_REVIEW_REPORT_PROVIDER}' (expected GEMINI, COPILOT, OPENAI, ANTHROPIC, OPENCODE-GO-OPENAI, OPENCODE-GO-ANTHROPIC, or OPEN_ROUTER)." >&2; exit 1 ;;
esac
OPENCODE_REVIEW_REPORT_GATEWAY_URL="${GW_URL:-${U:+${!U}}}"
export OPENCODE_GATEWAY_API_KEY="${!K:-}"
export OPENCODE_REVIEW_REPORT_GATEWAY_URL

missing=""
[ -z "${OPENCODE_GATEWAY_API_KEY}" ] && missing="${missing} ${K}"
[ -z "${OPENCODE_REVIEW_REPORT_GATEWAY_URL}" ] && missing="${missing} ${U}"
if [ -n "$missing" ]; then
  echo "❌ Required gateway setting(s) empty/unset for OPENCODE_REVIEW_REPORT_PROVIDER=${OPENCODE_REVIEW_REPORT_PROVIDER}:${missing}" >&2
  echo "   Set them in repo Settings → Secrets and variables → Actions (API keys = Secrets, URLs = Variables)." >&2
  exit 1
fi
echo "✓ Gateway credentials present for provider ${OPENCODE_REVIEW_REPORT_PROVIDER} (${U:+${U}, }${K})"

# 5b. Install ripgrep if absent (cheap, deterministic, no apt lock).
if ! command -v rg >/dev/null 2>&1; then
  echo "Installing ripgrep (prebuilt static binary)..."
  RG_VERSION="14.1.1"
  curl -sSL "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz -C /tmp
  mkdir -p "$HOME/.local/bin"
  mv "/tmp/ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl/rg" "$HOME/.local/bin/rg"
  chmod +x "$HOME/.local/bin/rg"
  export PATH="$HOME/.local/bin:$PATH"
  echo "$HOME/.local/bin" >> "${GITHUB_PATH:-/dev/null}"
  echo "✓ ripgrep installed: $(rg --version | head -1)"
else
  echo "✓ ripgrep already installed ($(rg --version | head -1))"
fi

# 5c. Install opencode — delegated to the shared lib (LADR-048) so every
# install path in this repo honours OPENCODE_REVIEW_REPORT_CLI_VERSION
# through a single implementation. The lib exports $HOME/.opencode/bin on
# PATH and appends to $GITHUB_PATH for follow-up steps. Guarded so a
# missing lib (broken LADR-048 path-coupling) surfaces with the same UX
# as the lib's other failures instead of an opaque "No such file".
if [ -x "$LIB_DIR/install-opencode.sh" ]; then
  bash "$LIB_DIR/install-opencode.sh"
else
  echo "❌ install-opencode.sh not found or not executable at $LIB_DIR/install-opencode.sh" >&2
  echo "   LADR-048 path-coupling broken — every install path must delegate to scripts/lib/install-opencode.sh" >&2
  exit 1
fi
# The lib's PATH export runs in its own subshell and doesn't propagate here.
# Re-export for this script's subsequent opencode invocations (PR #86 fix).
# Unconditionally append to $GITHUB_PATH so follow-up steps also find opencode,
# even on a cache hit (the lib's exit-0 cache-hit branch doesn't touch $GITHUB_PATH).
if [ -x "$HOME/.opencode/bin/opencode" ]; then
  export PATH="$HOME/.opencode/bin:$PATH"
  echo "$HOME/.opencode/bin" >> "${GITHUB_PATH:-/dev/null}"
fi

# 5d. Install opencode.json provider config.
bash "$LIB_DIR/setup-opencode-config.sh"

# 5e. Warm the SQLite store + provider-agnostic health check.
opencode stats >/dev/null 2>&1 || true
bash "$LIB_DIR/opencode-health.sh" || true

# 5f. Resolve provider → provider-id (gemini / openai / …). This is the
# authoritative resolver (matches the post-checkout `Resolve provider/model
# chain` step); the pre-checkout U/K mapping above is just a fail-fast.
bash "$LIB_DIR/resolve-provider.sh"
echo "Resolved provider: ${OPENCODE_REVIEW_REPORT_PROVIDER} → ${OPENCODE_REVIEW_REPORT_PROVIDER_ID:-gemini}"

# 5g. Probe the two-tier review chain (PRIMARY → SECONDARY). On a soft-fail
# (both models unavailable), set all_models_failed=true and post a
# request-changes review from the catch-all step below.
ERROR_PATTERN='NOT_FOUND|not found|404|quota|exhausted|rate.limit|RESOURCE_EXHAUSTED|INVALID_ARGUMENT|API_KEY_INVALID|API key not valid|400|401|authentication failed|provider error|model not found|sqlite-migration'
run_probe() {
  opencode run \
    --agent review \
    --model "${OPENCODE_REVIEW_REPORT_PROVIDER_ID:-gemini}/$1" \
    --format default \
    --log-level WARN \
    "Say 'OK'" 2>&1 || true
}

SELECTED_MODEL_FILE="$WORK_DIR/selected_model"
ALL_MODELS_FAILED_FILE="$WORK_DIR/all_models_failed"
: > "$SELECTED_MODEL_FILE"
echo "false" > "$ALL_MODELS_FAILED_FILE"

echo ""
echo "Primary review:   ${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY}"
echo "Secondary review: ${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY}"
echo "Orchestrator:     ${OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR} (not probed — falls back to the resolved review model at runtime)"
echo ""
output="$(run_probe "$OPENCODE_REVIEW_REPORT_MODEL_PRIMARY")"
if echo "$output" | grep -iqE "$ERROR_PATTERN"; then
  echo "⚠️  Primary review unavailable, quota exceeded, or API key error — trying secondary"
  output2="$(run_probe "$OPENCODE_REVIEW_REPORT_MODEL_SECONDARY")"
  if echo "$output2" | grep -iqE "$ERROR_PATTERN"; then
    echo "⚠️  Both review models failed — will post request-changes review and exit cleanly"
    echo "true" > "$ALL_MODELS_FAILED_FILE"
    : > "$SELECTED_MODEL_FILE"
  else
    echo "✓ Secondary review works"
    echo "$OPENCODE_REVIEW_REPORT_MODEL_SECONDARY" > "$SELECTED_MODEL_FILE"
  fi
else
  echo "✓ Primary review works"
  echo "$OPENCODE_REVIEW_REPORT_MODEL_PRIMARY" > "$SELECTED_MODEL_FILE"
fi

# --- Step 6: PR-head checkout (only for reviewable events) -------------------
# The PR head must be checked out before any `git diff` against the merge base.
# For pull_request: the workflow checked it out before this script runs. For
# issue_comment / workflow_dispatch: re-checkout here using the head_repo
# captured in PR_INFO_FILE (NOT github.repository — that breaks fork re-runs).
#
# The PR head is untrusted (LADR-025 warning) — we only run read-only git/file
# operations on it; opencode is run on the same code but with a locked-down
# `review` agent (read/grep only, no bash/skill/task/edit).
if [ "$EVENT_NAME" != "pull_request" ]; then
  # When the workflow dispatches us, the working directory is already the
  # consumer repo's checkout (set up by the local-job packaging, or by the
  # reusable workflow's `Checkout Code` step). We re-fetch the PR head so
  # `git diff` against merge-base has the right base.
  #
  # GHA only populates GITHUB_HEAD_REF for `pull_request` events — for
  # issue_comment / workflow_dispatch it's always empty. The earlier
  # same-repo no-op short-circuit (the inner `if [ -n
  # "${GITHUB_HEAD_REF:-}" ]` branch) was therefore dead code: the outer
  # `EVENT_NAME != pull_request` guard already excludes the only events
  # where GITHUB_HEAD_REF could be set. Always re-fetch. PR #86 review
  # 4820368853 #3 — drop the dead branch; the comment matches reality.
  echo "Re-checking out PR #${pr_number} head (${head_repo}@${head_ref})..."
  # Cross-repo (fork) PR or non-pull_request event: re-checkout via gh.
  # Persist-credentials=false so the head's git config does not leak the
  # workflow's GITHUB_TOKEN.
  git remote remove upstream 2>/dev/null || true
  git remote add upstream "${GITHUB_SERVER_URL:-https://github.com}/${head_repo}.git"
  git fetch upstream "${head_ref}" --depth=1 || {
    echo "❌ Failed to fetch PR head ${head_repo}@${head_ref}" >&2
    exit 1
  }
  git checkout "FETCH_HEAD" || {
    echo "❌ Failed to checkout FETCH_HEAD" >&2
    exit 1
  }
fi

# --- Step 7: Prepare `upstream` remote + post the all-models-failed review ---
# The base repo's branch must be fetchable for merge-base. The PR-head remote
# (`origin`) is the head_repo; for fork PRs the base is in `upstream`.
BASE_REPO_FOR_UPSTREAM="${base_repo:-${GITHUB_REPOSITORY}}"
git remote remove upstream 2>/dev/null || true
git remote add upstream "${GITHUB_SERVER_URL:-https://github.com}/${BASE_REPO_FOR_UPSTREAM}.git"
echo "✓ upstream → ${GITHUB_SERVER_URL:-https://github.com}/${BASE_REPO_FOR_UPSTREAM}.git"

# All-models-failed soft-fail: post a request-changes review that names the
# failed models and exits cleanly. This is the "Don't silently swallow a
# broken provider" safety net (LADR-021).
if [ "$(cat "$ALL_MODELS_FAILED_FILE")" = "true" ]; then
  echo "All models failed — posting request-changes review"
  PROVIDER="${OPENCODE_REVIEW_REPORT_PROVIDER}"
  CURRENT_SHA="$head_sha"
  LOGS_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-0}"
  cat > "$WORK_DIR/all_models_failed_review.md" <<EOF
## 🤖 OpenCode CLI Code Review - Commit: \`${CURRENT_SHA:0:7}\`

**Status:** ⚠️ Unable to run review — all ${PROVIDER} models unavailable

Both review models failed to respond, typically caused by token quota exhaustion, rate limits, or API key issues:

- Primary review: \`${OPENCODE_REVIEW_REPORT_MODEL_PRIMARY}\`
- Secondary review: \`${OPENCODE_REVIEW_REPORT_MODEL_SECONDARY}\`

**Next Steps:**
- Check the [workflow logs](${LOGS_URL}) for the specific error
- Verify ${PROVIDER} API quota / billing status
- Re-run the review via \`/ai-review\` once resolved

---
*Automated check by OpenCode CLI Code Review*
EOF
  gh pr review "${pr_number}" \
    --request-changes \
    --body-file "$WORK_DIR/all_models_failed_review.md"
  exit 0
fi

# --- Step 8: Determine review type + range ------------------------------------
# Reads previous reviews to decide between:
#   - full          (no prior review, or trigger requires it, or prior commit
#                    is no longer in history)
#   - incremental   (prior review exists at a commit still in history; only
#                    review changes since that commit)
#   - no_changes    (prior review was on the same commit)
# Output: $WORK_DIR/determine_review with KEY=VALUE entries:
#   from_sha, review_type, current_sha, last_full_review_status
DETERMINE_REVIEW_FILE="$WORK_DIR/determine_review"
: > "$DETERMINE_REVIEW_FILE"

# Force full if /ai-review in HEAD commit message, OR force_full_review flag.
FORCE_FULL_FROM_FLAG="$force_full_review"
COMMIT_MESSAGE="$(gh api "repos/${GITHUB_REPOSITORY}/commits/${head_sha}" --jq '.commit.message' 2>/dev/null || echo "")"
FORCE_FULL_FROM_COMMIT="false"
if echo "$COMMIT_MESSAGE" | grep -qiE "/ai-review"; then
  FORCE_FULL_FROM_COMMIT="true"
  echo "✓ /ai-review trigger found in head commit message"
fi

if [ "$FORCE_FULL_FROM_FLAG" = "true" ] || [ "$FORCE_FULL_FROM_COMMIT" = "true" ]; then
  echo "Forcing full review (manual trigger or /ai-review commit)"
  git fetch upstream "${base_ref}" --depth=1 2>&1 || true
  MERGE_BASE="$(git merge-base "upstream/${base_ref}" "$head_sha" 2>/dev/null || echo "$base_sha")"
  {
    echo "from_sha=${MERGE_BASE}"
    echo "review_type=full"
    echo "current_sha=${head_sha}"
    echo "last_full_review_status=none"
  } >> "$DETERMINE_REVIEW_FILE"
else
  REVIEWS="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/reviews?per_page=500" 2>/dev/null || echo "[]")"
  LAST_FULL_REVIEW_STATUS="$(echo "$REVIEWS" | jq -r '
    sort_by(.submitted_at) | reverse |
    [.[] | select(
      (.user.login == "github-actions[bot]") and
      (.body | test("🤖 (Gemini CLI|OpenCode CLI) Code Review")) and
      (.state == "APPROVED" or .state == "CHANGES_REQUESTED")
    )] | first | .state // "none"
  ')"
  LAST_REVIEWED_SHA="$(echo "$REVIEWS" | jq -r 'sort_by(.submitted_at) | reverse | [.[] |
    select(.body | test("🤖 (Gemini CLI|OpenCode CLI) Code Review - Commit:"))] |
    first | .body' | sed -n 's/.*Commit: `\?\([a-f0-9]\{7,40\}\)`\?.*/\1/p' | head -1)"
  if [ -z "$LAST_REVIEWED_SHA" ]; then
    LAST_REVIEWED_SHA="$(echo "$REVIEWS" | jq -r 'sort_by(.submitted_at) | reverse | [.[] |
      select(.body | test("🤖 (Gemini CLI|OpenCode CLI) Code Review"))] |
      first | .body' | sed -n 's/.*| Commit: `\?\([a-f0-9]\{7,40\}\)`\?.*/\1/p' | head -1)"
  fi
  if [ -z "$LAST_REVIEWED_SHA" ]; then
    echo "No previous review found — full review."
    git fetch upstream "${base_ref}" --depth=1 2>&1 || true
    MERGE_BASE="$(git merge-base "upstream/${base_ref}" "$head_sha" 2>/dev/null || echo "$base_sha")"
    {
      echo "from_sha=${MERGE_BASE}"
      echo "review_type=full"
    } >> "$DETERMINE_REVIEW_FILE"
  else
    if [ "${#LAST_REVIEWED_SHA}" -lt 40 ]; then
      EXPANDED="$(git rev-parse "$LAST_REVIEWED_SHA" 2>/dev/null || true)"
      [ -n "$EXPANDED" ] && LAST_REVIEWED_SHA="$EXPANDED"
    fi
    if git rev-parse --verify "${LAST_REVIEWED_SHA}^{commit}" >/dev/null 2>&1; then
      if [ "$LAST_REVIEWED_SHA" = "$head_sha" ]; then
        {
          echo "from_sha=$LAST_REVIEWED_SHA"
          echo "review_type=no_changes"
        } >> "$DETERMINE_REVIEW_FILE"
      else
        {
          echo "from_sha=$LAST_REVIEWED_SHA"
          echo "review_type=incremental"
        } >> "$DETERMINE_REVIEW_FILE"
      fi
    else
      echo "Previous commit $LAST_REVIEWED_SHA not found — full review."
      git fetch upstream "${base_ref}" --depth=1 2>&1 || true
      MERGE_BASE="$(git merge-base "upstream/${base_ref}" "$head_sha" 2>/dev/null || echo "$base_sha")"
      {
        echo "from_sha=${MERGE_BASE}"
        echo "review_type=full"
      } >> "$DETERMINE_REVIEW_FILE"
    fi
  fi
  echo "current_sha=${head_sha}" >> "$DETERMINE_REVIEW_FILE"
  echo "last_full_review_status=${LAST_FULL_REVIEW_STATUS:-none}" >> "$DETERMINE_REVIEW_FILE"
fi
# shellcheck disable=SC1090
. "$DETERMINE_REVIEW_FILE"
echo "Review type: ${review_type} | from: ${from_sha:0:7} → ${current_sha:0:7}"

# --- Step 9: Generate PR diff + file lists ------------------------------------
# $WORK_DIR/changed_files.txt — null-terminated list of files in the diff
# $WORK_DIR/feature_branch_files.txt — all files in the feature branch
# $WORK_DIR/pr_diff.txt — full diff of the feature branch (excluded files
#                         filtered by filter-excluded-files.sh)
# $WORK_DIR/files_changed=N — number of in-scope files
git fetch upstream "${base_ref}" --depth=1 2>&1 || true
MERGE_BASE_FOR_DIFF="$(git merge-base "upstream/${base_ref}" "$head_sha" 2>/dev/null || echo "$base_sha")"
echo "Merge base for diff: ${MERGE_BASE_FOR_DIFF:0:7}"

# All files changed in the feature branch (relative to the base ref).
git diff --name-only -z "${MERGE_BASE_FOR_DIFF}..${head_sha}" > "$WORK_DIR/feature_branch_files.txt"

case "$review_type" in
  no_changes)
    : > "$WORK_DIR/changed_files.txt"
    ;;
  incremental)
    git diff --name-only -z "${from_sha}..${head_sha}" > "$WORK_DIR/files_since_last_review.txt"
    comm -z -12 \
      <(tr '\0' '\n' < "$WORK_DIR/files_since_last_review.txt" | sort -z) \
      <(tr '\0' '\n' < "$WORK_DIR/feature_branch_files.txt" | sort -z) \
      > "$WORK_DIR/changed_files.txt"
    ;;
  *)
    cp "$WORK_DIR/feature_branch_files.txt" "$WORK_DIR/changed_files.txt"
    ;;
esac

# Filter excluded files (lock files, auto-generated, etc.).
if [ -s "$WORK_DIR/changed_files.txt" ]; then
  bash "$SCRIPT_DIR/filter-excluded-files.sh" || true
fi

# Build the diff body for downstream scripts.
: > "$WORK_DIR/pr_diff.txt"
if [ -s "$WORK_DIR/changed_files.txt" ]; then
  case "$review_type" in
    incremental)
      # changed_files.txt is null-delimited. Read it via xargs -0 (which
      # knows how to handle NUL separators) — using `tr '\0' '\n' | xargs -0`
      # would lose the NUL boundaries because xargs -0 expects NULs on its
      # input and tr's output is newline-delimited. The `git diff` runs in
      # a single invocation with all files as args; xargs -0 splits the
      # file list into argument-sized batches.
      xargs -0 -a "$WORK_DIR/changed_files.txt" git diff "${from_sha}..${head_sha}" -- > "$WORK_DIR/pr_diff.txt" 2>/dev/null || true
      ;;
    *)
      xargs -0 -a "$WORK_DIR/changed_files.txt" git diff "${MERGE_BASE_FOR_DIFF}..${head_sha}" -- > "$WORK_DIR/pr_diff.txt" 2>/dev/null || true
      ;;
  esac
fi

# Count files post-exclusion.
if [ -s "$WORK_DIR/changed_files.txt" ]; then
  FILES_CHANGED="$(tr '\0' '\n' < "$WORK_DIR/changed_files.txt" | grep -c . || echo 0)"
else
  FILES_CHANGED=0
fi
echo "Files changed (post-exclusion): ${FILES_CHANGED}"
echo "files_changed=${FILES_CHANGED}" >> "$GITHUB_OUTPUT"
if [ "$FILES_CHANGED" -eq 0 ]; then
  echo "has_changes=false" >> "$GITHUB_OUTPUT"
else
  echo "has_changes=true" >> "$GITHUB_OUTPUT"
fi

# --- Step 10: Block on too-many-files -----------------------------------------
if [ "$FILES_CHANGED" -gt "$OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT" ]; then
  echo "⚠️  Too many files (${FILES_CHANGED} > ${OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT}) — posting REQUEST_CHANGES"
  cat > "$WORK_DIR/too_many_files_review.md" <<EOF
## 🤖 OpenCode CLI Code Review - Commit: \`${head_sha:0:7}\`

**Status:** ❌ BLOCKED - Too many changed files

This PR changes **${FILES_CHANGED}** files, which exceeds the review limit of **${OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT}**. A changeset this large cannot be reviewed reliably.

**Next Steps:**
- Split this PR into smaller, focused PRs (each at or under ${OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT} files).
- Or, if a large changeset is unavoidable, raise the limit by setting the \`OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT\` repository Variable.

---
*Automated check by OpenCode CLI Code Review*
EOF
  gh pr review "${pr_number}" \
    --request-changes \
    --body-file "$WORK_DIR/too_many_files_review.md"
  exit 0
fi

# --- Step 11: Skip if no changes ----------------------------------------------
if [ "$FILES_CHANGED" -eq 0 ]; then
  if [ "$review_type" = "no_changes" ]; then
    SKIP_MSG="This commit has already been reviewed. No new changes detected."
  else
    SKIP_MSG="No changes detected since last review at commit \`${from_sha:0:7}\`."
  fi
  cat > "$WORK_DIR/skip_comment.md" <<EOF
## 🤖 OpenCode CLI Code Review - Commit: ${head_sha:0:7}

✅ ${SKIP_MSG}

---
*Automated review check by OpenCode CLI Code Review*
EOF
  gh pr review "${pr_number}" \
    --comment \
    --body-file "$WORK_DIR/skip_comment.md"
  exit 0
fi

# --- Step 12: PR metadata (title, author, body) -------------------------------
PR_JSON="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}")"
pr_title="$(echo "$PR_JSON" | jq -r .title)"
pr_author="$(echo "$PR_JSON" | jq -r .user.login)"
pr_body="$(echo "$PR_JSON" | jq -r '.body // ""')"
echo "$pr_body" > "$WORK_DIR/pr_description.txt"
echo "PR: ${pr_title} by @${pr_author}"

# --- Step 13: Find context files (mandatory + *AGENTS.md ancestor walk) ------
# When OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE is truthy
# (1/true/yes/on), skip the mandatory context file loading AND the AGENTS.md
# ancestor walk — the review runs without injected context files.
_bypass_mandatory_ctx="${OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE:-}"
case "${_bypass_mandatory_ctx,,}" in
  1|true|yes|on)
    echo "⏭️  Bypassing mandatory context file loading (OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE=${_bypass_mandatory_ctx})"
    echo "has_context=false" >> "$GITHUB_OUTPUT"
    echo "context_file_count=0" >> "$GITHUB_OUTPUT"
    : > "$WORK_DIR/context_files.txt" 2>/dev/null || true
    ;;
  *)
    bash "$SCRIPT_DIR/find-context-files.sh"
    ;;
esac
unset _bypass_mandatory_ctx

# --- Step 13.5: Code graph analysis (LADR-049, opt-in) -----------------------
# When OPENCODE_REVIEW_REPORT_ENABLE_GRAPH_ANALYSIS is truthy, build the code
# knowledge graph and run detect-changes to produce risk-scored function-level
# analysis. The graph data is consumed by:
#   - Phase 2 (LADR-050): per-chunk graph context injection in review-in-chunks.sh
#   - Phase 3 (LADR-051): graph-aware chunk grouping (replaces LLM semantic grouping)
#   - Phase 4 (LADR-052): aggregation enrichment in aggregate-reviews.sh
#
# Graceful degradation: if the graph build or detect-changes fails, we log a
# warning and continue without graph enrichment. The chunked review proceeds
# with its existing logic (directory/semantic grouping, context files only).
_graph_enabled="${OPENCODE_REVIEW_REPORT_ENABLE_GRAPH_ANALYSIS:-1}"
# Tokenize the value via tr so pathological inputs (1true, 1on, 11) align
# with the cache step's `contains()` truthy-set. Three-state result:
# "true" / "failed" / "disabled" — lets LADR-050/051/052 consumers
# distinguish "didn't run" from "ran and failed".
if printf '%s' "${_graph_enabled,,}" | tr -cs '[:alnum:]' '\n' | grep -qxE '1|true|yes|on'; then
  echo ""
  echo "=========================================="
  echo "Code Graph Analysis (LADR-049)"
  echo "=========================================="
  # Build the graph (install code-review-graph if needed, build/update SQLite DB)
  if bash "$LIB_DIR/build-code-graph.sh"; then
    # Run detect-changes to produce risk analysis
    if bash "$LIB_DIR/detect-changes-graph.sh"; then
      # Verify outputs exist and are non-empty
      if [ -s "$WORK_DIR/graph_detect_changes.json" ]; then
        GRAPH_ANALYSIS_AVAILABLE="true"
        echo "✓ Graph analysis available for chunk enrichment"
      else
        echo "⚠️  Graph analysis produced empty output — continuing without graph enrichment"
        GRAPH_ANALYSIS_AVAILABLE="failed"
      fi
    else
      echo "⚠️  detect-changes failed — continuing without graph enrichment"
      GRAPH_ANALYSIS_AVAILABLE="failed"
    fi
  else
    echo "⚠️  Graph build failed — continuing without graph enrichment"
    GRAPH_ANALYSIS_AVAILABLE="failed"
  fi
else
  # Graph analysis disabled — no-op
  GRAPH_ANALYSIS_AVAILABLE="disabled"
fi
export GRAPH_ANALYSIS_AVAILABLE
unset _graph_enabled
# TODO(LADR-050/051/052): GRAPH_ANALYSIS_AVAILABLE is a Phase 1 stub — the
# per-chunk context injection (LADR-050), graph-aware chunk grouping
# (LADR-051), and aggregation enrichment (LADR-052) consumers don't exist
# yet, so this $GITHUB_OUTPUT write is currently a dead signal. Three
# states: "true" = built and ready, "failed" = enabled but build/detect
# failed, "disabled" = explicitly off. Land it in the same commit as the
# first consumer that reads it, or remove the export and the
# $GITHUB_OUTPUT write if the consumers land elsewhere.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "graph_analysis_available=${GRAPH_ANALYSIS_AVAILABLE}" >> "$GITHUB_OUTPUT"
fi

# --- Step 14: Validate AGENTS.md (full reviews only) -------------------------
VALIDATION_PASSED_FILE="$WORK_DIR/validation_passed"
_bypass_agents_md="${OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE:-}"
if [ "$review_type" = "full" ] \
   && [ "${OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK}" != "1" ] \
   && [ "${_bypass_agents_md,,}" != "1" ] \
   && [ "${_bypass_agents_md,,}" != "true" ] \
   && [ "${_bypass_agents_md,,}" != "yes" ] \
   && [ "${_bypass_agents_md,,}" != "on" ]; then
  BASE_SHA_FOR_VALIDATION="${from_sha}" \
  HEAD_SHA_FOR_VALIDATION="${head_sha}" \
  BASE_REF_FOR_VALIDATION="${base_ref}" \
  bash "$SCRIPT_DIR/validate-agents-md.sh" "full"
else
  echo "validation_passed=true" >> "$GITHUB_OUTPUT"
  echo "validation_message=" >> "$GITHUB_OUTPUT"
fi
validation_passed="$(grep '^validation_passed=' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)"
echo "AGENTS.md validation: ${validation_passed}"
unset _bypass_agents_md

# If validation failed on a full review, post a blocking request-changes and
# stop. Mirrors the workflow's `Block PR if AGENTS.md Validation Failed` step.
if [ "$review_type" = "full" ] && [ "$validation_passed" = "false" ]; then
  if [ -f "$WORK_DIR/agents_validation_message.md" ]; then
    cat > "$WORK_DIR/validation_review.md" <<EOF
## 🤖 OpenCode CLI Code Review - Commit: \`${head_sha:0:7}\`

**Review Type:** FULL
**Status:** ❌ BLOCKED - Missing or Invalid AGENTS.md

$(cat "$WORK_DIR/agents_validation_message.md")

---
*Automated validation by OpenCode CLI Code Review*
EOF
    gh pr review "${pr_number}" \
      --request-changes \
      --body-file "$WORK_DIR/validation_review.md"
  fi
  exit 0
fi

# --- Step 15: Detect file types → build expertise statement ------------------
declare -A EXPERTISE_MAP
EXPERTISE_MAP[CS]="an expert .NET and C# code reviewer"
EXPERTISE_MAP[TS]="an expert Angular and TypeScript code reviewer"
EXPERTISE_MAP[JS]="an expert JavaScript and React code reviewer"
EXPERTISE_MAP[GO]="an expert Go code reviewer"
EXPERTISE_MAP[YML]="an expert DevOps and CI/CD reviewer"
EXPERTISE_MAP[PY]="an expert Python code reviewer"
EXPERTISE_MAP[JAVA]="an expert Java code reviewer"
EXPERTISE_MAP[SQL]="an expert database and SQL reviewer"
EXPERTISE_MAP[DOCKER]="an expert Docker and containerization reviewer"
declare -A DETECTED_EXPERTISE

if [ -f "$WORK_DIR/changed_files.txt" ]; then
  while IFS= read -r -d '' file; do
    case "$file" in
      *.cs|*.csproj|*.cshtml) DETECTED_EXPERTISE[CS]=1 ;;
      *.ts|*.tsx) DETECTED_EXPERTISE[TS]=1 ;;
      *.js|*.jsx) DETECTED_EXPERTISE[JS]=1 ;;
      *.go|go.mod|go.sum) DETECTED_EXPERTISE[GO]=1 ;;
      *.yml|*.yaml) DETECTED_EXPERTISE[YML]=1 ;;
      *.py|*.pyw|*.pyx|*.pyi|requirements.txt|requirements*.txt|setup.py|setup.cfg|pyproject.toml|Pipfile|poetry.lock|tox.ini|pytest.ini) DETECTED_EXPERTISE[PY]=1 ;;
      *.java|pom.xml|build.gradle) DETECTED_EXPERTISE[JAVA]=1 ;;
      *.sql) DETECTED_EXPERTISE[SQL]=1 ;;
      Dockerfile*|docker-compose.yml|docker-compose.*.yml|*.dockerfile) DETECTED_EXPERTISE[DOCKER]=1 ;;
    esac
  done < "$WORK_DIR/changed_files.txt"
fi

EXPERTISE_LIST=()
for key in "${!DETECTED_EXPERTISE[@]}"; do
  EXPERTISE_LIST+=("${EXPERTISE_MAP[$key]}")
done
if [ ${#EXPERTISE_LIST[@]} -gt 0 ]; then
  JOINED_LIST="$(printf ', %s' "${EXPERTISE_LIST[@]}")"
  JOINED_LIST="${JOINED_LIST:2}"
  if [[ "$JOINED_LIST" == *", "* ]]; then
    JOINED_LIST="$(echo "$JOINED_LIST" | sed 's/\(.*\), /\1 and /')"
  fi
  EXPERTISE_AREAS="$JOINED_LIST"
else
  EXPERTISE_AREAS="an expert code reviewer"
fi
EXPERTISE_STATEMENT="You are ${EXPERTISE_AREAS} reviewing GitHub PR #${pr_number} (${pr_title}) by @${pr_author} targeting ${base_ref} from ${head_ref}."
echo "Expertise: $EXPERTISE_STATEMENT"

# Detect release branch sync PRs.
REVIEW_MODE="standard"
if echo "$head_ref" | grep -iq '^chore/bnk[uir]-001-sync-'; then
  REVIEW_MODE="sync"
  echo "🔄 Release branch sync — using sync review mode"
fi

# --- Step 16: Skip if blocking review exists (incremental only) ---------------
if [ "$review_type" != "full" ] && [ "${last_full_review_status:-none}" = "CHANGES_REQUESTED" ]; then
  echo "Most recent full review is CHANGES_REQUESTED — skipping incremental review"
  cat > "$WORK_DIR/skip_blocking_review_comment.md" <<EOF
## 🤖 OpenCode CLI Code Review - Commit: \`${head_sha:0:7}\`

⏭️ **Skipping ${review_type} review** - Existing blocking review from @github-actions[bot] requires full review for clearance.

**Why?** An incremental review cannot clear a \`CHANGES_REQUESTED\` blocking state. Only a full review can approve the PR once all issues are resolved.

**Next Steps:**
- Push commits to address the blocking review issues
- A full review will run when you manually request it via \`/ai-review\` or merge to main

---
*Automated check by OpenCode CLI Code Review*
EOF
  gh pr comment "${pr_number}" \
    --body-file "$WORK_DIR/skip_blocking_review_comment.md"
  exit 0
fi

# --- Step 17: Chunked review --------------------------------------------------
SELECTED_MODEL="$(cat "$SELECTED_MODEL_FILE")"
if [ -z "$SELECTED_MODEL" ]; then
  # All-models-failed already handled above. This branch exists to make the
  # type explicit; the script cannot reach here when all_models_failed=true.
  echo "❌ No selected model — review cannot proceed." >&2
  exit 1
fi

bash "$SCRIPT_DIR/review-in-chunks.sh" \
  "${from_sha}" \
  "${head_sha}" \
  "${SELECTED_MODEL}" \
  "${EXPERTISE_STATEMENT}"
TOTAL_CHUNKS="$(grep '^total_chunks=' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)"
TOTAL_CHUNKS="${TOTAL_CHUNKS:-1}"
echo "Total chunks: ${TOTAL_CHUNKS}"

# --- Step 18: Aggregate -------------------------------------------------------
bash "$SCRIPT_DIR/aggregate-reviews.sh" \
  "${TOTAL_CHUNKS}" \
  "${SELECTED_MODEL}" \
  "${review_type}" \
  "${from_sha}" \
  "${FILES_CHANGED}" \
  "${head_sha}" \
  "${EXPERTISE_STATEMENT}" \
  "${last_full_review_status:-none}"

# --- Step 19: Minimize previous reviews (full only) --------------------------
if [ "$review_type" = "full" ] && [ "$validation_passed" != "false" ]; then
  bash "$SCRIPT_DIR/minimize-previous-reviews.sh" \
    "${pr_number}" \
    "${review_type}" \
    "${GITHUB_REPOSITORY}" \
    ""
fi

# --- Step 20: Post review -----------------------------------------------------
# Final shape: $WORK_DIR/final_review.md must exist (fail-closed if missing).
# Then truncate to GitHub's 65,536-char limit and post.
if [ ! -f "$WORK_DIR/final_review.md" ]; then
  echo "❌ No aggregated review found ($WORK_DIR/final_review.md missing) — failing closed (not approving)." >&2
  exit 1
fi
cp "$WORK_DIR/final_review.md" "$WORK_DIR/review_comment.md"

# Truncate if the body exceeds GitHub's 65,536-char limit.
MAX_BODY_SIZE=65000
BODY_SIZE="$(wc -c < "$WORK_DIR/review_comment.md" | tr -d ' ')"
LOGS_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-0}"
echo "Review body size: ${BODY_SIZE} characters (limit: ${MAX_BODY_SIZE})"
if [ "$BODY_SIZE" -gt "$MAX_BODY_SIZE" ]; then
  echo "⚠️  Review body exceeds limit — building compact version"
  sed '/^## 📂 Detailed Chunk Reviews/,$d' "$WORK_DIR/review_comment.md" > "$WORK_DIR/review_before_chunks.md"
  AFTER_CHUNKS=""
  if grep -q "^## 📚 AI Review Context Documents" "$WORK_DIR/review_comment.md"; then
    sed -n '/^## 📚 AI Review Context Documents/,$p' "$WORK_DIR/review_comment.md" > "$WORK_DIR/review_after_chunks.md"
    AFTER_CHUNKS="yes"
  fi
  {
    cat "$WORK_DIR/review_before_chunks.md"
    echo ""
    echo "> **ℹ️ Detailed chunk reviews omitted** — review body exceeded ${MAX_BODY_SIZE} character limit (${BODY_SIZE} chars). The holistic overview above contains all aggregated findings. See [workflow logs](${LOGS_URL}) for full per-file reviews."
    echo ""
    if [ "$AFTER_CHUNKS" = "yes" ]; then
      cat "$WORK_DIR/review_after_chunks.md"
    fi
  } > "$WORK_DIR/review_comment_compact.md"
  COMPACT_SIZE="$(wc -c < "$WORK_DIR/review_comment_compact.md" | tr -d ' ')"
  if [ "$COMPACT_SIZE" -le "$MAX_BODY_SIZE" ]; then
    mv "$WORK_DIR/review_comment_compact.md" "$WORK_DIR/review_comment.md"
  else
    TRUNC_HALF=30000
    {
      head -c "$TRUNC_HALF" "$WORK_DIR/review_comment_compact.md"
      echo ""
      echo "---"
      echo "> **⚠️ Review truncated** — compact version still too large (${COMPACT_SIZE} chars, limit ${MAX_BODY_SIZE}). See [workflow logs](${LOGS_URL}) for full review."
      echo "---"
      tail -c "$TRUNC_HALF" "$WORK_DIR/review_comment_compact.md"
    } > "$WORK_DIR/review_comment.md"
  fi
  rm -f "$WORK_DIR/review_before_chunks.md" "$WORK_DIR/review_after_chunks.md" "$WORK_DIR/review_comment_compact.md"
fi

# Map machine-readable action to gh CLI flag.
REVIEW_ACTION="$(grep '^review_action=' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)"
if [ -z "$REVIEW_ACTION" ]; then
  echo "❌ aggregation produced no review_action — failing closed (not approving)." >&2
  exit 1
fi
case "$REVIEW_ACTION" in
  comment)
    if [ "$review_type" = "incremental" ]; then
      REVIEW_ACTION_FLAG="--comment"
    else
      REVIEW_ACTION_FLAG="--approve"
    fi
    ;;
  request_changes) REVIEW_ACTION_FLAG="--request-changes" ;;
  approve)
    if [ "$review_type" = "incremental" ]; then
      REVIEW_ACTION_FLAG="--comment"
    else
      REVIEW_ACTION_FLAG="--approve"
    fi
    ;;
  *) REVIEW_ACTION_FLAG="--comment" ;;
esac
echo "Posting review: ${REVIEW_ACTION_FLAG}"
gh pr review "${pr_number}" \
  "${REVIEW_ACTION_FLAG}" \
  --body-file "$WORK_DIR/review_comment.md"

echo ""
echo "✅ Review posted successfully"
