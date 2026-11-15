# Review Follow-Through — High-Level Design

| | |
|---|---|
| **Status** | Accepted |
| **Owner** | `ai-review` + `git-commit-review-push` |
| **Tracker** | [Repository issues](https://github.com/generic-automation-and-it/smooth-ai-report-review/issues) |
| **Evidence** | [ai-review SKILL.md](../../../.agents/skills/ai-review/SKILL.md) + [git-commit-review-push SKILL.md](../../../.agents/skills/git-commit-review-push/SKILL.md) at `0a8a7a2`; canonical LADRs in each LADR's Related section |
| **Last updated** | 2026-11-15 |

> Design record for the delivered consumer skill and commit trigger. It states **intent + spec**;
> execution sequencing lives in the issue tracker.

## Intent

A posted review only changes a PR if its decisions are applied safely and its skips survive the next
round. This design specifies the consumer that analyses and executes decisions, the source-routed
result channels, the boundary between model advice and human decisions, and the commit trigger that
guarantees the next full review.

## Key Goals

### 1. Make read-only the default

Analysis never edits a file, commits, pushes, replies to a thread or writes a PR description.
Execution happens only with explicit per-item decisions or the explicit all-item opt-in. Conflicting
mode combinations are rejected before any edit.

**Acceptance criteria / DoD**

- Plain analysis leaves the tree and the PR untouched.
- Execution requires a resolvable PR and review.
- A review's imperative wording never selects execution on its own.

### 2. Route results by review source

For Copilot issues with mapped inline comments and threads, reply and resolve each processed
thread. Issues without that mapping are reported only through the single review-level summary
comment, which includes all processed issues. Any other review appends AI Review Notes to the PR
description and writes every skipped item into the Skip Areas bullets, then verifies those bullets
in the live body.

**Acceptance criteria / DoD**

- Every processed Copilot issue with a mapped inline comment and thread receives a reply and
  resolution; unrelated threads are untouched.
- Copilot issues without that mapping appear in the review-level summary comment only.
- Every skipped item has a Skip Areas bullet containing the skip-reason marker after the edit.
- The verification reads only the Skip Areas section, not the whole body.

### 3. Keep decision labels human-only

The invisible decision label block records only explicit per-item human choices, only for numbered
findings, and only when the processed review carries a run marker. Model recommendations and
autonomous runs never write it.

**Acceptance criteria / DoD**

- Analysis, all-item execution and the autonomous fixer produce no label block.
- Residual-risk, testing-gap, pre-existing and historical holistic items never enter it.
- A doubtful skip records the deferred class, which the harvester ignores.

### 4. Trigger the next full review

The dedicated commit-and-push path always requests a full review: only its final chunk commit carries
the review trigger, before any trailer block. During review execution, the trigger and empty
re-verification rule in [root AGENTS.md](../../../AGENTS.md) applies; this HLD records only where the
trigger must sit.

**Acceptance criteria / DoD**

- The gate's whole-message matcher finds the trigger on the pushed head.
- Every Critical-or-High review ends with the empty re-verification commit.
- Medium- and Low-only reviews make no empty commit.
- The clean-tree path verifies or amends the head before pushing.

## Core Separation of Concerns

> The consumer changes the PR; the gate judges it. Neither writes the other's evidence.

Analysis reads what the gate posted. Execution applies only decisions a human authorized or
explicitly opted into, then routes results to the channel the review source defines. The commit
trigger hands control back to the gate for a fresh, independent review.

## Guiding Principle — A review is input, not authorization

- Read-only is the default; every write has a named opt-in.
- Skip rationale that reaches only the table is a silent failure.
- Model output may advise, but only a human decision becomes a label.

## Related HLDs

- [HLD index](../README.md) — ownership map, numbering convention and source precedence.
- [003 Findings Integrity and Decision Scoring](../003-findings-and-decisions/README.md) — the evidence this skill consumes.
- [001 PR Review Gate Pipeline](../001-review-gate-pipeline/README.md) — the next round this skill triggers.
- [005 Autonomous Low and Medium Fixer](../005-autonomous-fixer/README.md) — the unattended sibling path.

---

## Diagrams

- [System Context (C1) + follow-through flow](./diagrams/c4-context.md)

## Architecture Decisions (LADRs)

| LADR | Decision | Status |
|------|----------|--------|
| [LADR-01](./ladrs/LADR-01-analysis-read-only.md) | Analysis is read-only; execution needs an explicit opt-in | Accepted |
| [LADR-02](./ladrs/LADR-02-source-routed-skip-bullets.md) | Results route by source; Skip Areas bullets are load-bearing | Accepted |
| [LADR-03](./ladrs/LADR-03-human-only-labels.md) | Decision labels come only from explicit human choices | Accepted |
| [LADR-04](./ladrs/LADR-04-trigger-on-final-commit.md) | The review trigger rides the final commit, before trailers | Accepted |

## Non-Functional Requirements

| NFR | Attribute | Target (summary) | Status |
|-----|-----------|------------------|--------|
| [NFR-01](./nfrs/NFR-01-skip-propagation.md) | Skip durability | 100% of skipped items verified in the live PR body | Accepted |
| [NFR-02](./nfrs/NFR-02-identifier-fidelity.md) | Identifier fidelity | Verbatim identifiers; zero auto-linking tokens | Accepted |
| [NFR-03](./nfrs/NFR-03-trigger-coverage.md) | Trigger coverage | Pushed head always matches the gate trigger | Accepted |
