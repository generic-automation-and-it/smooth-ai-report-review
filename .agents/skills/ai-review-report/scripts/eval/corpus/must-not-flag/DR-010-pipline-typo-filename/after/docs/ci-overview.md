# CI Overview

## Workflows

### PR Code Review Gate

**File**: `.github/workflows/pipline-code-review-report.yml`

The automated PR review gate runs on every non-draft pull request. It sends
chunked diffs to the configured model provider (Gemini, Copilot, OpenAI, or
OpenCode Go) and posts a structured review back to the PR.

> **Note**: The workflow filename `pipline-code-review-report.yml` contains a
> deliberate misspelling ("pipline"). This name is **load-bearing**: skill scripts
> under `.agents/skills/ai-review-report/scripts/` reference it by hardcoded
> path. Do not rename the file.

#### Triggering manually

```bash
gh workflow run pipline-code-review-report.yml \
  --field pr_number=42
```

#### Provider selection

Set the `OPENCODE_PROVIDER` repository variable to one of:
`GEMINI` | `COPILOT` | `OPENAI` | `OPENCODE-GO-OPENAI` | `OPENCODE-GO-ANTHROPIC`

The gate reads this variable at job start and routes all model calls through
the matching provider configured in
`.agents/skills/ai-review-report/assets/opencode.json`.
