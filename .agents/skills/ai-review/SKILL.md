---
name: ai-review
description: Analyze and execute AI PR review feedback with fix/skip decisions. Use when a user asks to parse an AI review, apply selected fixes, update PR AI review notes, and finalize review processing for GitHub or Azure DevOps pull requests.
---

# AI PR Review Analyzer & Executor

Analyze AI PR review feedback and execute fix/skip decisions.

## Invocation

The skill is invoked as `/ai-review <args>`. 

**Mode selection:**

1. **Explicit keyword** as the first argument: `analyse` or `execute`.
2. **Auto-detect** when no keyword is given:
   - If any argument matches `\d+=(fix|skip)` → **execute** mode.
   - Otherwise → **analyse** mode.

Examples:

```
/ai-review 48                              # auto → analyse
/ai-review analyse 48                      # explicit analyse
/ai-review 48 1=fix 2=skip                 # auto → execute
/ai-review execute 48 1=fix 2=skip         # explicit execute
```

## Two Modes: `analyse` and `execute`

### Mode 1: Analyse — Fetch review and recommend fixes/skips

**Use when**: User provides review URL, review ID, or just PR number

**Workflow:**

1. **Resolve PR number and review ID** from arguments
2. **Fetch review body** using `gh api` or `az repos pr` CLI
3. **Parse the review** to extract issues and suggested fixes
4. **Determine recommendation** for each issue:
   - Known intentional pattern: `skip`
   - AI hallucination: `skip`
   - Genuine bug or logic error: `fix`
   - Real simplification with no trade-offs: `fix`
   - Speculative / "consider" language: `skip`
   - Critical/High without exemption: `fix`

5. **Output analysis table:**

| # | File | AI PR Review Recommendation | Priority | AI Coder Recommendation | AI Reviewer Reasoning |
|---|------|----------------------------|----------|------------------------|-----------------------|

6. **Print summary** and suggested next command

7. **STOP** — Do NOT proceed to execute automatically. User decides whether and how to run execute.

---

### Mode 2: Execute — Apply fix/skip decisions

**Use when**: User provides decisions from analyse output

**Argument format**: `<pr-number> <1=fix|skip> <2=fix|skip> ...`

**Workflow:**

1. **Load review context** — Fetch latest AI review
2. **Process each decision** — Apply fixes or prepare skip entries
3. **Commit and push fixes** (only if any fixes were applied)
4. **Update PR AI Review Notes** — Append responses block
5. **Final empty commit** — ci: /ai-review — processed review responses
6. **Report completion**
7. **Review process improvements** (only if items were skipped)

## Guardrails

- Never auto-execute after analyse mode
- Keep fixes scoped to selected items only
- Preserve existing PR AI Review Notes content
- Only suggest review-process improvements, don't apply them
