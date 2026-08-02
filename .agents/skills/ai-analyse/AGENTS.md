# ai-analyse

## TL;DR

Autonomous counterpart to `/ai-review`: consumes the OpenCode Review Report's low/medium findings and applies only safe, scoped edits in CI. Critical and high findings remain human-owned.

## Non-Negotiables

- Touch only 🟡 Medium and 🔵 Low findings from the trusted gate-authored review body.
- **Never edit tests or the test framework by default ("test in the loop").** The suite is the independent oracle for a fix; a self-fix that also rewrites tests can mask its own regression. The workflow reverts any test/test-framework edit before commit unless the `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` Variable is truthy. Enforcement is deterministic in `scripts/lib/filter-test-self-fix.sh`, not left to the model.
- **Never fix a finding whose basis is a failing test.** A red test is evidence that a human needs to decide which is right — the code change or the test. Resolving that disagreement silently destroys the only evidence it existed. The deterministic filter `scripts/lib/filter-failing-test-findings.sh` withholds such findings before the model sees them (LADR-056); the prompt rule reinforces this regardless of the `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` toggle.
- Never edit for 🔴 Critical or 🟠 High findings, even if their suggested fixes appear nearby, and never list them in the summary table — they are omitted entirely (no FIX, no SKIP row), leaving Critical/High human-owned.
- Headless CI runs edit-only: no `git`, no commit, no push. The workflow owns those side effects.
- Never emit or create a `/ai-review` trigger. The workflow commit carries an `[ai-analyse]` marker for traceability only — the loop is bounded by the incremental-cycle cap (`OPENCODE_ANALYSE_MAX_INCREMENTAL`), not by a head-commit sentinel. A no-edit cycle (all SKIP) ends the loop early because nothing is pushed.

## Key Behaviors

- The workflow inlines `SKILL.md` into the prompt because opencode headless `run` does not auto-activate project skills and the `analyse` agent has the `skill` tool disabled.
- The agent is intentionally edit-only in `.agents/skills/ai-review-report/assets/opencode.json`: read/list/grep/glob/edit allowed; bash, skill, task, webfetch, and websearch denied.
- Summary comments are posted by the existing `.agents/skills/ai-review/scripts/copilot-review.sh summary` helper so GitHub plumbing stays centralized.
- The deterministic filter `filter-failing-test-findings.sh` withholds findings whose basis is a failing test before the model sees them, and the withheld findings are reported in the summary comment so the filtering is auditable.

## Changelog

| Date | Change | Ref |
|------|--------|-----|
| 2026-08-02 | Added the "failing test is a signal" rule: the deterministic filter `scripts/lib/filter-failing-test-findings.sh` withholds findings whose basis is a failing test before the model sees them, and the withheld findings are reported in the summary comment so the filtering is auditable. The prompt rule reinforces this unconditionally (regardless of `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX`). New offline test `scripts/test-filter-failing-test-findings.sh`. | LADR-056 |
| 2026-07-31 | `pipeline-ai-analyse.yml` now honours `OPENCODE_CLI_VERSION` (previously always installed `latest` regardless of the pin). The workflow's env block gains the Variable, and the `Initialize OPENCODE` step delegates opencode install to the shared lib `.agents/skills/ai-review-report/scripts/lib/install-opencode.sh` (LADR-048) so the analyse workflow and the review gate install opencode through one implementation. | LADR-048 |
| 2026-07-24 | Added the "test in the loop" guard: autonomous fixes no longer edit tests or the test framework unless `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` is truthy. New deterministic reverter `scripts/lib/filter-test-self-fix.sh` (+ offline test), workflow prompt/commit/summary wiring, and docs. | LADR-045 |
| 2026-07-05 | Critical/High findings are now omitted from the summary table entirely instead of appearing as SKIP rows (SKILL.md + `pipeline-ai-analyse.yml` prompt). | PR #61 |
| 2026-06-30 | Initial AGENTS.md for the `ai-analyse` skill: autonomous low/medium fixer, edit-only in CI, `[ai-analyse]` traceability marker, incremental-cycle cap. | ai-analyse |
