# Autonomous Low and Medium Fixer — High-Level Design

| | |
|---|---|
| **Status** | Accepted |
| **Owner** | `ai-analyse` |
| **Tracker** | [Repository issues](https://github.com/generic-automation-and-it/smooth-ai-report-review/issues) |
| **Evidence** | [ai-analyse SKILL.md](../../../.agents/skills/ai-analyse/SKILL.md) + [pipeline-ai-analyse.yml](../../../.github/workflows/pipeline-ai-analyse.yml) at `ac0d27f`; canonical LADRs in each LADR's Related section |
| **Last updated** | 2026-11-17 |

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
entirely — no fix row and no skip row (prompt-enforced). Exactly one decision per in-scope identifier
is also prompt-enforced; the workflow deterministically appends missing rows, but does not validate
row uniqueness.

**Acceptance criteria / DoD**

- No Critical or High finding appears in the fixer's table. (prompt-enforced)
- Missing in-scope rows, including residual-risk and testing-gap items, are appended by the
  deterministic completeness pass.
- Every in-scope identifier has exactly one row. (prompt-enforced; uniqueness is not mechanically
  validated)
- Testing gaps are pre-decided skip while test self-fix is off.
- Host-provided structural context may inform a FIX/SKIP decision but never widens the severity
  scope. (prompt-enforced)

### 2. Protect the independent oracles

The fixer never edits evaluation assets, and never edits tests or the test framework unless the
self-fix flag is explicitly enabled. Enforcement is deterministic: protected edits are reverted
before commit, and the model is never trusted to respect the boundary. Findings whose basis is a
failing test are withheld before the model sees them.

**Acceptance criteria / DoD**

- Zero test, framework or evaluation files are committed while the self-fix flag is off.
- Evaluation files are never committed, even when the self-fix flag is on.
- A withheld finding is named in the summary so the filtering is auditable.
- No production change is made to satisfy a failing test. (prompt-enforced)

### 3. Push only when safety was established

Auto-detected suites use regression-relative gating: a suite that passes at HEAD and fails after
the fix blocks the push; failures confirmed at HEAD are reported without blocking. Timeouts,
exhausted budgets and unavailable baselines fail closed. An explicit test command uses absolute
gating: any nonzero exit blocks publication. A test-gate-blocked summary publishes up to 30,000 bytes
of tracked-file diff and lists new-file names for a human; new file contents and a complete recovery
patch are not preserved in the run artifact.

**Acceptance criteria / DoD**

- No push occurs over a green-to-red regression.
- An auto-detected suite confirmed already red at HEAD is reported without blocking.
- A failed explicit command, exhausted budget or unavailable baseline blocks publication.
- A gate timeout always results in a skipped push with a reason, up to 30,000 bytes of tracked-file
  diff, and new-file names published; complete fix recovery is not guaranteed.

### 4. Bound and audit the loop

Automatically, the workflow triggers only after a successful gate run and requires a fresh review.
Manual `workflow_dispatch` provides an explicit recovery path against an existing eligible gate
review; it requires `pr_number` and may override `max_incremental`. Both paths reject forks and
enforce the configured incremental-cycle cap. A cycle with no edits ends the loop. Auto-fix commits
exclude tooling paths; `ci_temp` is excluded only when the consumer repo ignores it. They rebase
before pushing, and upload a redacted artifact.

**Acceptance criteria / DoD**

- The loop stops at the cycle cap or at a no-edit cycle.
- Automatic runs reject reviews predating the triggering gate run; both paths reject non-actionable
  reviews.
- A manual dispatch without `pr_number` fails; with one, it keeps the fork, gate-review and cap
  checks.
- Workflow-file edits are downgraded to a skipped push unless a workflow-scoped token is available.
- No artifact is uploaded if redaction cannot run.

### 5. Make every autonomous skip joinable

Every autonomous skip is named in the summary with its identifier, file, summary text and reason,
so a later measurement can join it to the next review. The fixer never claims that a skip propagates
to the next round: autonomous skips are not written as Skip Areas bullets. The recurrence
measurement and its fields (`unmatched_skips`, `unavailable`) are owned by HLD-006 NFR-04, not by
the fixer's design.

**Acceptance criteria / DoD**

- Each SKIP row carries the identifier, file, summary and reason columns.
- No fixer output states that a skipped finding will not be raised again.

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

- [HLD index](../README.md) — ownership map, numbering convention and source precedence.
- [003 Findings Integrity and Decision Scoring](../003-findings-and-decisions/README.md) — the findings this fixer consumes.
- [004 Review Follow-Through](../004-review-follow-through/README.md) — the human-driven sibling path.
- [001 PR Review Gate Pipeline](../001-review-gate-pipeline/README.md) — the run that triggers this loop.
- [007 Pi Agent Backend](../007-pi-agent-backend/README.md) — the second runtime that must preserve these safety guarantees (Draft).

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
