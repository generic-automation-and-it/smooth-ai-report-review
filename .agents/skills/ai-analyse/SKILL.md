---
name: ai-analyse
switches:
  - "`--analyse <review-ref>` - inspect the latest gate review or supplied review reference and recommend FIX/SKIP decisions for low/medium findings only."
  - "`--execute <pr>` - apply FIX decisions for low/medium findings and print a FIX/SKIP summary table."
  - "`--source=opencode` - force OpenCode Review Report parsing; this is the default in CI."
description: Autonomous low/medium AI review fixer. Reads an OpenCode Review Report, ignores Critical/High findings, applies only safe Medium/Low fixes, and emits a FIX/SKIP summary. In headless CI it edits files and prints the table only; the workflow owns commit, push, and PR comment posting.
allowed-tools:
  - Bash(.agents/skills/ai-analyse/scripts/*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/.agents/skills/ai-analyse/scripts/*)
  - Bash(.agents/skills/ai-review/scripts/copilot-review.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/.agents/skills/ai-review/scripts/copilot-review.sh:*)
  # The three git entries below are for LOCAL /ai-analyse --execute invocations
  # only (e.g. from Claude Code). In headless CI they are NON-BINDING: the
  # `analyse` opencode agent in ai-review-report/assets/opencode.json denies bash,
  # and the pipeline-ai-analyse.yml workflow owns commit/push/PR-comment (see the
  # CI Contract below). Do not rely on these for the autonomous loop.
  - Bash(git add:*)
  - Bash(git commit:*)
  - Bash(git push:*)
models:
  claude: sonnet
  copilot: auto
  codex: gpt-5.4
---

# AI Analyse

Autonomously process low/medium findings from the OpenCode Review Report.

> **Script location.** Every `.agents/skills/ai-analyse/...` path in this document assumes the skill is installed in the repository. When this skill runs from the Claude Code plugin (`smooth-ai-review`), substitute `${CLAUDE_PLUGIN_ROOT}/.agents/skills/ai-analyse` for `.agents/skills/ai-analyse` in script paths.

## Invocation

The skill is invoked as `/ai-analyse <args>`.

Modes:

- `--analyse <review-ref>`: fetch the relevant PR review, parse only `### 🟡 Medium Priority Issues` and `### 🔵 Low Priority / Nitpicks`, and emit a recommendation table. **Omit `### 🔴 Critical Issues` and `### 🟠 High Priority Issues` findings entirely** — do not add a FIX or SKIP row for them; they must not appear in the table at all.
- `--execute <pr>`: apply fixes for rows marked FIX, keep edits scoped to listed low/medium items, and print the final FIX/SKIP markdown table.

## CI Contract

The GitHub Actions workflow invokes this skill headlessly by inlining this `SKILL.md` into an `opencode run --agent analyse` prompt. In CI:

1. Edit files only for gate-authored low/medium findings supplied in the prompt.
2. Do not run `git`, do not commit, and do not push.
3. Print a markdown table to stdout with the exact columns, containing **only Medium and Low findings** (a Critical/High finding never gets a row — omit it entirely):

| # | Decision | Priority | File | Summary | Reason |
|---|----------|----------|------|---------|--------|

4. Use `FIX` only when the change is mechanical, directly supported by the listed finding, and low risk.
5. Use `SKIP` when a **Medium/Low** finding is speculative, already addressed, unclear, requires product judgment, would require broader refactoring, or whose fix would touch Critical/High behavior. Never use SKIP (or FIX) to represent a Critical/High finding itself — those are omitted from the table.

The workflow performs deterministic commit, rebase/push, and PR comment posting after the model exits. If those git-owned steps cannot rebase onto the latest PR head or fetch it reliably, the workflow posts the summary with `push_skipped` and leaves the branch unchanged for a later retry or human follow-up.

## Decision Rules

- Known intentional pattern: `SKIP`
- AI hallucination or stale review text: `SKIP`
- Genuine bug or logic error in a low/medium finding: `FIX`
- Real simplification with no trade-off: `FIX`
- Speculative / "consider" language: `SKIP`
- A finding whose only viable fix would edit a test or the test framework, while `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` is off (the default): `SKIP` with reason "test edit not allowed (OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX off)"
- A Critical or High finding itself (its own priority is 🔴/🟠), even if included in suggested fixes: **omit entirely — no row, neither FIX nor SKIP**

## Guardrails

- **Test in the loop.** By default (`OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` unset/off) never edit a test file — unit, component, integration, or e2e — or any test-framework/config file. The suite must stay an independent oracle that proves the fix did not break anything; a self-fix that also rewrites the tests can hide its own regression. Only when `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` is truthy (`1`/`true`/`yes`/`on`) may a fix update tests and the test framework. The workflow enforces this deterministically — any test-file edit made while the setting is off is reverted before commit — so treat test files as read-only rather than relying on that safety net.
- Never touch 🔴 Critical or 🟠 High findings, and never list them in the summary table — omit them entirely (no FIX, no SKIP row).
- Never add a `/ai-review` marker.
- Keep every edit scoped to the supplied low/medium review text.
- Do not invent findings beyond the supplied review sections.
- Prefer minimal edits over refactors.
- The auto-fix commit message is owned by the workflow and carries `[ai-analyse]`.
- If no safe file edit is possible, print SKIP rows and leave the working tree unchanged.
