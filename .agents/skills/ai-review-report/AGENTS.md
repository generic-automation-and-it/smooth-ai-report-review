---
name: ai-review-report
description: Edit-time context for the `ai-review-report` skill. Load this when modifying SKILL.md, the scripts under scripts/, the opencode.json provider config, the pipline-code-review-report workflow, or any LADR. This file is the "why" — the LADR history, the env-var provenance, the confirmed false-positive PRs, the skill layout, and the supersede chains. SKILL.md is the runtime contract (what the review model must do); this file is the coder's companion.
metadata:
  type: skill-context
  scope: ai-review-report
  applies_to: ["SKILL.md", "scripts/**", "assets/**", "references/**"]
---

# ai-review-report — Editor's Context

## TL;DR

`ai-review-report` is the **generator** half of the PR code-review skill pair (paired with `/ai-review`, the consumer). It runs as a GitHub Actions gate (`.github/workflows/pipline-code-review-report.yml`), reviews PRs in chunks via the `opencode` CLI transport, and posts a structured review. SKILL.md is the runtime contract the review model follows; this file is the edit-time companion — LADR history, env-var provenance, confirmed-FP PR references, and the skill layout that the scripts reference by hardcoded path.

## Non-Negotiables

- **Workflow ↔ script paths are coupled.** The gate invokes skill scripts by hardcoded path (`.agents/skills/ai-review-report/scripts/…`). Moving or renaming a script, the skill folder, or the workflow file (`pipline-code-review-report.yml` — the `pipline` typo is **load-bearing**, see DR-010) silently breaks the gate. Change the workflow YAML and the scripts in the same commit.
- **Skill frontmatter is required for skill activation.** `SKILL.md`'s YAML frontmatter (`name` + `description`) is what Claude Code / Codex / Copilot read to decide *when* to load the skill. Don't strip the frontmatter to "clean up markdown"; the `description` field is the activation trigger.
- **Agent Skills format is the same across all three loaders.** The skill is a directory containing `SKILL.md` (frontmatter + body) and optional `assets/`, `references/`, `scripts/` subfolders — per [agentskills.io](https://agentskills.io). No tool-specific frontmatter fields; what differs is *where* the skill folder lives, not how it's authored.
- **History of decisions lives in references/CHANGELOG.md**, not here. This file is the **narrative** of why current behaviour looks the way it does (LADRs, FP PR refs, supersede chains); references/CHANGELOG.md is the **dated audit trail** of every commit. Don't duplicate it.
- **`AGENTS.md` per-skill is a Claude Code / Codex / Copilot project-doc convention**, not an Agent Skills field. The Agent Skills spec does not define an `AGENTS.md` file inside a skill — the convention this repo adopts is that a sibling `AGENTS.md` is loaded by Claude Code's `AGENTS.md` discovery, by Codex's `AGENTS.md` discovery, and by Copilot's `.github/instructions/*.instructions.md` discovery. Keep that in mind if the Agent Skills spec ever diverges.

## System Context

`ai-review-report` is a CI gate that, when triggered, fetches the PR diff, splits it into chunks, dispatches each chunk to the selected provider's model through the `opencode` CLI transport, then aggregates the per-chunk reviews into a single posted PR review. The model is selected by `OPENCODE_REVIEW_REPORT_PROVIDER` (`GEMINI` / `COPILOT` / `OPENAI` / `OPENCODE-GO-OPENAI` / `OPENCODE-GO-ANTHROPIC`). The scripts under `scripts/` are the only entry points the workflow calls; the `assets/` folder holds runtime config the scripts install; the `references/` folder holds edit-time docs (this file, CHANGELOG.md, and the quality standards).

```mermaid
C4Context
    title ai-review-report — System Context (as a CI component)

    System(skill, "ai-review-report skill", "SKILL.md + scripts/ + assets/ + references/")
    System_Ext(workflow, "pipline-code-review-report workflow", "GitHub Actions gate that invokes the skill scripts by hardcoded path")
    System_Ext(opencode, "opencode CLI", "Provider-agnostic transport; runs `opencode run --agent review --model <provider-id>/<model>`")
    System_Ext(github, "GitHub API", "Diff fetch, review post/minimize, GraphQL")
    System_Ext(provider, "Selected model endpoint", "LiteLLM proxy or native API — Gemini / OpenAI / Copilot / OpenCode Go, publicly reachable from GHA runners")
    System_Ext(reporeview, "Repo under review", "Diff + AGENTS.md context files; opencode reads them via read_file")

    Rel(workflow, skill, "Invokes scripts/* by hardcoded path")
    Rel(skill, opencode, "Spawns for chunk review + aggregation + semantic grouping")
    Rel(skill, github, "Fetches diffs, posts reviews, minimizes old reviews")
    Rel(opencode, provider, "HTTPS")
    Rel(opencode, reporeview, "Reads AGENTS.md / .docs/* context files (--agent review: read/grep/glob/list/external_directory allowed; skill/task/edit/write/bash denied)")
```

## Skill Layout

The skill folder is **referenced by hardcoded path** from the workflow and the scripts themselves. Don't reorganize it without a paired workflow change.

| Path | Type | Loaded by | Purpose |
|------|------|-----------|---------|
| `SKILL.md` | runtime | Claude Code / Codex / Copilot skill loader (frontmatter `description`); also read by the reviewer model via opencode's read tools | The runtime contract — frontmatter, what the model must do, current Decision + Consequences of every accepted LADR, Key Behaviors, decision matrix. |
| `AGENTS.md` (this file) | edit-time | Claude Code / Codex / Copilot project-doc loader | The editor's companion — LADR history with full Context, env-var provenance, confirmed-FP PR refs, supersede chains, skill layout, what the model doesn't need to read every review. |
| `assets/opencode.json` | runtime | `lib/setup-opencode-config.sh` installs into `~/.config/opencode/opencode.json` (global scope, precedence 2) at job start; `setup-opencode-config.sh`'s `is_ours` predicate keys on the managed shape and self-heals drifted personal installs | Provider config — `gemini`, `github-copilot`, `openai`, `go-openai`, `go-anthropic`; locked-down `review` agent (LADR-029); `permission.external_directory: allow` (LADR-025). |
| `assets/review-config.json` | runtime | `scripts/filter-excluded-files.sh` | File-exclusion patterns (lock files, generated code like `*.Designer.cs`). |
| `scripts/` | runtime | The workflow invokes these by hardcoded path | Shell: `review-in-chunks.sh`, `aggregate-reviews.sh`, `find-context-files.sh`, `filter-excluded-files.sh`, `minimize-previous-reviews.sh`, `local-review.sh`, `validate-agents-md.sh`, `test-minimize-reviews.sh`, `test-review-chunk-threshold.sh`, plus `eval/` (LADR-033) and `lib/` helpers (`resolve-provider.sh`, `setup-opencode-config.sh`, `opencode-with-fallback.sh`, `opencode-health.sh`). |
| `references/CHANGELOG.md` | edit-time | Coder reading history | **Dated audit trail** of every commit to the skill. Load when updating the skill or auditing past decisions; not needed for routine execution. Contains the imported history pre-2026-06-01 (legacy names like `.ai/`, `gemini-code-review`, `manual-gemini-cli-code-review.yml` — these do not exist in this repo, preserved as record). |
| `references/knowledge-conventional-contexts-quality.instructions.md` | edit-time | Coder authoring or updating `*_AGENTS.md` files | The repo-wide AGENTS.md quality standards the review/validation prompts apply. |

## Environment Variables — Provenance

The full env-var table the model must follow is in SKILL.md. **What lives here is the provenance and the *why* of the renaming rules** — the per-Variable rules that govern how to add a new provider or change a key.

**Variables vs Secrets — the iron rule.** Gateway **API keys** are credentials → GitHub **Secrets** (never Variables — Variables are plaintext and printable in logs). Gateway **URLs**, the `OPENCODE_REVIEW_REPORT_PROVIDER` selector, the `OPENCODE_REVIEW_REPORT_MODEL_*` ids, the `OPENCODE_REVIEW_REPORT_HEALTH_TIMEOUT`, and `OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT` are non-sensitive config → **Variables**, so they can be retuned without editing the workflow. The exception that proves the rule: **OpenCode Go's fixed public base `https://opencode.ai/zen/go/v1` is hardcoded in `opencode.json`** (LADR-027) — it has no per-deployment URL to retune, so there is no `OPENCODE_GO_*_URL` Variable. The API-key Secrets (`OPENCODE_GO_OPENAI_API_KEY`, `OPENCODE_GO_ANTHROPIC_API_KEY`) remain env-injected.

**Renaming rule — the LADR-032 `OPENCODE_*` → `OPENCODE_REVIEW_REPORT_*` rename.** A non-key config var uses the `OPENCODE_REVIEW_REPORT_` prefix. API-key Secrets keep their `OPENCODE_<PROVIDER>_API_KEY` names — they're provider credentials, not review-report config. When adding a new non-key Variable, the prefix is mandatory; when the repo's GitHub Variables aren't renamed to match, the gate reads them empty and falls back to defaults (Secrets are unaffected). Historical changelog/LADR mentions of old/removed var names are left intact as record.

**Derived Variables.** Two Variables are **derived at runtime** by `lib/resolve-provider.sh` and not user-set: `OPENCODE_REVIEW_REPORT_PROVIDER_ID` (the opencode.json provider key prefixed onto the model — `gemini` / `github-copilot` / `openai` / `go-openai` / `go-anthropic`) and `OPENCODE_REVIEW_REPORT_GATEWAY_URL` / `OPENCODE_GATEWAY_API_KEY` (the selected provider's creds copied to generic names for the credential presence check — note the API-key Secret name does **not** take the `OPENCODE_REVIEW_REPORT_` prefix because it stays a Secret). The provider-agnostic health check is against opencode's `/global/health` (LADR-028), not per-provider gateway probes — so `OPENCODE_GATEWAY_HEALTH_URL`, `OPENCODE_GATEWAY_AUTH_STYLE`, and `OPENCODE_API_HEALTH_OVERRIDE` were removed.

**`OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE` and `OPENCODE_DISABLE_CLAUDE_CODE`.** The first is a GitHub Variable; the second is derived from it. They disable all `.claude` support in opencode to prevent conflicts with Claude Code's `.claude` directory features. Default `1` (disabled). Set `OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE=0` to re-enable `.claude` support.

**`workflow_dispatch` overrides.** The `model_preset` `choice` input and the free-text `model` input both live in the workflow `env:` block. `model_preset` is the **first `||` term** in each expression so it wins over the free-text `model` input and the `OPENCODE_REVIEW_REPORT_*` Variables. Adding/renaming a `model_preset` option requires editing both the `options:` list and the five `env:` expressions (PROVIDER, PROVIDER_ID, three model tiers) in the same commit — they are coupled by the literal option strings.

**Local runs.** `local-review.sh` accepts `--provider` / `OPENCODE_REVIEW_REPORT_PROVIDER`, harvests every provider's credentials from the shell rc files (URL + key for Gemini/Copilot/OpenAI; API key only for the two OpenCode Go surfaces, whose base URL is hardcoded), sources `lib/resolve-provider.sh` to pick + validate the selected pair, and runs the provider-agnostic opencode health check. GHA Variables are CI-only; locally the primary review model is the `--model` arg and the secondary/orchestrator fall back to script defaults (which must be overridden for non-GEMINI providers).

## Architecture Decisions (LADRs)

The LADRs are the **decisions an AI coder would plausibly re-litigate if they didn't read them**. Full Date/Status/Context/Decision/Consequences for each; what survives in SKILL.md is the *Decision + Consequences* in compressed form, with the *Context* stripped because the model doesn't need it at runtime. LADR numbering is append-only — superseded entries (LADR-008, 014, 017, 018) and partially-superseded entries (LADR-023, 024) stay in this file with their full Date/Status/Context/Decision/Consequences/Supersede-by chain. Don't renumber.

### LADR-001: Chunked Review Processing

- **Date**: 2025-10-28
- **Status**: Accepted
- **Context**: Large PRs caused JavaScript heap exhaustion and EventEmitter memory leaks in Gemini CLI.
- **Decision**: Split diffs into chunks (<100KB each) grouped by directory, each as a separate Gemini API call, with final aggregation.
- **Consequences**: Memory-efficient and scalable; multiple API calls increase cost; needs cross-chunk holistic analysis (now runs for every PR per LADR-030).
- **See also**: LADR-010 (adaptive split on large dirs), LADR-011 (semantic grouping for 15+ files), LADR-030 (holistic aggregation now unconditional).

### LADR-002: Two-Tier Review Model Chain

- **Date**: 2025-12-19 (Updated: 2026-05-29)
- **Status**: Accepted
- **Context**: Gemini models may be unavailable due to quota exhaustion, rate limits, or regional issues. Deep chunk review needs a capable model; cheap orchestration (grouping/summary) is split out to its own model (LADR-022).
- **Decision**: Deep chunk-review chain is two-tier: `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY` (default `gemini-3.1-pro-preview`) → `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY` (default `gemini-2.5-pro`). No third tier — the old `auto`/Flash last-resort reviewer was removed; a degraded Flash review is worse than an honest "models down". If BOTH review models fail the startup probe, soft-fail per LADR-021. Models come from GitHub **Variables** (literal defaults); `workflow_dispatch` input overrides the primary. The startup probe tests only these two review models (the orchestrator is not probed — LADR-022). Error detection includes quota/rate-limit patterns.
- **Consequences**: High reliability for the substantive review; slightly longer startup due to model testing. Independent of the orchestrator tier, which can be retuned without touching the review chain.

### LADR-003: Context-Aware Review with On-Demand File Access

- **Date**: 2025-11-15
- **Status**: Accepted
- **Context**: Including full `*AGENTS.md` contents in prompts caused size bloat and false positives (Gemini flagged issues without seeing full context).
- **Decision**: Use `--yolo` flag (legacy: gemini-cli) → now realized as the `review` agent's read/grep/glob/list/external_directory allow-list (LADR-025/029). Pass file paths only, instruct Gemini to READ files before flagging Critical/High issues.
- **Consequences**: No prompt size increase; reduced false positives; slightly slower when many files need verification.

### LADR-004: Incremental Reviews Must Never Approve

- **Date**: 2025-11-20
- **Status**: Accepted
- **Context**: Bug where incremental reviews approved PRs, bypassing blocking states from full reviews (PR #3946 — the original confirmed-FP incident).
- **Decision**: Incremental reviews MUST always use `--comment`, never `--approve`. Only full reviews can approve.
- **Consequences**: Prevents bypassing unresolved Critical/High issues; requires manual approval when incremental finds no new issues.
- **Confirmed false positive if violated**: PR #3946.

### LADR-005: Two-Part Aggregation Output

- **Date**: 2025-11-28
- **Status**: Accepted
- **Context**: Single aggregation mixed executive summary with detailed analysis, creating visual clutter.
- **Decision**: Split using `DETAILED_SECTION_MARKER` delimiter. Part 1 = executive summary (always visible). Part 2 = holistic cross-chunk analysis (collapsible with chunk details).
- **Consequences**: Clean overview for decision-makers; requires the model to follow the two-part format.

### LADR-006: Test File Pairing with Implementation Files

- **Date**: 2025-12-05
- **Status**: Accepted
- **Context**: Tests and implementation reviewed in separate chunks, making coverage verification difficult.
- **Decision**: Map test files to implementation files (`.NET: *Test.cs→*.cs`, `Frontend: *.spec.ts→*.ts`) and group them in the same chunk.
- **Consequences**: Tests reviewed alongside code they validate; slightly larger chunks.

### LADR-007: Markdown-Based Separator Instead of JSON

- **Date**: 2025-12-01
- **Status**: Accepted
- **Context**: JSON output from the model frequently had schema violations (unescaped quotes, trailing commas).
- **Decision**: Use markdown with `DETAILED_SECTION_MARKER` delimiter, parsed with `sed`/`grep`.
- **Consequences**: Reliable parsing; less structured than JSON but works well for LLM outputs.

### LADR-008: Unified Concurrency Group (Superseded)

- **Date**: 2026-01-02
- **Status**: **Superseded by LADR-009**.
- **Context**: Race condition where manual and automated reviews ran concurrently on the same commit.
- **Decision**: All events use the same concurrency group.
- **Why superseded**: Caused `/ai-review` comments to cancel in-progress automated reviews.

### LADR-009: Selective Concurrency

- **Date**: 2026-01-02
- **Status**: Accepted
- **Context**: LADR-008 caused reviews to be cancelled mid-execution.
- **Decision**: Only `pull_request` events share concurrency group `ai-review-{pr_number}`. Other events (`issue_comment`, `workflow_dispatch`) use unique `{run_id}-{run_attempt}` per run. `pull_request_target` trigger was removed (caused duplicate runs on PR creation).
- **Consequences**: Automated reviews always complete; manual triggers run independently; rapid commits still cancel each other.

### LADR-010: Adaptive Chunk Splitting by Directory Depth

- **Date**: 2026-02-17
- **Status**: Accepted
- **Context**: Large directories (e.g., ProsmarBunkering.Web with 13 files, ~130KB diff) exceeded Gemini API limits. `MAX_CHUNK_SIZE` was declared but never enforced.
- **Decision**: After initial grouping, calculate cumulative diff size per group. If exceeding 100KB, re-group by next directory level, up to 5 iterations. Single-file groups kept as-is.
- **Consequences**: Prevents API failures on large groups; uses natural directory structure; adds minor `git diff | wc -c` overhead.

### LADR-011: Semantic Business Context Grouping via LLM

- **Date**: 2026-02-17 (Threshold raised 2026-05-28)
- **Status**: Accepted
- **Context**: Directory-based chunking splits cross-cutting features into isolated chunks (e.g., IMOS change across 3 directories reviewed separately). Threshold was raised from 8 → 15 on 2026-05-28 after PR #5326 (10 files) over-split into 6 chunks with tiny per-chunk output, hitting GitHub's 65KB review-body limit.
- **Decision**: LLM pre-processing groups files by business context for PRs with 15+ files. 60-second timeout, strict validation (every file exactly once), falls back to directory grouping on failure. Includes "logic moved" detection: when code is removed from one file and similar code added in another, both are grouped together.
- **Consequences**: Cross-cutting features reviewed together for medium-to-large PRs; small PRs (<15 files) skip the extra semantic-grouping API call (~10-30s saved) and use cheaper directory grouping. Non-deterministic grouping above the threshold; LADR-010 applies as safety net.
- **Confirmed false positive if threshold is too low**: PR #5326 (10 files, 6 tiny chunks).

### LADR-012: Confidence Tagging and Verification-Incomplete Suppression

- **Date**: 2026-03-10
- **Status**: Accepted
- **Context**: The model frequently flagged test coverage or implementation concerns for files it never received in its chunk, producing false positives. Downstream tooling (`/ai-review:analyse`) had no way to distinguish verified findings from speculative ones.
- **Decision**: (1) Chunk prompts instruct the model to suppress findings for files not in the chunk at Critical/High/Medium — only Low (informational) allowed. (2) Every finding must be tagged `[VERIFIED]` (code seen in diff or via `read_file`) or `[SPECULATIVE]` (inferred from partial context). (3) Aggregation prompt preserves tags and prevents elevating speculative findings.
- **Consequences**: Reduces false positives from partial-context inference; enables downstream auto-downgrading of speculative findings; adds ~2 tokens per finding for the tag.
- **Grammar reference** (used by the eval harness, LADR-033): only `[VERIFIED]` Critical/High/Medium count; `[SPECULATIVE]` and "None found" never count.

### LADR-013: Migration/Schema Chunk Detection

- **Date**: 2026-03-11
- **Status**: Accepted
- **Context**: EF Core migration files and raw SQL scripts have fundamentally different review concerns than application code (reversibility, existing data handling, nullable column safety, index locking) — but previously received the standard code review prompt, causing the model to focus on correctness and security instead of migration-specific risks.
- **Decision**: Detect chunks containing `*.sql`, `*_Migration.cs`, or `*/Migrations/*.cs` files and route them to a migration-focused prompt. Migration detection takes priority over doc-only detection in the three-way branch.
- **Consequences**: Migration PRs get actionable feedback on rollback paths and data safety. Standard code review items (performance, security, test coverage) are intentionally replaced — if a chunk mixes migration and application code, migration review applies.

### LADR-014: RTK Token Optimization for Gemini CLI

- **Date**: 2026-03-24
- **Status**: **Superseded by LADR-023** (RTK Gemini hook is specific to `@google/gemini-cli`; opencode transport is incompatible with it).
- **Context**: Gemini CLI `--yolo` mode reads files via tool calls that return full uncompressed content, consuming tokens on large files. RTK proxies these tool outputs through intelligent filtering and compression.
- **Decision**: Install RTK in CI pipeline and configure the Gemini hook (`rtk init -g --gemini --auto-patch --hook-only`). RTK intercepts Gemini's `read_file` and shell tool calls, compressing outputs before they reach the model context.
- **Consequences** (at the time): 60-90% token reduction on tool outputs; adds ~5s install overhead; single Rust binary with zero runtime dependencies; transparent to review scripts.
- **Why superseded**: After the LADR-023 transport migration the workflow no longer invokes `@google/gemini-cli`. RTK's Gemini hook only intercepts that binary's tool I/O — opencode handles its own tool calls outside RTK's interception path. The chunked architecture (LADR-001) already bounds prompt size to <100KB per chunk, which is what RTK's compression was protecting; per-PR token cost is monitored after the migration to confirm spend stays bounded.

### LADR-015: Strengthened Critical/High Verification and Diff Integrity Checks

- **Date**: 2026-03-23
- **Status**: Accepted
- **Context**: PR #4787 review produced false positives: (1) corrupted/large diff caused the model to flag "review blocked" as Critical, (2) the model flagged a symbol as still present despite it being removed in an earlier commit on the same branch — `read_file` would have shown its absence.
- **Decision**: Two changes: (a) Chunk prompt now requires Critical/High verification to confirm the flagged symbol exists in the **current file state** via `read_file`, not just in the diff hunk. (b) Per-file diff integrity check warns the model when a file's diff exceeds `MAX_CHUNK_SIZE`, instructing it not to raise Critical/High without `read_file` verification. Additionally, `/ai-review:analyse` auto-recommends skip for `[SPECULATIVE]`-tagged findings.
- **Consequences**: Reduces false positives from stale diff context and large/truncated diffs; adds minor per-file size check overhead; speculative findings no longer require manual triage.
- **Confirmed false positive if violated**: PR #4787.

### LADR-016: Release Branch Sync Review Mode

- **Date**: 2026-04-07
- **Status**: Accepted
- **Context**: Release branch sync PRs (`chore/bnk[uir]-001-sync-*`) aggregate already-reviewed code from multiple PRs. Standard review flagged style, test coverage, and performance on code that was already reviewed — generating noise and wasting reviewer time.
- **Decision**: Detect sync branches by head ref prefix (case-insensitive). Pass `REVIEW_MODE=sync` to chunk and aggregation scripts. Sync mode narrows chunk prompts to merge conflict errors, cross-PR breaking combinations, config drift, and migration ordering conflicts. Aggregation holistic analysis is similarly narrowed. Severity threshold raised: only Critical and High used, everything else is Low (informational).
- **Consequences**: Sync PRs get focused, actionable reviews instead of noise. Trade-off: genuine issues in already-reviewed code won't be caught (acceptable because original PR review should have caught them).

### LADR-017: Single-Chunk Aggregation Short-Circuit

- **Date**: 2026-05-12
- **Status**: **Superseded by LADR-030** (the holistic aggregation now runs for every PR, including single-chunk ones).
- **Context**: For PRs that produce a single chunk, the aggregation step still ran the full "Holistic Cross-Chunk Analysis" call — a Pro-tier model with `--yolo` `read_file` access and a ~430-line prompt template. Observed cost on PR #5179 (1 chunk): chunk review 8 min, aggregation 15 min (total 25 min). With one chunk there is by definition no *cross-chunk* surface to analyse, so the holistic pass is pure overhead and re-derives findings that already exist in the chunk review.
- **Decision**: When `TOTAL_CHUNKS=1`, skip the full holistic-aggregation call. Instead: (1) parse `🔴 [VERIFIED] Critical:` and `🟠 [VERIFIED] High Priority:` lines from the chunk review to determine the decision programmatically; (2) make one small targeted call on the ORCHESTRATOR model (LADR-022) — with a minimal prompt asking for 2-3 sentences describing what the PR changes and why. This fills `## 📋 Overall Summary` with a real narrative instead of a canned message. If the targeted call fails, fall back to the canned message. Placeholder filter uses case-insensitive regex that handles quoted, bolded, and period-terminated "None found" variants. Only `[VERIFIED]` findings can block — `[SPECULATIVE]` cannot promote to a blocking decision (consistent with LADR-012/LADR-015). LADR-004 enforcement preserved: incremental reviews always resolve to `COMMENT`, never `APPROVE`.
- **Consequences** (at the time): Eliminated the ~15-min holistic call for single-chunk PRs while preserving the readable summary.
- **Why superseded**: The cost premise no longer held once LADR-022 moved aggregation onto the cheap orchestrator/Flash model (~30 s, not 15 min on Pro), and skipping the holistic pass left small PRs without the aggregated Overall Summary / Issues Summary / Suggested Fixes high-level report users expected. See LADR-030.
- **Confirmed false positive if reverted**: PR #5179 (cost); PR #10 (3 files → single chunk via `OPENCODE_REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING=10` produced placeholders only).

### LADR-018: Flash Model for Aggregation Step

- **Date**: 2026-05-12
- **Status**: **Superseded by LADR-022** (aggregation now uses the explicit `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR`).
- **Context**: LADR-002 specifies a Pro-tier model for the review job. The same model was used for both chunk reviews (analytical) and the aggregation summary (summarisation). Aggregation is summarising chunk reviews into a PR-level overview and emitting a recommendation — not deep analysis. Pro-tier latency on the aggregation step (~15 min observed) is wasted on a task a Flash model can do in 2-3 min.
- **Decision**: Derive an `AGGREGATION_MODEL_ID` from `OPENCODE_MODEL_ID` inside `aggregate-reviews.sh`: `gemini-3*-pro*` → `gemini-3-flash-preview`, `gemini-2.5-pro*` → `gemini-2.5-flash`, anything else → pass-through. Chunk-review model selection (LADR-002 fallback chain) is unchanged. The `**Model:**` field in the posted review comment continues to show the chunk-review model (Pro), since chunk reviews drive the substantive findings — the Flash aggregation model is an implementation detail.
- **Consequences** (at the time): ~3-5× faster aggregation on multi-chunk PRs. No quality loss because aggregation is structured summarisation, not analysis. If the Flash variant is not available the LADR-002 fallback chain doesn't apply at the aggregation step — failure hits the `❌ Summary generation failed - using fallback` path.
- **Why superseded**: The `auto` derivation was replaced by an explicit, independently-tunable orchestrator Variable; the proxy-router dependency was removed.

### LADR-019: No `read_file` Access at Aggregation Step

- **Date**: 2026-05-12
- **Status**: Accepted
- **Context**: LADR-003 grants `read_file` access to *all* model calls. The aggregation prompt invited the model to `read_file` during the holistic pass to "verify concerns before flagging" and to "upgrade `[SPECULATIVE]` tags to `[VERIFIED]`". In practice this caused duplicate file reads: chunk reviews already performed `read_file` verification for every Critical/High finding (per Key Behavior "Critical/High symbol verification"), so the aggregation re-reads the same files to re-check the same findings. Multiple tool-call round-trips at Pro-tier latency contributed substantially to the 15-min aggregation time.
- **Decision**: Strip `read_file` invitations from the aggregation prompt template. The prompt instructs the model that file-system verification is not its job. Confidence-tag promotion (`[SPECULATIVE]` → `[VERIFIED]`) is removed from the aggregation responsibilities — chunk reviews own it.
- **Consequences**: Fewer agentic round-trips at aggregation. Quality preserved because the *verification* layer is unchanged — chunk reviews still do the file-state checks per LADR-015. Trade-off: if a chunk review missed a verification opportunity, the aggregation can no longer rescue it. Acceptable: missing verification at chunk level is a chunk-review prompt bug to fix at that layer, not papered over downstream.

### LADR-020: Skip Integration / DI / Test-Coverage Sections on Small PRs

- **Date**: 2026-05-12
- **Status**: Accepted
- **Context**: The holistic aggregation prompt unconditionally requested Integration, Dependency Injection Analysis, and Test Coverage Analysis sections for `full` reviews. These are intra-chunk concerns — chunk-review prompts already evaluate them per chunk for the changed files. Asking the aggregation model to re-derive them for 1-2 chunk PRs is duplicate work with low marginal value.
- **Decision**: Gate the Integration / DI / Test Coverage sections of the holistic prompt on `REVIEW_TYPE=full AND TOTAL_CHUNKS > 2`. Combined into a single guarded block (previously two adjacent `if` statements with identical condition).
- **Consequences**: Smaller prompt and faster aggregation on small PRs. For 3+ chunk PRs the sections still run, because cross-chunk integration/DI consistency is a genuine concern when changes span many files. No loss of coverage on 1-2 chunk PRs because the underlying chunk review already evaluated those concerns on the changed files.

### LADR-021: All-Models-Failed Posts Request-Changes Instead of Failing Workflow

- **Date**: 2026-05-25
- **Status**: Accepted
- **Context**: When both review models (primary + secondary per LADR-002) failed during the startup probe — typically due to upstream token quota exhaustion, key/billing problems, or a regional outage — the workflow exited with `exit 1`. The resulting red ❌ gate check blocked merges even though the failure was infrastructure-side, not a code defect. Observed in run 26387093767: every model returned a quota/auth error and the job failed with no review posted.
- **Decision**: On all-models-failed, the model-test step sets `all_models_failed=true` (and `selected_model=none`) and completes successfully. A new step `Post Request Changes - All Gemini Models Failed`, gated on `steps.gemini_model_test.outputs.all_models_failed == 'true'`, posts a `--request-changes` review naming the failed models and pointing to the workflow logs. All downstream side-effect steps (`Validate AGENTS.md`, `Block PR if AGENTS.md Validation Failed`, `Skip Review Due to Blocking Review`, `Review PR in Chunks`, `Aggregate Reviews`, `Minimize Previous Gemini Reviews`, `Post Review Comment`, `Post Error Comment`) are gated with `steps.gemini_model_test.outputs.all_models_failed != 'true'` so they no-op on this path. The job exits green.
- **Consequences**: Quota / API-key incidents surface as a request-changes review (the existing "Failed → request-changes" branch of the decision matrix in Key Behaviors) rather than a red workflow check. Re-running once the upstream issue is resolved (via `/ai-review`) clears the request-changes state through a fresh full review. Trade-off: a green workflow check no longer guarantees a Gemini review ran — reviewers must read the posted review body to see whether substantive findings or an infrastructure failure produced the request-changes verdict.
- **Confirmed run**: 26387093767.

### LADR-022: Explicit Orchestrator Model for Non-Analytical Calls

- **Date**: 2026-05-26 (Updated: 2026-05-29)
- **Status**: Accepted (supersedes LADR-018)
- **Context**: Every PR runs two non-analytical calls — semantic grouping (`review-in-chunks.sh`) and aggregation/summary (`aggregate-reviews.sh`). Both are classification/summarisation, not code analysis, so they belong on a cheap model. The original design used an `auto` logical label derived from the review model via `get_aggregation_model()`, which hid the actual model behind proxy-router behaviour and coupled the cheap tier to the review tier.
- **Decision**: Replace the `auto` derivation with an explicit, independently-tunable `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR` (default `gemini-3-flash-preview`, a GitHub Variable). All non-chunk-review calls run on it. Its fallback is the **resolved review model** (the chunk chain's winner), so if the orchestrator is down the summary still runs on a known-healthy model. The orchestrator is intentionally **not** probed at startup (its fallback is already proven by the LADR-002 probe). Removed: the `auto` logical name, `resolve_model()`'s `auto`→flash mapping, and `get_aggregation_model()`.
- **Consequences**: Lower per-PR cost without changing review quality (analysis stays on the Pro review chain). The `**Model:**` field shows the resolved review model. Deterministic — no reliance on a proxy router to interpret `auto`. Orchestrator and review tiers tune independently.

### LADR-023: opencode as Transport for Gemini Models

- **Date**: 2026-05-28
- **Status**: Accepted (now partially superseded by LADR-029 — chunk review now passes `--agent review` rather than the default `build` agent)
- **Context**: Google's public-tier Gemini CLI (`@google/gemini-cli`) stops serving Pro/Ultra/free accounts on 2026-06-18. Enterprise Gemini Code Assist licences are exempt; we use the public-tier endpoint behind an internal LiteLLM proxy, so the deadline applies to us. Antigravity CLI (Google's official replacement) is OAuth-only with no `--model` flag in print mode — not viable for headless CI on self-hosted runners. Pi (`@earendil-works/pi-coding-agent`) was viable but smaller ecosystem. opencode (`opencode-ai`, MIT, 166k stars, 900 contributors) was chosen.
- **Decision**: Use `opencode` as the CLI transport. Gemini *models* unchanged — LADR-002 two-tier review chain and LADR-022 (explicit orchestrator) preserved at the call-site level. The provider is declared in `assets/opencode.json` with `baseURL={env:OPENCODE_REVIEW_REPORT_GEMINI_URL}` and `apiKey={env:OPENCODE_GEMINI_API_KEY}`. The `litellm-gemini` provider name was later renamed to `gemini` (BNKI-001 PR #1) and the per-provider `baseURL` placeholders were removed (each `@ai-sdk/*` now uses its native API base; a relaying-gateway provider with its own baseURL may be added separately). Originally passed NO `--agent` flag — that stance was superseded by LADR-029 (custom `review` agent with no pinned `model` field, so `--model` still wins). The `gemini` provider registers four physical model ids (`gemini-3.1-pro-preview`, `gemini-2.5-pro`, `gemini-3-flash-preview`, `gemini-2.5-flash`). The old `auto` logical name and its `resolve_model()` mapping were removed (LADR-022) — every call site now passes an explicit model id.
- **Consequences**: Unblocks the 2026-06-18 EOL deadline. Posted review still surfaces the chunk-review model id in `**Model:**`. The workflow filename is `pipline-code-review-report.yml` (the comment trigger is `/ai-review`). LADR-015 file-state verification works via the `review` agent's read tool.

### LADR-024: Single Gateway Provider + Local Reachability Preflight

- **Date**: 2026-05-29
- **Status**: **Partially superseded by LADR-026 (single-provider → env-based selection) and LADR-028 (the local gateway reachability preflight is replaced by the opencode-server health check)**. Only the `timeout`-shim part remains in force.
- **Context**: Both CI and local reviews originally ran through the internal LiteLLM gateway (`litellm-gemini` provider) on `OPENCODE_REVIEW_REPORT_GEMINI_URL` + `OPENCODE_GEMINI_API_KEY`. The gateway is on a private network: off-VPN, every `opencode run` hung indefinitely (the macOS `timeout` shim killed only the bash wrapper, orphaning opencode) — a silent multi-minute "deadlock".
- **Decision**: One provider everywhere — `litellm-gemini`. `local-review.sh` (a) harvested `OPENCODE_GEMINI_*` from the shell rc files, and (b) ran an 8s gateway `/health` preflight before any review work, aborting with a "connect to VPN" message if unreachable. The `timeout` shim was rewritten to run each call in its own process group and `kill -KILL` the group on expiry, so genuine hangs are bounded (60s grouping / 300s chunk) and no orphans leak.
- **Consequences** (still in force for the `timeout`-shim half): Local runs need network access to the resolved endpoint. Genuine hangs are bounded; no process orphans.
- **Why partially superseded**: The "one provider everywhere" stance was reversed by LADR-026 — the provider is now env-selectable and the endpoint can be a LiteLLM proxy *or* a provider's native API. The per-provider reachability preflight was itself later removed by LADR-028 in favour of the provider-agnostic opencode-server `/global/health` check (which does **not** pre-empt a private-network/VPN hang — the process-group `timeout` shim still bounds any hang during the actual model calls).

### LADR-025: Allow `external_directory` reads (headless `--yolo` equivalent)

- **Date**: 2026-06-01
- **Status**: Accepted
- **Context**: Chunks intermittently failed with `## ⚠️ Review Failed for Chunk`. The chunk prompt lists context-file paths and instructs the model to `read_file` each; context includes in-repo dot-paths (`.github/*AGENTS.md`, `.docs/nfr/*`, `.agents/rules-scoped/*`). opencode's `read` permission defaults to `allow`, but **`external_directory` defaults to `ask`** — and in non-interactive `opencode run` there is no responder, so opencode **auto-rejects** those reads → the model call errors/empties → the chunk is marked failed → the fail-closed net forces REQUEST_CHANGES even on clean PRs. The old `@google/gemini-cli` used `--yolo` (unconditional FS access) and had no such gate — this regressed in LADR-023.
- **Decision**: Add a top-level `"permission": { "external_directory": "allow" }` block to `assets/opencode.json` — the headless equivalent of `--yolo` for the one gate that was failing. Applies to the default `build` agent used in `run` mode. `setup-opencode-config.sh`'s self-heal `is_ours` predicate was widened to treat `permission` as part of our managed-config shape. The review pipeline only reads — never edits or runs bash — so allowing reads is safe.
- **Consequences**: Chunks reliably load context files; LADR-015 verification reads work; clean PRs can resolve to APPROVE again (as pre-migration). Trade-off: the model may read any in-repo path during a review — acceptable (same effective access as the prior `--yolo`).
- **Update (LADR-029)**: `external_directory: allow` is now ALSO set on a read-only `review` agent (`--agent review`) that additionally denies skill/task/edit/bash. The original "tighter scoping later" suggestion was realized.

### LADR-026: Env-Selected Provider (GEMINI / COPILOT / OPENAI)

- **Date**: 2026-06-06
- **Status**: Accepted (supersedes the single-provider stance of LADR-024; extended by LADR-027 for OpenCode Go)
- **Context**: `assets/opencode.json` already *declared* three providers (`litellm-gemini`, `github-copilot`, `openai`) but only `litellm-gemini` was ever routed to. Teams wanted to retarget the gate at Copilot/OpenAI gateways — or at a provider's native API rather than a LiteLLM proxy — without editing the workflow.
- **Decision**: Promote the providers from config-only to runtime-selectable via the `OPENCODE_REVIEW_REPORT_PROVIDER` Variable (default `GEMINI`). `lib/resolve-provider.sh` is the single source of truth: it maps the selector → `OPENCODE_REVIEW_REPORT_PROVIDER_ID` (the opencode provider key prefixed onto the model), copies the selected provider's URL/key into generic `OPENCODE_REVIEW_REPORT_GATEWAY_URL`/`_API_KEY` (for the credential presence check), and **fails fast** when the selected provider's creds are missing or the `OPENCODE_REVIEW_REPORT_MODEL_*` chain doesn't match the provider's model family (GEMINI → `gemini-*`, others → `gpt-*`). (Health checking was later moved out of the resolver to the provider-agnostic opencode server — LADR-028.) All call sites prefix `${OPENCODE_REVIEW_REPORT_PROVIDER_ID}/<model>`; the workflow exports all three credential pairs at job scope; `local-review.sh` harvests all three pairs and sources the same resolver.
- **Consequences**: One gate, any of three providers, switchable by a Variable + that provider's URL/key/model Variables — no workflow edit. opencode is genuinely provider-agnostic transport: the endpoint may be a LiteLLM proxy or a native API. Trade-off: the model-chain defaults are Gemini IDs, so a non-GEMINI run MUST set `OPENCODE_REVIEW_REPORT_MODEL_*` to that provider's models or the resolver aborts (intentional, prevents confusing downstream `opencode run` failures).
- **See also**: LADR-027 for OpenCode Go (two surfaces, hardcoded base URL).

### LADR-027: OpenCode Go Providers — split by SDK surface (`go-openai` + `go-anthropic`)

- **Date**: 2026-06-06
- **Status**: Accepted (extends LADR-026)
- **Context**: LADR-026 made the provider env-selectable across `gemini` / `github-copilot` / `openai`. We additionally want to route the gate at OpenCode's own hosted gateway — [OpenCode Go / OpenCode Zen](https://opencode.ai/docs/go/) — which serves non-Google/non-OpenAI families (Qwen, DeepSeek, Kimi, GLM, MiniMax). The catch: OpenCode Go is **dual-surface**. Some models speak the OpenAI Chat Completions API (`@ai-sdk/openai-compatible`, endpoint `…/v1/chat/completions`) and others speak the Anthropic Messages API (`@ai-sdk/anthropic`, endpoint `…/v1/messages`). A single `opencode.json` provider block can pin only one `npm`, so one block cannot serve both surfaces.
- **Decision**: Split OpenCode Go into **two** providers rather than one, each with its own `npm` + `baseURL` + credential namespace:
  - **`go-openai`** — `npm: "@ai-sdk/openai-compatible"`, `baseURL: "https://opencode.ai/zen/go/v1"` (hardcoded), `apiKey={env:OPENCODE_GO_OPENAI_API_KEY}`. Models: `deepseek-v4-flash`, `deepseek-v4-pro`, `glm-5.1`.
  - **`go-anthropic`** — `npm: "@ai-sdk/anthropic"`, `baseURL: "https://opencode.ai/zen/go/v1"` (hardcoded), `apiKey={env:OPENCODE_GO_ANTHROPIC_API_KEY}`. Models: `minimax-m3`, `minimax-m2.7`, `qwen3.7-plus`, `qwen3.6-pro` (current at the time of writing).

  Both `baseURL`s are the shared base `https://opencode.ai/zen/go/v1` — the respective SDK appends `/chat/completions` vs `/messages` to reach the two documented endpoints. The base is a **fixed public endpoint, hardcoded** (not env-driven) — OpenCode Go is a single SaaS gateway with no per-deployment URL to retune, so there is **no `OPENCODE_GO_*_URL` Variable**; only the API key (Secret) is configurable, and the same OpenCode Zen key works for both surfaces. Two selectors map in: `OPENCODE_REVIEW_REPORT_PROVIDER=OPENCODE-GO-OPENAI` → provider-id `go-openai`, `OPENCODE-GO-ANTHROPIC` → `go-anthropic` (resolved in `lib/resolve-provider.sh`, the workflow `OPENCODE_REVIEW_REPORT_PROVIDER_ID` map + bootstrap creds case, `local-review.sh` cred harvest). `setup-opencode-config.sh`'s `is_ours` predicate widened to providers `["gemini","github-copilot","go-anthropic","go-openai","openai"]` (jq-sorted) and to accept the hardcoded `https://opencode.ai/zen/go/…` baseURL. The model-family fail-fast still applies (non-GEMINI must not carry a `gemini*` id). (Health is checked provider-agnostically via the opencode server — LADR-028 — not per-surface.)
- **Consequences**: Two switchable providers covering both OpenCode Go surfaces; no workflow edit to enable (key = Secret, models = Variables — no URL to set). A run picks ONE surface — its model chain must be all-OpenAI-surface or all-Anthropic-surface ids (mixing won't resolve). Explicit `npm`/`baseURL` means we don't depend on opencode's catalog knowing the provider ids. Reaching usage beyond plan limits is handled OpenCode-side via the "Use balance" console toggle (Zen balance fallback) — not a pipeline concern.

### LADR-028: Health via the opencode server (`/global/health`), not per-provider gateway probes

- **Date**: 2026-06-06
- **Status**: Accepted (supersedes the per-provider health derivation in LADR-026 and the reachability-preflight half of LADR-024)
- **Context**: Health was checked by probing each provider's gateway endpoint — a per-surface path (`/v1/models`, `/v1beta/models`, `/models`, `<baseURL>/models`) with a per-surface auth header (Bearer vs `x-goog-api-key`), plus an `OPENCODE_API_HEALTH_OVERRIDE` escape hatch. That logic was duplicated in three places (the workflow's pre-checkout bootstrap, `lib/resolve-provider.sh`, and `local-review.sh`) and had to grow a new branch for every provider/surface added. It was also brittle: a healthy `/models` on one surface didn't guarantee the surface opencode actually calls.
- **Decision**: Replace all per-provider gateway probes with a single provider-agnostic check against opencode itself. New `lib/opencode-health.sh` runs `opencode serve` (which prints `opencode server listening on http://127.0.0.1:<port>`), parses that URL, polls `<url>/global/health` until 200, then tears the server down. Identical for every provider, so `resolve-provider.sh` no longer derives `OPENCODE_GATEWAY_HEALTH_URL` / `OPENCODE_GATEWAY_AUTH_STYLE`, and `OPENCODE_API_HEALTH_OVERRIDE` is removed. Wired in: the workflow runs it as a non-blocking step (`|| true`) right after opencode is installed + configured; `local-review.sh` runs it (fatal) after `setup-opencode-config.sh`. The resolver still resolves + presence-checks the provider's URL/key (`OPENCODE_REVIEW_REPORT_GATEWAY_URL`/`_API_KEY`).
- **Consequences**: One health path for all providers; adding a provider/surface needs no health-branch edit. Trade-off: `/global/health` confirms opencode is up but does NOT validate the upstream gateway's reachability or the API key — so (a) the local preflight no longer pre-empts a private-network/VPN hang (the process-group `timeout` shim still bounds hangs during real calls, LADR-024), and (b) a present-but-invalid key surfaces only at the real model call ("Assert Review Model Selection Works" in CI). Both are acceptable: the health step is a smoke test, and the functional model-call gate is unchanged.

### LADR-029: Run chunk review on a locked-down `review` agent (`--agent review`)

- **Date**: 2026-06-07
- **Status**: Accepted (realizes the read-only `review` agent anticipated by LADR-025; supersedes the "pass NO `--agent` flag" stance of LADR-023 and LADR-025)
- **Context**: On a PR that touched this gate's own files, chunk #2 (`.github/workflows/pipline-code-review-report.yml`, 1 file) came back as `## ⚠️ Review Failed` with **0 bytes** while chunks #0/#1 succeeded on the same model (`qwen3.7-plus`). The marker blamed "silent provider failure", but the chunk stderr told the real story: `> build · qwen3.7-plus` → `→ Skill "ai-review-report"` → `→ Read .github/workflows/pipline-code-review-report.yml` → end-of-turn, empty stdout. opencode's default **`build`** agent auto-discovers repo skills and exposes them as tools; the skill's own activation description ("use when modifying the `pipline-code-review-report` workflow") matched the chunk *being reviewed*, so the model **executed the skill instead of writing a review** and spent its turn on tool calls. This only bites when the gate reviews its own repo (or a repo that vendors this skill), but it forces a fail-closed REQUEST_CHANGES every time. Compounding it: `opencode-with-fallback.sh` keyed its fallback chain on exit code only — opencode exited 0 with empty output, so the secondary model was never tried.
- **Decision**: Stop using the default `build` agent for reviews. Define a custom **`review`** agent in `assets/opencode.json` (`mode: primary`, **no `model` field** so `--model` still wins — verified: `--agent review --model X` reports `> review · X`, the precedence trap LADR-023 hit with `build`'s pinned model does not apply) with `skill`/`task`/`edit`/`write`/`bash`/`webfetch`/`websearch` disabled (both via the deprecated `tools` map *and* `permission: deny`, belt-and-suspenders) and `read`/`grep`/`glob`/`list`/`external_directory` allowed (LADR-025 access preserved). `opencode-with-fallback.sh` now passes `--agent review` and, additionally, captures stdout and **returns non-zero when output is < 200 bytes**, so an exit-0-but-empty result advances the fallback chain (matching the empty-output floor in `review-in-chunks.sh`) instead of short-circuiting as a hollow success. The empty-chunk failure marker wording was corrected to name agent tool-misfire as a cause, not only provider failure.
- **Consequences**: The review model can no longer self-activate this (or any vendored) skill — the `.github` chunk reviews as text. Reviews remain read-only (no new write/bash/skill surface; arguably *tighter* than `build`). Aggregation also runs through `--agent review` (it only reads stdin + markdown). Trade-off: `assets/opencode.json` now carries a managed `agent` block — `setup-opencode-config.sh`'s `is_ours` self-heal predicate already keys on provider shape, so a personal config without `review` will be left intact with the standard warning (CI always overwrites). Reviewing this repo's own PRs is the canonical trigger, so keeping the `review` agent is required for the gate to certify its own changes.
- **Confirmed trigger PR**: #5 (0-byte `.github` chunk → fail-closed REQUEST_CHANGES).
- **Self-referential class**: also LADR-031 (a different self-referential failure: the `## ⚠️ Review Failed` marker string in repo docs is quoted by the chunk model, grep'd by the fail-closed net, and overrides APPROVE → REQUEST_CHANGES — observed on PR #15).

### LADR-030: Holistic Aggregation Runs for Every PR (incl. Single-Chunk)

- **Date**: 2026-06-07
- **Status**: Accepted (supersedes LADR-017)
- **Context**: LADR-017 short-circuited the holistic aggregation for `TOTAL_CHUNKS=1`, emitting placeholder text ("No cross-chunk aggregation applies — this PR was reviewed as a single unit." / "Holistic Cross-Chunk Analysis: Not applicable"). Because LADR-010's default threshold (`OPENCODE_REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING=10`, PR #10) routes most small PRs into a single chunk, the *common* case lost the high-level report entirely — users saw only raw per-file chunk findings and a programmatic decision. LADR-017's cost rationale (a ~15-min Pro-tier pass) was stale: LADR-022 already moved aggregation onto the cheap orchestrator/Flash model (~30 s).
- **Decision**: Remove the single-chunk short-circuit from `aggregate-reviews.sh`. The holistic / high-level aggregation LLM call now runs for every PR regardless of chunk count, producing the full `## 📋 Overall Summary`, `## ✅ Positive Highlights`, `## 🔍 Issues Summary`, `## 📝 Suggested Fixes`, `## 🎯 Recommendation`, and `## 🔄 Holistic Cross-Chunk Analysis` sections. The prompt phrasing adapts to chunk count (a 1-chunk PR is described as "reviewed in a single chunk", not "multiple chunks"). The two safety properties the short-circuit used to enforce are unchanged because they already live downstream and are chunk-count-agnostic: (1) the fail-closed net (per LADR-031, an out-of-band `chunk_<n>.failed` flag file) catches any chunk that could not be reviewed; (2) the workflow forces incremental reviews to `--comment`/never-`APPROVE` (LADR-004). The empty/tiny-output aggregation fail-safe (REQUEST_CHANGES on <50-byte summary) also applies to single-chunk PRs. The LADR-020 guard (skip Integration/DI/Test-Coverage holistic sections when `TOTAL_CHUNKS <= 2`) still suppresses cross-chunk-only sections that add nothing for one chunk.
- **Consequences**: Every PR — including the common small/single-chunk case — now gets a real aggregated high-level report. Cost is a single extra Flash-tier call (~30 s) per single-chunk PR; acceptable given LADR-022. The deterministic programmatic decision of the short-circuit is replaced by the LLM's policy-driven recommendation, identical to how multi-chunk PRs already resolve — with the same fail-closed and incremental guards intact.
- **Confirmed FP if reverted**: PR #10 (3 files → single chunk via the default `OPENCODE_REVIEW_MIN_FILE_COUNT_BEFORE_CHUNCKING=10` → placeholders only).

### LADR-031: Out-of-Band Chunk-Failure Signal (flag file, not marker-text grep)

- **Date**: 2026-06-07
- **Status**: Accepted
- **Context**: The fail-closed net in `aggregate-reviews.sh` decided "a chunk failed → force REQUEST_CHANGES" by grepping the **combined review text** for the literal marker `## ⚠️ Review Failed`. That marker string is *documented* in this repo's own files (SKILL.md LADRs, `aggregate-reviews.sh` comments). When the gate reviews its own repo (or a repo vendoring this skill) and the diff touches those files, the chunk-review model **quotes the marker back** in its review body — e.g. PR #15's clean review contained *"the `## ⚠️ Review Failed` check in `aggregate-reviews.sh`"*. The grep matched the quote, concluded a chunk had failed, and **overrode a genuine `APPROVE` to REQUEST_CHANGES** (run log: `A chunk failed to review — forcing REQUEST_CHANGES (fail-closed), overriding 'approve'`). The PR showed CHANGES_REQUESTED despite 0 findings. Same self-referential class as LADR-029: the gate tripping its own mechanism by reviewing the file that documents it. Deriving a control-flow decision from free-text review *content* is the root flaw — any text grep can be defeated by content that quotes the pattern.
- **Decision**: Signal chunk failure **out-of-band**. `review-in-chunks.sh` writes a zero-importance flag file `ci_temp/reviews/chunk_<n>.failed` (alongside `chunk_<n>.md`) at both failure sites (empty/tiny <200-byte output, and non-zero/timeout exit). `aggregate-reviews.sh` fail-closes on the **existence of any `chunk_*.failed` flag** (`ls ci_temp/reviews/chunk_*.failed`), never on grepping review text. The human-readable `## ⚠️ Review Failed for Chunk:` marker is still written into the chunk body so failures remain visible in the posted review — but it is presentation only, not the control signal. A flag file cannot be quoted into existence by review content, so doc/skill files may mention the marker string freely. Per-chunk flag files (not a shared append) keep the parallel chunk loop race-free.
- **Consequences**: The gate can review its own repo without false REQUEST_CHANGES from quoted markers. The signal is robust to any review content. Trade-off: the failure marker and the flag are now two separate writes that must stay in sync — both failure branches in `review-in-chunks.sh` must drop the flag (covered; a missing flag would silently *under*-report a failure, so the marker write and flag write sit adjacent at each site). Flag files live only in `ci_temp/` and never reach the posted review or git.
- **Confirmed FP if reverted**: PR #15 (LADR-030 PR — clean APPROVE overridden to REQUEST_CHANGES by the quoted marker).
- **Self-referential class**: also LADR-029 (skill self-activation), LADR-032 (the `pipline` typo, DR-010).

### LADR-032: Max-file-count gate + `OPENCODE_*` → `OPENCODE_REVIEW_REPORT_*` env rename

- **Date**: 2026-06-07
- **Status**: Accepted
- **Context**: (a) A PR touching a very large number of files is too big to review reliably — the chunked review still runs, burns model budget, and returns low-signal findings on an unreviewable changeset. There was no upper bound. (b) The pipeline's configurable env vars used a bare `OPENCODE_` prefix, which collides namespace-wise with anything else keyed on the opencode CLI and doesn't signal that these are the *review-report* gate's settings.
- **Decision**: (a) Add an upper file-count bound. A new **Block PR if Too Many Files Changed** step runs right after **Generate PR Diff**: if the post-exclusion `files_changed` exceeds `OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT` (repo/org **Variable**, default `100`; invalid/non-positive values fall back to 100), it posts a `--request-changes` review ("too many files to review — split the PR / raise the Variable") and emits `exceeded=true`. Every review-chain step (`Validate`-block, `Skip Review Due to Blocking`, chunked review, aggregation, minimize, post-review) gains `&& steps.file_count_gate.outputs.exceeded != 'true'`, so the gate short-circuits without double-posting or fail-closing. `initialize_opencode` runs before the diff is known, so opencode still installs — accepted as minor. (b) Rename every non-key config var `OPENCODE_*` → `OPENCODE_REVIEW_REPORT_*` (provider selector, model chain, gateway URLs, CLI version, health timeout, chunking threshold, derived provider-id/gateway-url). **API-key Secrets keep their names** (`OPENCODE_*_API_KEY`) — they're provider credentials, not review-report-specific config — as does the derived `OPENCODE_GATEWAY_API_KEY`.
- **Consequences**: Oversized PRs fail fast with actionable guidance instead of a costly low-quality review; the limit is tunable per repo. Operational cost of the rename: the repo/org GitHub **Variables** must be renamed to the `OPENCODE_REVIEW_REPORT_*` names or the gate reads them empty and falls back to defaults (Secrets unaffected). Historical changelog/LADR references to old/removed var names are left intact as record.

### LADR-033: Eval Harness for the Chunk-Review Model (Precision + Recall vs a Labeled Corpus)

- **Date**: 2026-06-07
- **Status**: Accepted
- **Context**: The chunk-review call (`review-in-chunks.sh`) produces the blocking findings. Its quality was only ever defended reactively — every recurring false positive became a new DR (DR-001…DR-014), and there was no way to know whether a prompt edit, a model swap, or a new LADR re-introduced a previously-killed false positive or weakened genuine-defect detection. The only model-touching check in CI was the startup "Say OK" liveness probe (not a quality signal). Each DR carries a concrete confirmed-FP PR reference, so the DR list is itself a ready-made "must-NOT-flag" golden set.
- **Decision**: Add an opt-in eval harness under `scripts/eval/` that scores the chunk-review LLM on two axes against a labeled corpus, driving the **real** `review-in-chunks.sh` per fixture (so prompt/LADR/model changes are regression-tested, not a reimplemented prompt) and reusing the CI transport verbatim (`lib/resolve-provider.sh` + `lib/setup-opencode-config.sh` + `lib/opencode-health.sh` + the two-tier `lib/opencode-with-fallback.sh` — **no new transport**).
  - **Precision (must-NOT-flag)**: one+ fixture per DR-001…DR-014. The reviewer must not re-raise a known false positive at Critical/High/Medium (Low/none allowed). **Zero tolerance** — any such flag fails the run, because every DR is a confirmed FP. This bar is intentionally **stricter than the production gate's blocking threshold** (the gate blocks only on `[VERIFIED]` Critical/High — LADR-012/LADR-015): a re-raised DR at Medium is still review noise on a confirmed FP, so the eval fails on it too. Fixtures are kept minimal (only the intentional pattern, plus an inline "do NOT flag" steering comment) so any blocking flag is unambiguously the DR re-raise and not an unrelated defect — a fixture must not itself contain a real bug (e.g. get-only auto-props set in an object initializer won't compile, so DR-001 uses `init` accessors).
  - **Recall (must-catch)**: synthesized fixtures with a seeded real defect (the legitimate inverses of the DRs + classic security/data-safety bugs) the reviewer should flag at ≥ its labeled severity; the run fails below a configurable catch-rate threshold (`EVAL_RECALL_THRESHOLD`, default 80%). Real PRs the DRs reference live in a separate product repo, so must-catch fixtures are **synthesized** with severity in a sidecar `manifest.json`.
  - Output is parsed with the pipeline's own grammar (LADR-012): only `[VERIFIED]` Critical/High/Medium count; `[SPECULATIVE]` and "None found" never count. Each fixture runs in a throwaway git sandbox (before→after commits) with the canonical DR standards (`.github/instructions/code-review-standards.instructions.md` + a DR-012…014 supplement) placed at their production dot-paths so the reviewer reads the **same** context production injects via `MANDATORY_CONTEXT_FILES`.
  - **Triggers** (real paid calls): `eval/local-evals.sh` locally; `workflow_dispatch`; and a **post-merge canary** — `push` to `main` **path-filtered** to the review-pipeline files that change the eval outcome (`.agents/skills/ai-review-report/**`, `.github/instructions/code-review-standards.instructions.md`, `.github/workflows/llm-eval-harness.yml`). Deliberately **never on `pull_request`** (it never blocks a PR) and **never in the default bash-test path**. The canary cannot change the result for an arbitrary PR because the eval scores the reviewer against a fixed corpus, not the PR's content — only the path-filtered files matter, so it stays cheap. The default-path-safe test is `eval/test-evals.sh` (stubbed model via the `EVAL_SELFTEST` seam — corpus walk, scoring, gating, exit codes; no calls). `EVAL_SAMPLES>1` runs each fixture N times (precision = worst-case, recall = majority).
  - **Triage archive**: the per-fixture git sandbox + `WORK_ROOT` are wiped on exit, so a precision FAIL otherwise leaves no record of WHAT the model flagged. When `EVAL_ARTIFACT_DIR` is set, `run-evals.sh` copies each fixture's concatenated review to `<id>.review.md` (and infra-fail run logs to `<fixture>.lastlog`); the CI workflow sets it under `ci_temp/eval-artifacts/` and uploads it via `actions/upload-artifact` with `if: always()` (the eval step exits non-zero on a regression). Inspect those reviews to confirm a FAIL is a genuine model re-raise vs a fixture-hygiene artifact.
- **Consequences**: Prompt/model/LADR changes can be regression-tested before they reach production instead of being caught by adding yet another DR. Workflow↔script path coupling now also covers `scripts/eval/` (the dispatch workflow invokes it by hardcoded path). Cost is bounded by being manual/opt-in. **Out of scope** (possible follow-up): evals for the orchestrator-tier calls (semantic grouping, aggregation summary — LADR-022), which are classification/cosmetic, not blocking.

## Key Behaviors

These are the "I would have gotten this wrong" warnings — the things an AI coder editing this skill must know to avoid breaking the gate. They are the editing-time counterpart to SKILL.md's runtime Key Behaviors.

- **Two skills, opposite directions.** `ai-review-report` (this skill) *generates* the review (CI gate, or locally via `scripts/local-review.sh`). `ai-review` (invoked `/ai-review`) *consumes* a posted review and applies fix/skip decisions back to the PR. Don't conflate them or merge their scripts.
- **The `pipline` filename typo is load-bearing** (DR-010). Renaming `pipline-code-review-report.yml` to `pipeline-…` silently breaks the gate because the workflow↔script path coupling is by hardcoded reference. The typo is in the file name, not a string in the file body — `git mv` will break it; expect a request to keep it.
- **opencode's `PermissionConfig` defines a fixed key set** (DR-011). The keys are `bash`, `edit`, `read`, `grep`, `glob`, `list`, `task`, `skill`, `external_directory`, `webfetch`, `websearch`, `lsp`, `todowrite`, `question`, `doom_loop` — and there is **no `write` key** (verified against `https://opencode.ai/config.json`). opencode silently ignores unknown permission keys, so a `permission.write: deny` suggestion is a no-op that only *looks* like a guard. Write protection is two-layer via `tools.write:false` + `permission.edit:deny`.
- **Don't re-introduce the `litellm-gemini` provider name.** It was renamed to `gemini` (PR #1, BNKI-001). Old changelog/LADR references are historical record; do not change them. The `setup-opencode-config.sh` `is_ours` providers list is the canonical name set: `["gemini","github-copilot","go-anthropic","go-openai","openai"]` (jq-sorted).
- **`scripts/lib/` is the only place shared helpers live.** Cross-script imports go through `source "$(dirname "$0")/lib/<helper>.sh"`. Don't reach into a sibling skill's `lib/` — the cross-skill dependency is not in the path coupling and is fragile.
- **The `--agent review` precedence trap is subtle** (LADR-029). `--agent review` does **not** override `--model` because the `review` agent has no `model` field set — opencode's docs say agent-level `model` is only used when `--model` is absent. Verified: `--agent review --model X` reports `> review · X`. Adding a `model` field to the `review` agent would silently break `--model` overrides and lock the gate to a single model.
- **`--yolo` is gone** (LADR-023). The old gemini-cli flag is now realized as the `review` agent's read/grep/glob/list/external_directory allow-list. Don't grep for `--yolo` in scripts — it was never carried over to opencode.
- **`OPENCODE_*` API-key Secrets keep their names** (LADR-032). When adding a new provider, its API key is `OPENCODE_<PROVIDER>_API_KEY` (Secret), even though every non-key config var uses the `OPENCODE_REVIEW_REPORT_` prefix. The asymmetry is intentional — Secrets are provider credentials, not review-report config.
- **Workflow↔script path coupling is a hard rule** (repo `CLAUDE.md` Non-Negotiables). Every script the workflow invokes by hardcoded path lives under `.agents/skills/ai-review-report/scripts/`. The eval harness (LADR-033) added a second hardcoded path: `.github/workflows/llm-eval-harness.yml` invokes `scripts/eval/run-evals.sh` by hardcoded path. Renaming any of these without a paired workflow edit is a silent break.
- **The env-var rename of LADR-032 affects Variables only**, not Secrets. Repo/org GitHub Variables must be renamed to the `OPENCODE_REVIEW_REPORT_*` names or the gate reads them empty and falls back to defaults; Secrets are unaffected. Verify after the rename by running a full review on a test PR with a non-default Variable value.
- **The `local-review.sh` timeout shim is non-negotiable on macOS** (LADR-024). The `gsed` + process-group-killing `timeout` shim is provided automatically. Don't try to simplify it; the previous `perl -e 'alarm; exec bash …'` shim never worked — bash traps SIGALRM and the `opencode` grandchild was orphaned.
- **`MANDATORY_CONTEXT_FILES` paths warn-and-skip when absent** (root `AGENTS.md` Key Behaviors). They are intentional for cross-repo reuse — do not "fix" them by deleting or repointing.
- **DR-014 in `.agents/skills/code-review-standards/SKILL.md`**: the chosen approach documented in an LADR is by definition intentional; flagging it as wrong is a confirmed FP. PR #5258 (BNKI-1190) flagged `Secondary.Enabled: true` in prod as High×14 because PR-body text said "off in prod" — that wording was superseded by commit `e7083c3` and the kill-switch LADR-10 explicitly allows the flip.
- **Confirmed false-positive PRs to keep in mind when reviewing FP reports** (not exhaustive — see references/CHANGELOG.md for full provenance):
  - **PR #3946** (BNKI-001) — incremental review approved PR (LADR-004 invariant).
  - **PR #4787** (BNKI-001) — corrupted/large diff + stale-symbol flag (LADR-015 invariant).
  - **PR #4992** (BNKI-1066) — primary-constructor suggested for class already using primary constructors; also a `FtpHelper.cs` "swallowed exceptions regression" where a deleted `if (!config.ContinueWorking) throw;` was unreachable in the surviving mode (DR-013).
  - **PR #5179** — single-chunk aggregation cost (LADR-017 cost basis).
  - **PR #5258** (BNKI-1190) — PR-body wording ("off in prod", "missing type-name discriminator") overriding LADR-10's chosen approach (DR-014). Mass-flagged at High×14.
  - **PR #5326** — semantic-grouping threshold of 8 over-split 10 files into 6 tiny chunks (raised to 15, LADR-011).
  - **PR #5** — 0-byte `.github` chunk from skill self-activation (LADR-029 invariant).
  - **PR #15** — clean APPROVE overridden to REQUEST_CHANGES by quoted `## ⚠️ Review Failed` marker (LADR-031 invariant).
  - **PR #10** — 3-file single-chunk PR showed placeholders only (LADR-030 / LADR-017 invariant).
  - **Run 26387093767** — all-models-failed left as red workflow check (LADR-021 invariant).

## Test References

The skill's "tests" are the eval fixtures under `scripts/eval/corpus/` (per LADR-033). There is no `*UnitTest` / `*ComponentTest` / `*IntegrationTest` project in the backend sense.

| Tier | Sub-folder | Purpose |
|------|-----------|---------|
| Structural self-test | `scripts/eval/test-evals.sh` | Corpus walk + scoring + gating + exit codes; stubbed model via `EVAL_SELFTEST` seam; default-path-safe (no paid calls). |
| Self-test for the reviewer itself | `scripts/test-minimize-reviews.sh` (3.3K) | BDD-style test of the minimize-previous-reviews step. |
| Self-test for the chunk threshold | `scripts/test-review-chunk-threshold.sh` (3.3K) | Verifies the `OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT` gate. |
| Live eval | `scripts/eval/local-evals.sh` | Local entrypoint: cred harvest + macOS `timeout` shim, then `run-evals.sh`. Paid calls. |
| Workflow eval | `.github/workflows/llm-eval-harness.yml` | `workflow_dispatch`-only. Never on `pull_request`. Path-filtered post-merge canary on `push` to `main`. |
| Validation | `scripts/validate-agents-md.sh` (20.7K) | Validates `*_AGENTS.md` files in the reviewed repo against the quality standards (`references/knowledge-conventional-contexts-quality.instructions.md`). Runs as a workflow step. |

When adding a new eval fixture, follow the patterns in `scripts/eval/corpus/`: the fixture is a git sandbox (before→after commits), with the canonical DR standards (`.github/instructions/code-review-standards.instructions.md` + a DR-012…014 supplement) placed at their production dot-paths, and a sidecar `manifest.json` for the must-catch recall label.

## Quality Constraints

Skill-specific non-functional requirements that go beyond the project-wide baseline. The project-wide NFRs are in `.agents/rules/non-functional-requirements.instructions.md`.

- **Skill prompt is bounded.** Chunk reviews are bounded to <100KB per call (LADR-001/LADR-014). Aggregation prompt size adapts to chunk count (LADR-020/LADR-030). Adding a new section to the holistic prompt must come with a guard or it re-bloats small-PR aggregation.
- **Skill is provider-agnostic at the call-site.** All call sites prefix `${OPENCODE_REVIEW_REPORT_PROVIDER_ID}/<model>`. Adding a hardcoded provider prefix (e.g. `gemini/`) in a new call site is a regression — the gate should still work when `OPENCODE_REVIEW_REPORT_PROVIDER=OPENAI`.
- **Skill is read-only at the model level.** The `review` agent denies `skill`/`task`/`edit`/`write`/`bash` (LADR-029). Any change to the agent that re-enables a write tool is a regression — the model will start self-activating the skill or modifying the repo.
- **Skill has zero new transport.** Every script reuses `lib/resolve-provider.sh` + `lib/setup-opencode-config.sh` + `lib/opencode-health.sh` + `lib/opencode-with-fallback.sh`. Adding a new way to call the model (e.g. shelling out to `curl` directly) is a regression — the eval harness (LADR-033) explicitly cites "no new transport" as a design property.
- **Skill is race-safe in the parallel chunk loop.** Per-chunk state lives in per-chunk files (`chunk_<n>.md`, `chunk_<n>.failed` — LADR-031). Don't introduce a shared append-only file or shared counter — the chunk loop runs in parallel and any shared mutable state needs a `flock`.
- **Skill survives a "review its own repo" cycle.** The `review` agent (LADR-029) and the out-of-band failure flag (LADR-031) exist because the gate tripping on its own SKILL.md / workflow YAML was a confirmed failure mode. Any new prompt that contains the literal string `## ⚠️ Review Failed` will be picked up by the grep-fail-closed net (now only in the chunk body, not the control path) — fine for visibility, but new control decisions must stay out of review text.

## Migration Plans

- **LADR numbering is append-only.** Superseded entries (LADR-008, 014, 017, 018) and partially-superseded entries (LADR-023, 024) stay in this file with their full Date/Status/Context/Decision/Consequences/Supersede-by chain. When adding LADR-N+1, do not renumber.
- **The env-var prefix migration (LADR-032) is the most recent cross-cutting rename.** Repo/org GitHub **Variables** must be renamed to the `OPENCODE_REVIEW_REPORT_*` names; Secrets are unaffected. New Variables follow the new prefix by default. The legacy `OPENCODE_*` prefix is reserved for Secrets only.
- **The provider name `litellm-gemini` was renamed to `gemini` (PR #1).** New code uses `gemini`. The old name appears in dated changelog and LADR histories as record; do not change those.
- **The comment trigger `/gemini-review` was retired in favour of `/ai-review`.** PRs that document `/gemini-review` as a re-run mechanism need to be updated; the workflow no longer matches the old string. Dated changelog references are historical record only.
- **The `auto` logical model name and `get_aggregation_model()` derivation were removed in LADR-022.** New code passes an explicit model id; the orchestrator Variable is the single source of truth.
- **The `OPENCODE_API_HEALTH_OVERRIDE` Variable was removed in LADR-028.** New health code uses the opencode server's `/global/health` — there is no per-provider escape hatch.

## See also

- **SKILL.md** — the runtime contract (frontmatter, what the model must do, current Decision + Consequences of every accepted LADR, Key Behaviors, decision matrix). Loaded by Claude Code / Codex / Copilot when the skill is invoked; the model reads it via opencode's read tools at review time.
- **references/CHANGELOG.md** — the dated audit trail of every commit to the skill. Load when updating the skill or auditing past decisions; not needed for routine execution. Contains the imported history pre-2026-06-01 (legacy names like `.ai/`, `gemini-code-review`, `manual-gemini-cli-code-review.yml` — these do not exist in this repo, preserved as record).
- **references/knowledge-conventional-contexts-quality.instructions.md** — the repo-wide AGENTS.md quality standards the review/validation prompts apply.
- **`.github/workflows/pipline-code-review-report.yml`** — the gate. Workflow↔script path coupling: every script under `scripts/` is invoked by hardcoded path from this workflow. Workflow↔`model_preset` options coupling: adding/renaming a `model_preset` option requires editing both the `options:` list and the five `env:` expressions in the same commit.
- **`.github/instructions/code-review-standards.instructions.md`** — the DR list the chunk-review model follows. DR-001…DR-014 are the "must-NOT-flag" golden set for the eval harness (LADR-033).
- **`.github/workflows/llm-eval-harness.yml`** — the workflow that runs the eval harness. `workflow_dispatch`-only; post-merge canary on `push` to `main` path-filtered to the review-pipeline files. Never on `pull_request`.

## Changelog

> AI loading note: Skip this section during routine task execution. Use it only when updating this file.

| Date | Change | Ref |
|:-----|:-------|:----|
| 2026-06-08 | Initial AGENTS.md: split SKILL.md into runtime contract (skill frontmatter + Decision/Consequences of accepted LADRs + decision matrix) and editor's companion (this file — full LADR history with Date/Status/Context, env-var provenance, skill layout, confirmed-FP PR references, supersede chains, Key Behaviors for the coder). Source-of-truth for the split: the chunk-review model does not need the LADR *Context* narrative to do its job; an AI coder editing the skill does. | — |
