# AI Skills

Self-contained skills for Claude Code, GitHub Copilot, and OpenAI Codex powering this repo's AI PR review pipeline.

Skills live **flat**, one directory per skill directly under `.agents/skills/`. A skill's folder name MUST equal its `name:` frontmatter (this is the slash-command name), and folders sit exactly one level under `.agents/skills/` (Claude Code discovers skills exactly one level under `.claude/skills/`).

## The Review Pipeline — Two Skills, Opposite Directions

| Skill | Direction | Purpose | Usage |
|-------|-----------|---------|-------|
| **ai-review-report** | *generates* | Chunked AI review of a PR diff — runs as the CI gate (`.github/workflows/pipeline-code-review-report.yml`) or locally via `scripts/local-review.sh`, and posts a structured review to the PR | invoked by the gate / `scripts/local-review.sh` |
| **ai-review** | *consumes* | Parse a posted AI review, apply fix/skip decisions, and finalize review processing on the PR (GitHub or Azure DevOps) | `/ai-review analyse 123` |

Do not conflate the two or merge their scripts: `ai-review-report` produces the review that `ai-review` later acts on.

### ai-review-report

The repo's deliverable. Pipeline internals — provider selection (`OPENCODE_REVIEW_REPORT_PROVIDER`), chunking, the two-tier model chain, false-positive rules, and the LADR history — live in `ai-review-report/SKILL.md` (runtime contract) and `ai-review-report/AGENTS.md` (decision history). Key layout:

| Path | Role |
|------|------|
| `ai-review-report/SKILL.md` | Runtime contract — source of truth for pipeline behavior |
| `ai-review-report/scripts/` | Scripts invoked by the workflow **by hardcoded path** — move/rename only together with the workflow YAML |
| `ai-review-report/assets/` | Runtime config: `opencode.json` (env-injected credentials only), `review-config.json` |
| `ai-review-report/references/` | Edit-time docs: `CHANGELOG.md`, AGENTS.md quality standards — not read during a review |

### ai-review

Consumes a posted review. Detects the review source — for a GitHub Copilot agent review it replies to and resolves each linked review thread; otherwise it appends AI review notes to the PR description.

## Supporting Skill

| Skill | Purpose | Usage |
|-------|---------|-------|
| **git-commit-review-push** | Commit with conventional format (logical chunks), append the `/ai-review` full-review trigger to the final commit, and push to remote | `/git-commit-review-push` |

## Model Selection

Each SKILL.md carries a `models` frontmatter block with the recommended model per tool. When a skill is invoked as a sub-agent, use the model from its `models` block.

| Skill | Complexity | Rationale |
|-------|-----------|-----------|
| **ai-review** | medium | Review analysis + multi-file code fixes |
| **git-commit-review-push** | medium | Chunked commits + branch rename logic + upstream tracking |

`ai-review-report` pins its own model chain per provider via the gate's GitHub Variables (`OPENCODE_REVIEW_REPORT_MODEL_*`), not the `models` frontmatter.

## About Skills

Each skill is a directory containing:
- **SKILL.md** — The skill definition with workflow steps and `models` frontmatter
- **scripts/** — Helper scripts (if applicable)
- **assets/** — Runtime config (if applicable)
- **references/** — Reference documentation (if applicable)

Skills are tool-agnostic and work across Claude Code, GitHub Copilot, and OpenAI Codex.
