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
