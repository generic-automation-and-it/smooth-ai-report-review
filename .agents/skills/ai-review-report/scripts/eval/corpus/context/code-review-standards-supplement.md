# Code Review Standards — Supplement (DR-012 … DR-015)

> **Eval-corpus context file.** The eval harness places this at the production
> path `.agents/skills/code-review-standards/SKILL.md` inside each fixture
> sandbox so the reviewer reads the SAME standards production injects via
> `MANDATORY_CONTEXT_FILES`. DR-001…DR-011 live in
> `.github/instructions/code-review-standards.instructions.md` (copied verbatim).
> DR-012…DR-014 below mirror the `ai-review-report` SKILL.md **Key Behaviors** —
> keep in sync with that file (the source of truth).

Intentional patterns for AI reviewers to prevent false positives.

## ADRs (continued)

### DR-012: EF Core Expression Tree Navigation — Do NOT Flag NRE

Navigation property access inside EF Core `.Select()`, `.Where()`, `.OrderBy()`
lambdas is compiled into an **expression tree** and translated to SQL (LEFT/INNER
JOIN with NULL propagation) — it is **NOT executed as runtime C#**. Do NOT flag
NullReferenceException risk or suggest the null-conditional operator (`?.`) on
navigation properties inside these lambdas.

- **Signal**: the method returns `IQueryable<T>` or the chain ends with
  `.ToListAsync()` / `.ToList()` is NOT yet called.
- **Materialized code is different**: after `.ToList()`, `.FirstOrDefault()`,
  `.AsEnumerable()`, the code IS runtime C# and normal NRE rules apply.
- **DO NOT suggest**: `?.` on a navigation property inside a `Select`/`Where`
  expression tree; "possible NRE on `x.Related.Name`" inside an `IQueryable`.

Confirmed recurring false positive (BNKI-780 rounds 1 and 2).

### DR-013: Mode-Aware Regression Analysis — Trace Every Execution Mode Before Flagging a Deleted Guard

When a PR deletes a `throw`, early-return, or guard clause that was conditional on
a feature flag, configuration value, or mode selector, do NOT flag it as a
regression without first tracing the pre-PR behaviour **in every execution mode
the code supported**. If the deleted branch was already **dead code**
(unreachable or bypassed) in the mode that survives the PR, there is **no
regression** — the PR is simply removing dead code alongside the mode it belonged
to.

- **Signal**: the PR description mentions "remove mode", "deprecate flag", "single
  worker"; or the diff deletes both a flag property AND the branches gated on it.
- **A deleted guard IS a real regression** only when the surviving mode could
  still reach it pre-PR.

Confirmed false positive: PR #4992 (BNKI-1066) flagged `FtpHelper.cs` "swallowed
exceptions regression" after `if (!config.ContinueWorking) throw;` was deleted
alongside the `ContinueWorking` property — in continuous mode (the surviving
mode) the throw was never reached pre-PR, so behaviour is identical.

### DR-014: Diff + LADR/Spec Beats PR-Body Intent

When the PR description wording (Focus Areas, Known Issues, intent claims)
conflicts with the current diff against base **or** with an LADR / `*_AGENTS.md`
in the loaded context, treat the **diff and the LADR as ground truth**. PR-body
text goes stale across follow-up commits and design changes. Do NOT mass-flag
code as wrong because it contradicts an outdated PR-body claim — flag the
**description** as stale at 🔵 Low instead.

If an LADR's Decision / Alternatives Considered / Implementation notes records the
chosen approach, the implementation is **by definition intentional** — do not
raise the chosen approach at Critical/High.

- **Self-consistency check**: if your own per-chunk review confirms an LADR is
  correct ("perfectly reflects the codebase"), you cannot raise that same chosen
  approach as Critical elsewhere in the same review.

Confirmed false positives: PR #5258 (BNKI-1190) — High×14 on `Secondary.Enabled:
true` because the original AI Review Notes said "off in prod" (superseded by a
later commit); plus a Critical "missing type-name discriminator" despite the LADR
explicitly choosing connection-string discrimination.

### DR-015: GitHub Actions reusable-workflow context is the caller's

In a workflow with `on.workflow_call`, the `github` context inside the called (reusable)
workflow is inherited from the CALLER: `github.event_name` is the caller's triggering
event (`pull_request`, `workflow_dispatch`, ...) — it is never `"workflow_call"` — and
`github.event.pull_request.*` is fully populated when the caller was PR-triggered.

Do NOT flag as bugs:
- A job `if:` gate that lists caller event names without a `workflow_call` clause.
- `github.event.pull_request.*` references "unavailable in workflow_call context".
- A caller not forwarding the PR number as an input when the callee reads it from the event.

Related glob trap: `on.push.branches/tags/paths` filters are glob patterns, not regex —
dots are literal; do not suggest regex-escaping.

Confirmed recurring false positive: PR #36 (review 4473891333) — two hallucinated
Criticals + one High produced a wrong REQUEST_CHANGES.
