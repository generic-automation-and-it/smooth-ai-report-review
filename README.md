# AI Review Report

## TL;DR

Automated, AI-driven pull-request code review. A GitHub Actions gate diffs each PR, splits the changes into context-aware chunks, and runs them through the [OpenCode](https://opencode.ai/) CLI — the provider-agnostic model transport — which calls the configured LLM at whatever endpoint the selected provider points to: a LiteLLM proxy, a provider's native API (Google Gemini, OpenAI, GitHub Copilot), or OpenCode's own gateway (OpenCode Go). The gate then posts one consolidated review back to the PR — an executive summary plus collapsible per-chunk detail, with findings categorized by priority (Critical / High / Medium / Low). Runs automatically on PRs and on demand via `/ai-review`.

Two skills back it:
- **`ai-review-report`** — generates the review (the CI gate; also runnable locally).
- **`ai-review`** — consumes a posted review and applies fix/skip decisions (`/ai-review`).

Implementation details and decisions live in [`.agents/skills/ai-review-report/SKILL.md`](.agents/skills/ai-review-report/SKILL.md).

## Review states

| State | When it happens | Outcome |
|---|---|---|
| **Full review** | First review on a PR, an `/ai-review` comment, a re-requested review, or a manual dispatch | Reviews the entire diff against the merge base. Can **approve**, **request changes**, or comment — and clears any prior blocking state. |
| **Incremental review** | Later pushes to an already-reviewed PR | Reviews only the new commits since the last reviewed commit. **Never approves** — posts comments only. |
| **Full review blocked — documentation gate failed** | A full-review PR adds/modifies **no** `*AGENTS.md`, `README.md`, or `SKILL.md`, or introduces a new `*AGENTS.md` that fails the naming/template rules (all changed files exempt-path is excused) | The gate blocks instead of reviewing and posts guidance describing the missing or invalid documentation. |
| **Review bypassed — changes already requested** | The bot already has an open *changes requested* review | Incremental reviews skip (the existing block stands until addressed). A new **full** review still runs and can clear it. |

## Requirements

- A GitHub-hosted `ubuntu-latest` runner. The model gateway for the selected provider (e.g. `OPENCODE_REVIEW_REPORT_GEMINI_URL`) must be reachable from GitHub-hosted runners — i.e. publicly routable, not VPN-only. (If the gateway is private-network only, switch the workflow's `runs-on` back to `self-hosted`.)
- **Allow GitHub Actions to approve PRs.** Enable repo (or org) **Settings → Actions → General → Workflow permissions → "Allow GitHub Actions to create and approve pull requests."** Without it, a clean full review fails when the gate tries to approve (`GitHub Actions is not permitted to approve pull requests`). An org-level policy can force this off and overrides the repo toggle.
- Gateway config for the selected provider (default `GEMINI`): the API key as a GitHub **Secret** (`OPENCODE_GEMINI_API_KEY`) and the gateway URL as a **Variable** (`OPENCODE_REVIEW_REPORT_GEMINI_URL`); optional **Variables** `OPENCODE_REVIEW_REPORT_PROVIDER` (to switch provider), `OPENCODE_REVIEW_REPORT_MODEL_*` (to retune the model chain), and `OPENCODE_REVIEW_REPORT_CLI_VERSION` (pin OPENCODE CLI; unset = latest) without editing the workflow. See [Environment variables](#environment-variables) for the complete list and [Providers](#providers) for the per-provider breakdown.

## Providers

OpenCode is provider-agnostic — the committed config ([`.agents/skills/ai-review-report/assets/opencode.json`](.agents/skills/ai-review-report/assets/opencode.json)) defines the providers OpenCode can route to. Each provider reads its gateway URL and API key from environment variables (`{env:...}` substitution), so credentials never live in the repo.

| Provider | Status | Models | Env vars (gateway URL + key) |
|---|---|---|---|
| **Gemini** (`gemini`, `@ai-sdk/google`) | Default — the model chain points here | `gemini-3.1-pro-preview`, `gemini-2.5-pro`, `gemini-3-flash-preview`, `gemini-2.5-flash` | `OPENCODE_REVIEW_REPORT_GEMINI_URL`, `OPENCODE_GEMINI_API_KEY` |
| **GitHub Copilot** (`github-copilot`, `@ai-sdk/github-copilot`) | Optional | `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` | `OPENCODE_REVIEW_REPORT_COPILOT_URL`, `OPENCODE_COPILOT_API_KEY` |
| **OpenAI** (`openai`, `@ai-sdk/openai`) | Optional | `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` | `OPENCODE_REVIEW_REPORT_OPENAI_URL`, `OPENCODE_OPENAI_API_KEY` |
| **OpenCode Go — OpenAI** (`go-openai`, `@ai-sdk/openai-compatible`) | Optional — [OpenCode's own gateway](https://opencode.ai/docs/go/) (OpenCode Zen), OpenAI-compatible surface | `deepseek-v4-flash`, `deepseek-v4-pro`, `glm-5.1` | `OPENCODE_GO_OPENAI_API_KEY` (base URL hardcoded) |
| **OpenCode Go — Anthropic** (`go-anthropic`, `@ai-sdk/anthropic`) | Optional — same gateway, Anthropic-compatible surface | `minimax-m2.7`, `qwen3.7-plus`, `qwen3.6-plus` | `OPENCODE_GO_ANTHROPIC_API_KEY` (base URL hardcoded) |

> **OpenCode Go is two providers.** Its Zen gateway exposes two SDK surfaces under one base (`https://opencode.ai/zen/go/v1`, hardcoded in `opencode.json`): an OpenAI-compatible one (`/chat/completions`, serving DeepSeek/GLM) and an Anthropic-compatible one (`/messages`, serving MiniMax/Qwen). A single opencode.json provider block can pin only one `npm`, so the surfaces are split into `go-openai` and `go-anthropic`, selected by `OPENCODE-GO-OPENAI` / `OPENCODE-GO-ANTHROPIC`. The base URL is a fixed public endpoint so there's **no URL Variable** — only the API key Secret. The same Zen API key works for both surfaces.

The active provider is chosen by the **`OPENCODE_REVIEW_REPORT_PROVIDER`** Variable (`GEMINI` | `COPILOT` | `OPENAI` | `OPENCODE-GO-OPENAI` | `OPENCODE-GO-ANTHROPIC`, default `GEMINI`). The pipeline resolves it to the matching opencode provider-id and gateway credentials, then prefixes every model with that id (`<provider-id>/<model>`) when invoking OpenCode. Optional providers can be left unconfigured: you only need credentials for the provider `OPENCODE_REVIEW_REPORT_PROVIDER` actually selects.

### GitHub configuration

Set these under repo (or org) **Settings → Secrets and variables → Actions**. The workflow exports each value into the job env so OpenCode's `{env:...}` substitution resolves at runtime.

**Secrets** (API keys only — sensitive):

| Secret | For | Required? |
|---|---|---|
| `OPENCODE_GEMINI_API_KEY` | Gemini gateway API key | Required (default provider) |
| `OPENCODE_COPILOT_API_KEY` | GitHub Copilot gateway API key | Only if using Copilot models |
| `OPENCODE_OPENAI_API_KEY` | OpenAI gateway API key | Only if using OpenAI models |
| `OPENCODE_GO_OPENAI_API_KEY` | OpenCode Go (OpenAI surface) API key | Only if using `OPENCODE-GO-OPENAI` |
| `OPENCODE_GO_ANTHROPIC_API_KEY` | OpenCode Go (Anthropic surface) API key | Only if using `OPENCODE-GO-ANTHROPIC` |

**Variables** (non-sensitive — gateway URLs, provider selector, model chain; switch provider / retune without editing the workflow; each falls back to a literal default if unset):

| Variable | Default | Role |
|---|---|---|
| `OPENCODE_REVIEW_REPORT_PROVIDER` | `GEMINI` | Selects the active provider: `GEMINI`, `COPILOT`, `OPENAI`, `OPENCODE-GO-OPENAI`, or `OPENCODE-GO-ANTHROPIC` |
| `OPENCODE_REVIEW_REPORT_GEMINI_URL` | `https://generativelanguage.googleapis.com/v1beta/openai` | Gemini gateway base URL (default provider, OpenAI-compatible). Unset → `@ai-sdk/google`'s native Gemini API base. Point at a LiteLLM proxy to relay instead. |
| `OPENCODE_REVIEW_REPORT_COPILOT_URL` | `https://api.githubcopilot.com` | GitHub Copilot gateway base URL (only if using Copilot models). Unset → `@ai-sdk/github-copilot`'s native API base. |
| `OPENCODE_REVIEW_REPORT_OPENAI_URL` | `https://api.openai.com/v1` | OpenAI gateway base URL (only if using OpenAI models). Unset → `@ai-sdk/openai`'s native API base. |
| `OPENCODE_REVIEW_REPORT_CLI_VERSION` | _(unset)_ | Optional OPENCODE CLI version pin used by the **Initialize OPENCODE** step cache/install flow. Leave unset to install latest and use cached fallback if download fails. |
| `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY_REVIEW` | `gemini-3.1-pro-preview` | Primary deep chunk-review model |
| `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY_REVIEW` | `gemini-2.5-pro` | Secondary review model (two-tier chain) |
| `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR` | `gemini-3-flash-preview` | Cheap model for grouping, aggregation, and summary |
| `OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING` | `10` | If changed file count is this value or lower, review as a single chunk. Above it, use normal chunking flow. |
| `OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT` | `100` | Upper bound on changed files. If a PR exceeds it, the gate posts REQUEST_CHANGES ("too many files to review") and skips the AI review entirely. Raise it for unavoidably large changesets. |

> **Switching provider:** set `OPENCODE_REVIEW_REPORT_PROVIDER` to `COPILOT`, `OPENAI`, `OPENCODE-GO-OPENAI`, or `OPENCODE-GO-ANTHROPIC`, supply that provider's `OPENCODE_<P>_API_KEY` (Secret) — and, for the gateway-relayed providers, its `OPENCODE_REVIEW_REPORT_<P>_URL` (Variable); the two OpenCode Go surfaces need no URL Variable (base URL hardcoded) — **and** set the three `OPENCODE_REVIEW_REPORT_MODEL_*` Variables to that provider's model IDs (e.g. `gpt-5.5` / `gpt-5.4` / `gpt-5.4-mini` for OpenAI/Copilot, `deepseek-v4-pro` / `deepseek-v4-flash` / `glm-5.1` for `OPENCODE-GO-OPENAI`, or `qwen3.7-plus` / `minimax-m2.7` for `OPENCODE-GO-ANTHROPIC`). The model-chain defaults are Gemini IDs, which don't resolve on the other gateways — the run **fails fast** (in [`lib/resolve-provider.sh`](.agents/skills/ai-review-report/scripts/lib/resolve-provider.sh)) if a `gemini*` model is left in place for a non-`GEMINI` provider. All provider credentials are wired into the workflow's `env:` block, so no workflow edit is needed to enable a provider — only its key (+ URL for the relayed providers) + model Variables.

## Environment variables

Complete reference for every environment variable the pipeline reads. **Selector + credentials + model chain** are what you configure; **derived** vars are computed at runtime by [`lib/resolve-provider.sh`](.agents/skills/ai-review-report/scripts/lib/resolve-provider.sh) (CI: written to `$GITHUB_ENV`; local: exported by `local-review.sh`) — you never set them by hand.

| Variable | Set by | Purpose |
|---|---|---|
| `OPENCODE_REVIEW_REPORT_PROVIDER` | GitHub **Variable** / `--provider` / shell (default `GEMINI`) | Selects the active provider: `GEMINI`, `COPILOT`, `OPENAI`, `OPENCODE-GO-OPENAI`, or `OPENCODE-GO-ANTHROPIC`. |
| `OPENCODE_REVIEW_REPORT_GEMINI_URL` (**Variable**) / `OPENCODE_GEMINI_API_KEY` (**Secret**) | GitHub / shell export | Gemini gateway base URL + API key (`gemini` provider). |
| `OPENCODE_REVIEW_REPORT_COPILOT_URL` (**Variable**) / `OPENCODE_COPILOT_API_KEY` (**Secret**) | GitHub / shell export | GitHub Copilot gateway base URL + API key (`github-copilot` provider). |
| `OPENCODE_REVIEW_REPORT_OPENAI_URL` (**Variable**) / `OPENCODE_OPENAI_API_KEY` (**Secret**) | GitHub / shell export | OpenAI gateway base URL + API key (`openai` provider). |
| `OPENCODE_GO_OPENAI_API_KEY` (**Secret**) | GitHub / shell export | OpenCode Go OpenAI-compatible API key (`go-openai` provider). Base URL is hardcoded (`https://opencode.ai/zen/go/v1`) — no URL Variable. |
| `OPENCODE_GO_ANTHROPIC_API_KEY` (**Secret**) | GitHub / shell export | OpenCode Go Anthropic-compatible API key (`go-anthropic` provider). Base URL is hardcoded — no URL Variable. |
| `OPENCODE_REVIEW_REPORT_CLI_VERSION` | GitHub **Variable** / shell (default unset) | Optional OPENCODE CLI version pin for the workflow's **Initialize OPENCODE** step. Unset = latest. |
| `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY_REVIEW` | GitHub **Variable** / `--model` / shell (default `gemini-3.1-pro-preview`) | Primary deep chunk-review model. The `workflow_dispatch` `model` input overrides it. |
| `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY_REVIEW` | GitHub **Variable** / shell (default `gemini-2.5-pro`) | Secondary review model (two-tier fallback chain). |
| `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR` | GitHub **Variable** / shell (default `gemini-3-flash-preview`) | Cheap model for semantic grouping, aggregation, and summary. |
| `OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING` | GitHub **Variable** / shell (default `10`) | If changed file count is this value or lower, review as a single chunk. Above it, the standard chunking flow runs. |
| `OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT` | GitHub **Variable** / shell (default `100`) | Max changed files the gate will review. If a PR exceeds it, the gate blocks the PR with REQUEST_CHANGES instead of attempting a low-quality review of an oversized changeset. |
| `MANDATORY_CONTEXT_FILES` | Workflow `env:` (space-separated) | Context files loaded into every review (coding standards, language/tool setup, review guidelines). |
| `AGENTS_MD_EXEMPT_PATHS` | Workflow `env:` (pipe-separated) | Paths exempt from the `*_AGENTS.md` validation requirement. |
| `GITHUB_TOKEN` | GitHub Actions (or `gh auth` locally) | Posting reviews/comments and reading PR metadata. |
| `OPENCODE_REVIEW_REPORT_PROVIDER_ID` | **Derived** | The opencode.json provider KEY the model is prefixed with: `gemini` / `github-copilot` / `openai` / `go-openai` / `go-anthropic`. |
| `OPENCODE_REVIEW_REPORT_GATEWAY_URL` / `OPENCODE_GATEWAY_API_KEY` | **Derived** | The selected provider's URL + key, copied to generic names for the credential presence check. (Health is checked separately and provider-agnostically via the opencode server — `lib/opencode-health.sh` — so there is no derived per-provider health URL.) |

## Using `/ai-review`

`/ai-review` is the companion skill that **consumes** a posted review and applies fix/skip decisions back to the PR. It is invoked locally inside Claude Code after the CI gate has posted a review.

### Two modes

| Mode | When to use | Invocation |
|---|---|---|
| **Analyse** | Fetch a posted review and get a recommended fix/skip table | `/ai-review <pr>` |
| **Execute** | Apply the fix/skip decisions from an analyse run | `/ai-review <pr> 1=fix 2=skip …` |

Modes are auto-detected: if any argument matches `<N>=fix` or `<N>=skip`, execute mode is used; otherwise analyse.

### Quick examples

```bash
# Analyse PR 48 — fetches the latest AI review and outputs a fix/skip recommendation table
/ai-review 48

# Execute decisions from the analyse output
/ai-review 48 1=fix 2=skip 3=fix

# Force a specific review source (auto-detected by default)
/ai-review analyse 48 --source=copilot
/ai-review execute 48 1=fix --source=other
```

### Result routing

- **GitHub Copilot review** — replies to and resolves each inline review thread per decision, then posts a summary comment on the PR.
- **Other review** (OpenCode/Gemini/generic) — appends the fix/skip table to the PR description's **AI Review Notes** section.

Source is auto-detected by scanning the PR's reviews for the Copilot bot. Override with `--source=copilot` or `--source=other`.

### Guardrails

- Analyse **always stops** — execute is never triggered automatically.
- Fixes are scoped to selected items only; unrelated threads are never resolved.
- Non-Copilot flow appends to AI Review Notes — it never overwrites existing content.

Full spec: [`.agents/skills/ai-review/SKILL.md`](.agents/skills/ai-review/SKILL.md)
