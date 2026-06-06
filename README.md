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

- A `self-hosted` runner (the LiteLLM model gateway is on a private network).
- GitHub **Secrets** `OPENCODE_LITELLM_URL` and `OPENCODE_LITELLM_API_KEY`; optional **Variables** `OPENCODE_MODEL_*` to retune the model chain without editing the workflow.

## Providers

OpenCode is provider-agnostic — the committed config ([`.agents/skills/ai-review-report/assets/opencode.json`](.agents/skills/ai-review-report/assets/opencode.json)) defines the providers OpenCode can route to. Each provider reads its gateway URL and API key from environment variables (`{env:...}` substitution), so credentials never live in the repo.

| Provider | Status | Models | Env vars (gateway URL + key) |
|---|---|---|---|
| **Gemini** (`litellm-gemini`, `@ai-sdk/google`) | Default — the model chain points here | `gemini-3.1-pro-preview`, `gemini-2.5-pro`, `gemini-3-flash-preview`, `gemini-2.5-flash` | `OPENCODE_GEMININ_URL`, `OPENCODE_GEMININ_API_KEY` |
| **GitHub Copilot** (`github-copilot`, `@ai-sdk/github-copilot`) | Optional | `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` | `OPENCODE_COPILOT_URL`, `OPENCODE_COPILOT_API_KEY` |
| **OpenAI** (`openai`, `@ai-sdk/openai`) | Optional | `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` | `OPENCODE_OPENAI_URL`, `OPENCODE_OPENAI_API_KEY` |

A provider is only invoked if the model chain (`OPENCODE_MODEL_*`) names one of its models — qualify cross-provider models as `provider/model` (e.g. `openai/gpt-5.5`). Optional providers can be left unconfigured: if their env vars are unset OpenCode simply never routes to them, so you only need credentials for the providers your model chain actually uses.

### GitHub configuration

Set these under repo (or org) **Settings → Secrets and variables → Actions**. The workflow exports each value into the job env so OpenCode's `{env:...}` substitution resolves at runtime.

**Secrets** (one URL + API key pair per provider you enable):

| Secret | For | Required? |
|---|---|---|
| `OPENCODE_GEMININ_URL` | Gemini gateway base URL | Required (default provider) |
| `OPENCODE_GEMININ_API_KEY` | Gemini gateway API key | Required (default provider) |
| `OPENCODE_COPILOT_URL` | GitHub Copilot gateway base URL | Only if using Copilot models |
| `OPENCODE_COPILOT_API_KEY` | GitHub Copilot gateway API key | Only if using Copilot models |
| `OPENCODE_OPENAI_URL` | OpenAI gateway base URL | Only if using OpenAI models |
| `OPENCODE_OPENAI_API_KEY` | OpenAI gateway API key | Only if using OpenAI models |

**Variables** (optional — retune the model chain without editing the workflow; each falls back to a literal default if unset):

| Variable | Default | Role |
|---|---|---|
| `OPENCODE_MODEL_PRIMARY_REVIEW` | `gemini-3.1-pro-preview` | Primary deep chunk-review model |
| `OPENCODE_MODEL_SECONDARY_REVIEW` | `gemini-2.5-pro` | Secondary review model (two-tier chain) |
| `OPENCODE_MODEL_ORCHESTRATOR` | `gemini-3-flash-preview` | Cheap model for grouping, aggregation, and summary |

> **Note:** the committed workflow currently exports only the Gemini gateway env vars (under the original `OPENCODE_LITELLM_*` secret names). If you enable the optional Copilot/OpenAI providers — or point the Gemini provider at the `OPENCODE_GEMININ_*` secrets — add the matching `secrets.*` → `env:` mappings to the job's `env:` block in [`.github/workflows/pipline-code-review-report.yml`](.github/workflows/pipline-code-review-report.yml) so the substitution can resolve.
