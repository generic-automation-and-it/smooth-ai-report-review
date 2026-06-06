# AI Review Report

## TL;DR

Automated, AI-driven pull-request code review. A GitHub Actions gate diffs each PR, splits the changes into context-aware chunks, and runs them through the [OpenCode](https://opencode.ai/) CLI — the model transport — which calls an LLM via a private LiteLLM gateway (provider-agnostic — any model LiteLLM can route to). The gate then posts one consolidated review back to the PR — an executive summary plus collapsible per-chunk detail, with findings categorized by priority (Critical / High / Medium / Low). Runs automatically on PRs and on demand via `/gemini-review`.

Two skills back it:
- **`ai-review-report`** — generates the review (the CI gate; also runnable locally).
- **`ai-review`** — consumes a posted review and applies fix/skip decisions (`/ai-review`).

Implementation details and decisions live in [`.agents/skills/ai-review-report/SKILL.md`](.agents/skills/ai-review-report/SKILL.md).

## Review states

| State | When it happens | Outcome |
|---|---|---|
| **Full review** | First review on a PR, a `/gemini-review` comment, a re-requested review, or a manual dispatch | Reviews the entire diff against the merge base. Can **approve**, **request changes**, or comment — and clears any prior blocking state. |
| **Incremental review** | Later pushes to an already-reviewed PR | Reviews only the new commits since the last reviewed commit. **Never approves** — posts comments only. |
| **No review — `AGENTS.md` missing** | Changed code lacks a required `*_AGENTS.md` context file | The gate blocks instead of reviewing and requests the missing context doc. |
| **Review bypassed — changes already requested** | The bot already has an open *changes requested* review | Incremental reviews skip (the existing block stands until addressed). A new **full** review still runs and can clear it. |

## Requirements

- A GitHub-hosted `ubuntu-latest` runner. The model gateway for the selected provider (e.g. `OPENCODE_GEMININ_URL`) must be reachable from GitHub-hosted runners — i.e. publicly routable, not VPN-only. (If the gateway is private-network only, switch the workflow's `runs-on` back to `self-hosted`.)
- Gateway config for the selected provider (default `GEMINI`): the API key as a GitHub **Secret** (`OPENCODE_GEMININ_API_KEY`) and the gateway URL as a **Variable** (`OPENCODE_GEMININ_URL`); optional **Variables** `OPENCODE_PROVIDER` (to switch provider) and `OPENCODE_MODEL_*` (to retune the model chain) without editing the workflow. See [Environment variables](#environment-variables) for the complete list and [Providers](#providers) for the per-provider breakdown.

## Providers

OpenCode is provider-agnostic — the committed config ([`.agents/skills/ai-review-report/assets/opencode.json`](.agents/skills/ai-review-report/assets/opencode.json)) defines the providers OpenCode can route to. Each provider reads its gateway URL and API key from environment variables (`{env:...}` substitution), so credentials never live in the repo.

| Provider | Status | Models | Env vars (gateway URL + key) |
|---|---|---|---|
| **Gemini** (`litellm-gemini`, `@ai-sdk/google`) | Default — the model chain points here | `gemini-3.1-pro-preview`, `gemini-2.5-pro`, `gemini-3-flash-preview`, `gemini-2.5-flash` | `OPENCODE_GEMININ_URL`, `OPENCODE_GEMININ_API_KEY` |
| **GitHub Copilot** (`github-copilot`, `@ai-sdk/github-copilot`) | Optional | `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` | `OPENCODE_COPILOT_URL`, `OPENCODE_COPILOT_API_KEY` |
| **OpenAI** (`openai`, `@ai-sdk/openai`) | Optional | `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` | `OPENCODE_OPENAI_URL`, `OPENCODE_OPENAI_API_KEY` |

The active provider is chosen by the **`OPENCODE_PROVIDER`** Variable (`GEMINI` | `COPILOT` | `OPENAI`, default `GEMINI`). The pipeline resolves it to the matching opencode provider-id and gateway credentials, then prefixes every model with that id (`<provider-id>/<model>`) when invoking OpenCode. Optional providers can be left unconfigured: you only need credentials for the provider `OPENCODE_PROVIDER` actually selects.

### GitHub configuration

Set these under repo (or org) **Settings → Secrets and variables → Actions**. The workflow exports each value into the job env so OpenCode's `{env:...}` substitution resolves at runtime.

**Secrets** (API keys only — sensitive):

| Secret | For | Required? |
|---|---|---|
| `OPENCODE_GEMININ_API_KEY` | Gemini gateway API key | Required (default provider) |
| `OPENCODE_COPILOT_API_KEY` | GitHub Copilot gateway API key | Only if using Copilot models |
| `OPENCODE_OPENAI_API_KEY` | OpenAI gateway API key | Only if using OpenAI models |

**Variables** (non-sensitive — gateway URLs, provider selector, model chain; switch provider / retune without editing the workflow; each falls back to a literal default if unset):

| Variable | Default | Role |
|---|---|---|
| `OPENCODE_PROVIDER` | `GEMINI` | Selects the active provider: `GEMINI`, `COPILOT`, or `OPENAI` |
| `OPENCODE_GEMININ_URL` | — | Gemini gateway base URL (required — default provider) |
| `OPENCODE_COPILOT_URL` | — | GitHub Copilot gateway base URL (only if using Copilot models) |
| `OPENCODE_OPENAI_URL` | — | OpenAI gateway base URL (only if using OpenAI models) |
| `OPENCODE_MODEL_PRIMARY_REVIEW` | `gemini-3.1-pro-preview` | Primary deep chunk-review model |
| `OPENCODE_MODEL_SECONDARY_REVIEW` | `gemini-2.5-pro` | Secondary review model (two-tier chain) |
| `OPENCODE_MODEL_ORCHESTRATOR` | `gemini-3-flash-preview` | Cheap model for grouping, aggregation, and summary |

> **Switching provider:** set `OPENCODE_PROVIDER` to `COPILOT` or `OPENAI`, supply that provider's `OPENCODE_<P>_URL` (Variable) + `OPENCODE_<P>_API_KEY` (Secret), **and** set the three `OPENCODE_MODEL_*` Variables to that provider's model IDs (e.g. `gpt-5.5` / `gpt-5.4` / `gpt-5.4-mini`). The model-chain defaults are Gemini IDs, which don't resolve on the Copilot/OpenAI gateways — the run **fails fast** (in [`lib/resolve-provider.sh`](.agents/skills/ai-review-report/scripts/lib/resolve-provider.sh)) if a `gemini*` model is left in place for a non-`GEMINI` provider. All three credential pairs are wired into the workflow's `env:` block, so no workflow edit is needed to enable a provider — only its URL + key + model Variables.

## Environment variables

Complete reference for every environment variable the pipeline reads. **Selector + credentials + model chain** are what you configure; **derived** vars are computed at runtime by [`lib/resolve-provider.sh`](.agents/skills/ai-review-report/scripts/lib/resolve-provider.sh) (CI: written to `$GITHUB_ENV`; local: exported by `local-review.sh`) — you never set them by hand.

| Variable | Set by | Purpose |
|---|---|---|
| `OPENCODE_PROVIDER` | GitHub **Variable** / `--provider` / shell (default `GEMINI`) | Selects the active provider: `GEMINI`, `COPILOT`, or `OPENAI`. |
| `OPENCODE_GEMININ_URL` (**Variable**) / `OPENCODE_GEMININ_API_KEY` (**Secret**) | GitHub / shell export | Gemini gateway base URL + API key (`litellm-gemini` provider). |
| `OPENCODE_COPILOT_URL` (**Variable**) / `OPENCODE_COPILOT_API_KEY` (**Secret**) | GitHub / shell export | GitHub Copilot gateway base URL + API key (`github-copilot` provider). |
| `OPENCODE_OPENAI_URL` (**Variable**) / `OPENCODE_OPENAI_API_KEY` (**Secret**) | GitHub / shell export | OpenAI gateway base URL + API key (`openai` provider). |
| `OPENCODE_MODEL_PRIMARY_REVIEW` | GitHub **Variable** / `--model` / shell (default `gemini-3.1-pro-preview`) | Primary deep chunk-review model. The `workflow_dispatch` `model` input overrides it. |
| `OPENCODE_MODEL_SECONDARY_REVIEW` | GitHub **Variable** / shell (default `gemini-2.5-pro`) | Secondary review model (two-tier fallback chain). |
| `OPENCODE_MODEL_ORCHESTRATOR` | GitHub **Variable** / shell (default `gemini-3-flash-preview`) | Cheap model for semantic grouping, aggregation, and summary. |
| `MANDATORY_CONTEXT_FILES` | Workflow `env:` (space-separated) | Context files loaded into every review (coding standards, language/tool setup, review guidelines). |
| `AGENTS_MD_EXEMPT_PATHS` | Workflow `env:` (pipe-separated) | Paths exempt from the `*_AGENTS.md` validation requirement. |
| `GITHUB_TOKEN` | GitHub Actions (or `gh auth` locally) | Posting reviews/comments and reading PR metadata. |
| `OPENCODE_PROVIDER_ID` | **Derived** | The opencode.json provider KEY the model is prefixed with: `litellm-gemini` / `github-copilot` / `openai`. |
| `OPENCODE_GATEWAY_URL` / `OPENCODE_GATEWAY_API_KEY` | **Derived** | The selected provider's URL + key, copied to generic names for the `/health` probe and gateway-reachability checks. |
