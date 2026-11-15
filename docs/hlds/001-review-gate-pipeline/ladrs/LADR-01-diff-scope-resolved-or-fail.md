# LADR-01: The Diff Base Is a Resolved Ancestor or the Run Stops

**Status:** Accepted

## Context

- A two-dot diff against a base tip silently includes commits the base gained after the branch point.
- A shallow or grafted checkout can make ancestry look unavailable.
- A guessed base produces a review of code the author never changed.
- An empty diff still posts a verdict, so a failed diff is worse than a failed run.

## Decision

**Adopt** one rule for every full review: resolve a true merge-base between the base branch and the
reviewed head, then diff that ancestor against the head. If resolution fails, the run fails and
posts no review; a best-effort error comment may still be posted.

Incremental reviews are different by design: they diff the selected previous reviewed commit
against the head and never resolve ancestry of their own. A plain re-fetch does not undo a shallow
graft, so resolution must deepen or unshallow rather than retry the same fetch.

## Consequences

- Every reviewed line is attributable to the PR under review.
- A broken history fails loudly instead of producing a plausible but false review.
- Review latency grows when a shallow checkout must be deepened.
- The base branch is fetched, never merged or rebased into the PR branch.

## Related

- Canonical **LADR-075**, **LADR-004** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
