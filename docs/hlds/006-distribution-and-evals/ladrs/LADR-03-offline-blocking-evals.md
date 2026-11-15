# LADR-03: Offline Regressions Block; Paid Model Evals Report Only

**Status:** Accepted

## Context

- Paid model evaluation is nondeterministic, slow and costly.
- A flaky paid check in branch protection would block unrelated work.
- Deterministic regressions can prove install, health, config, fallback, RTK and installer behavior
  without a model or a secret.
- Fork and draft PRs still need a check result for branch protection.

## Decision

**Split** evaluation into two jobs. A secret-free offline regression job blocks relevant pull
requests, evaluates relevance inside the job rather than with path filters, and therefore always
returns a check result, including for drafts and forks. The paid model-evaluation job remains
report-only.

Precision against a labeled corpus is judged per sample by majority, because a single draw is
measurement noise rather than a verdict.

## Consequences

- Deterministic regressions protect every consumer from a broken toolchain.
- Paid evaluation cannot block a release on its own.
- Changes outside the regression job's relevance rules still receive a passing check result.
- Model quality changes require the report-only corpus to justify them.

## Related

- Canonical **LADR-033**, **LADR-069**, **LADR-087** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  blocking job in [llm-eval-harness.yml](../../../../.github/workflows/llm-eval-harness.yml).
