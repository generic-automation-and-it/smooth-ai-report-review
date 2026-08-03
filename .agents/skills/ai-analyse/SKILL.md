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

### Input shape — what LADR-055 changed, and what it did not

The input to this skill is **unchanged in format**: `ai-review-report`'s `lib/extract-ai-analyse-scope.sh` still scrapes `### 🟡 Medium Priority Issues` and `### 🔵 Low Priority / Nitpicks` out of the posted review body, and this skill still reads those sections. Nothing here needs editing.

Two things about that input are worth knowing:

- **The findings you receive are now filtered.** When the gate has full structured-findings coverage, those sections are rendered from a merged, deduplicated set with a confidence gate applied: a Medium or Low finding the chunk reviewer anchored below confidence 75 — a verified nitpick, or something it could not evidence — is suppressed before it reaches you, and the count is printed in the review's `### 📊 Coverage` block. Expect **fewer and better-evidenced** items than before, and no cross-chunk duplicates of the same defect. Each finding now carries a stable `1)` and a `(chunk 0)` back-reference; use the `1)` in your table's `#` column when it is present rather than renumbering. The Medium section also carries `R1)` residual risks and `T1)` testing gaps (LADR-063) — separate sequences, so `R1)` is never the same item as `1)`. Quote those identifiers verbatim too; they are usually SKIPs, and a SKIP row that names `R1)` is what lets the next round tell your decision apart from an unread item.
- **Never write an identifier as `#1` (LADR-067).** The number is `1)`, with a trailing paren and no leading `#`. GitHub autolinks `#` followed by digits to an issue or PR, so `#1` in anything you emit renders as a link to that repo's issue #1 and leaves a cross-reference on it. When an identifier leads a markdown bullet, bold it — `- **1)** …` — because a bare `1)` at the head of a bullet is a CommonMark ordered-list marker and the number disappears from the rendered text.
- **`ci_temp/findings.merged.json` exists and is the intended future input.** The gate writes the full structured document — including `autofix_class` (`gated_auto` / `manual` / `advisory`), `owner`, `requires_verification`, and `suggested_fix` per finding — which is a far better autonomy predicate than "the severity is Medium": under the current severity-only rule (LADR-042) a Medium needing a design decision is auto-fixable while a Critical with a one-line mechanical fix is not. **Nothing consumes it yet.** Switching this skill's selection predicate from severity to route is a separate, deliberate change (Tier 1 item 5); do not start reading the JSON opportunistically, because the current comment-scraping path is what the workflow's trust boundary and `filter-test-self-fix.sh` enforcement are built around.

## Decision Rules

- Known intentional pattern: `SKIP`
- AI hallucination or stale review text: `SKIP`
- Genuine bug or logic error in a low/medium finding: `FIX`
- Real simplification with no trade-off: `FIX`
- Speculative / "consider" language: `SKIP`
- A finding whose only viable fix would edit a test or the test framework, while `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` is off (the default): `SKIP` with reason "test edit not allowed (OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX off)"
- A finding whose basis is that a test is failing (regardless of `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX`): `SKIP` with reason "failing test is a signal — human decision required"
- A Critical or High finding itself (its own priority is 🔴/🟠), even if included in suggested fixes: **omit entirely — no row, neither FIX nor SKIP**

## Guardrails

- **Test in the loop.** By default (`OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` unset/off) never edit a test file — unit, component, integration, or e2e — or any test-framework/config file. The suite must stay an independent oracle that proves the fix did not break anything; a self-fix that also rewrites the tests can hide its own regression. Only when `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` is truthy (`1`/`true`/`yes`/`on`) may a fix update tests and the test framework. The workflow enforces this deterministically — any test-file edit made while the setting is off is reverted before commit — so treat test files as read-only rather than relying on that safety net.
- **Failing tests are signals, not defects.** A failing test is evidence that a human needs to decide which is right — the code change or the test. Never FIX a finding whose basis is that a test is failing, and never change production code to make a failing test pass. Resolving that disagreement silently destroys the only evidence it existed. The deterministic filter withholds such findings before the model sees them; the prompt rule reinforces this regardless of the `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` toggle.
- Never touch 🔴 Critical or 🟠 High findings, and never list them in the summary table — omit them entirely (no FIX, no SKIP row).
- Never add a `/ai-review` marker.
- Keep every edit scoped to the supplied low/medium review text.
- Do not invent findings beyond the supplied review sections.
- Prefer minimal edits over refactors.
- The auto-fix commit message is owned by the workflow and carries `[ai-analyse]`.
- If no safe file edit is possible, print SKIP rows and leave the working tree unchanged.
- **Test gate.** After the model edits and `filter-test-self-fix.sh` reverts any test edits, the workflow runs the project's test suites via `run-test-gate.sh`. Gating is **regression-relative**: a suite that fails after your edits is re-run against a pristine checkout of HEAD, and only a suite that *passes at HEAD and fails after* blocks the push (`push_skipped=true`, `skip_reason=test-suite-failed`). A suite that was already red is reported but does not block — otherwise one stale suite would disable the loop permanently. A timeout always blocks, because it means safety could not be established. Your fixes are preserved, not reverted, and the diff is published in the summary comment for a human to apply. Set `OPENCODE_ANALYSE_TEST_COMMAND` to override auto-detection, or `OPENCODE_ANALYSE_TEST_TIMEOUT` to change the whole-gate budget (default 600s).
