# Autonomous Low and Medium Fixer — High-Level Design

| | |
|---|---|
| **Status** | Accepted (as built, 2026-11-15) |
| **Owner** | `ai-analyse` |
| **Tracker** | [Repository issues](https://github.com/generic-automation-and-it/smooth-ai-report-review/issues) |
| **Evidence** | [ai-analyse SKILL.md](../../../.agents/skills/ai-analyse/SKILL.md) + [pipeline-ai-analyse.yml](../../../.github/workflows/pipeline-ai-analyse.yml) at `0a8a7a2`; canonical LADRs in each LADR's Related section |
| **Last updated** | 2026-11-15 |

> Design record for the delivered autonomous fixer. It states **intent + spec**; execution
> sequencing lives in the issue tracker.

## Intent

Safe, well-evidenced low and medium findings should not wait for a human to apply them. At the same
time, the fixer must never become an oracle that grades its own work. This design specifies a
narrow scope, deterministic fences around tests and evaluation, a test gate that is regression-relative
for auto-detected suites and absolute for an explicit command, and a bounded loop that the workflow —
not the model — controls.

## Key Goals

### 1. Keep the scope narrow

Only gate-authored Medium and Low findings are eligible. Critical and High findings are omitted
entirely — no fix row and no skip row. Every in-scope identifier receives exactly one decision, and
the workflow fills any omission deterministically.

**Acceptance criteria / DoD**

- No Critical or High finding appears in the fixer's table.
- Every in-scope identifier has exactly one row, including residual-risk and testing-gap items.
- Testing gaps are pre-decided skip while test self-fix is off.

### 2. Protect the independent oracles

The fixer never edits evaluation assets, and never edits tests or the test framework unless the
self-fix flag is explicitly enabled. Enforcement is deterministic: protected edits are reverted
before commit, and the model is never trusted to respect the boundary. Findings whose basis is a
failing test are withheld before the model sees them.

**Acceptance criteria / DoD**

- Zero test, framework or evaluation files are committed while the self-fix flag is off.
- Evaluation files are never committed, even when the self-fix flag is on.
- A withheld finding is named in the summary so the filtering is auditable.
- No production change is made to satisfy a failing test.

### 3. Push only when safety was established

Auto-detected suites use regression-relative gating: a suite that passes at HEAD and fails after
the fix blocks the push; failures confirmed at HEAD are reported without blocking. Timeouts,
exhausted budgets and unavailable baselines fail closed. An explicit test command uses absolute
gating: any nonzero exit blocks publication. Blocked fixes are preserved and published for a human.

**Acceptance criteria / DoD**

- No push occurs over a green-to-red regression.
- An auto-detected suite confirmed already red at HEAD is reported without blocking.
- A failed explicit command, exhausted budget or unavailable baseline blocks publication.
- A gate timeout always results in a skipped push with the fix diff published.

### 4. Bound and audit the loop

Automatically, the workflow triggers only after a successful gate run and requires a fresh
review. Manual dispatch provides an explicit recovery path against an existing eligible gate
review. Both paths reject forks and enforce the configured incremental-cycle cap, which manual
dispatch may explicitly override. A cycle with no edits ends the loop. Auto-fix
commits exclude workflow scratch and tooling paths, rebase before pushing, and upload a redacted
artifact.

**Acceptance criteria / DoD**

- The loop stops at the cycle cap or at a no-edit cycle.
- Automatic runs reject reviews predating the triggering gate run; both paths reject non-actionable reviews.
- Workflow-file edits are downgraded to a skipped push unless a workflow-scoped token is available.
- No artifact is uploaded if redaction cannot run.

## Core Separation of Concerns

> The model proposes edits; the workflow decides whether they are safe to publish.

The model is edit-only and has no shell, no git and no network. The workflow owns scope extraction,
filters, the test gate, commit, rebase, push and audit output. That split keeps every irreversible
action outside the model's reach.

## Guiding Principle — The suite is the oracle, never the fixer's pen

- A fix may not rewrite the test that proves it.
- A red test is a human decision, not a defect to silence.
- Unattended work is acceptable only with a deterministic boundary and an audit trail.

## Related HLDs

- [003 Findings Integrity and Decision Scoring](../003-findings-and-decisions/README.md) — the findings this fixer consumes.
- [004 Review Follow-Through](../004-review-follow-through/README.md) — the human-driven sibling path.
- [001 PR Review Gate Pipeline](../001-review-gate-pipeline/README.md) — the run that triggers this loop.

---

## Diagrams

- [System Context (C1) + fixer loop](./diagrams/c4-context.md)

## Architecture Decisions (LADRs)

| LADR | Decision | Status |
|------|----------|--------|
| [LADR-01](./ladrs/LADR-01-severity-only-scope.md) | Selection stays severity-based; merged JSON is not consumed yet | Accepted |
| [LADR-02](./ladrs/LADR-02-test-in-the-loop.md) | Test and evaluation edits are off by default and reverted deterministically | Accepted |
| [LADR-03](./ladrs/LADR-03-failing-test-is-signal.md) | Failing-test findings are withheld before the model sees them | Accepted |
| [LADR-04](./ladrs/LADR-04-regression-relative-gate.md) | Auto-detected suites gate on regressions; explicit commands gate absolutely | Accepted |
| [LADR-05](./ladrs/LADR-05-workflow-owns-side-effects.md) | The workflow owns every side effect and fences its own tooling | Accepted |

## Non-Functional Requirements

| NFR | Attribute | Target (summary) | Status |
|-----|-----------|------------------|--------|
| [NFR-01](./nfrs/NFR-01-oracle-integrity.md) | Oracle integrity | Zero protected-file changes in committed fixes | Accepted |
| [NFR-02](./nfrs/NFR-02-push-safety.md) | Push safety | Zero pushes over a regression or timeout | Accepted |
| [NFR-03](./nfrs/NFR-03-bounded-loop-audit.md) | Boundedness and audit | Cycle cap enforced; artifact redacted or withheld | Accepted |
