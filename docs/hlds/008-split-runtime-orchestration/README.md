# Split Runtime — pi chunk review, OpenCode orchestration

| | |
|---|---|
| **Status** | Draft |
| **Owner** | `ai-review-report` + `ai-analyse` |
| **Tracker** | [Repository issues](https://github.com/generic-automation-and-it/smooth-ai-report-review/issues) |
| **Evidence** | Not yet delivered — this record specifies the intent and the contract |
| **Last updated** | 2026-11-20 |

> Discovery HLD. This document delivers **intent + spec** — what we are building and why, the
> decisions behind it, and the quality bar it must meet. It does **not** contain an implementation
> plan; execution is tracked in the issue tracker.

## Intent

The gate executes every model call on one runtime. Its two workload classes have different optima.
Chunk review is volume-bound: many parallel calls, large diffs, a fail-closed coverage contract.
Semantic grouping and aggregation are two synthesis calls where the incumbent runtime's behaviour is
the measured baseline. This design lets each role run on the runtime that fits it, without forking
prompts, post-processing or failure handling.

## Key Goals

### 1. Per-role runtime selection without behavioural forks

Each call site resolves exactly one runtime from an explicit selector; the gate's shared layers —
prompt building, enrichment, post-processing — remain identical whichever runtime executes.

**Acceptance criteria / DoD**

- One selector resolves one runtime per role; an unknown value fails before any model call.
- No review behaviour or post-processing step exists in a runtime-specific variant.
- A runtime failure reaches the failure channel that role already handles.

### 2. Equivalent evidence for chunk review on either runtime

A chunk is reviewed against the same prompt and the same delivered instruction set on both runtimes,
including context a runtime attaches during exploration.

**Acceptance criteria / DoD**

- Prompt bytes for the same chunk are identical across runtimes.
- The delivered instruction set — generated chunk artifact plus native and on-read context — is equal
  by content for both runtimes; exact context files are never delivered twice.
- The consumed rule-source set is unchanged; no rule directory is discovered because of a runtime.

### 3. Coverage-first chunk execution

Chunk execution is judged by completed coverage, not by elegance: a runtime change is acceptable only
if it does not lose chunks.

**Acceptance criteria / DoD**

- On the same corpus revision, the split runtime's unreviewed/timed-out chunk rate is no worse than the
  incumbent runtime's baseline.
- Per-chunk latency is recorded for both runtimes in the evaluation evidence.

### 4. Orchestration stays on the incumbent runtime

Semantic grouping and aggregation remain on the runtime whose synthesis behaviour the gate is tuned
against, unless an explicit override selects otherwise.

**Acceptance criteria / DoD**

- With no override, grouping and aggregation execute on the incumbent runtime.
- Posted bodies are byte-identical to today for the same chunk set.
- Orchestration failure semantics — fall back to the resolved review model — are unchanged.

### 5. RTK integrates with both active runtimes

RTK is available to whichever runtime executes model calls, within its own supported floor.

**Acceptance criteria / DoD**

- RTK initializes for the pi runtime through its own agent target and for OpenCode through its plugin.
- A runtime whose RTK integration is below its supported floor is skipped with one notice; the review
  still runs.
- RTK initialization never blocks a review.

### 6. Credentials and failure taxonomy unchanged per attempt

Splitting the runtime does not widen the child environment or change how a failed attempt is
classified.

**Acceptance criteria / DoD**

- Each model attempt holds exactly one provider key, whichever runtime executes it.
- A chunk failure still fail-closes; an orchestration failure still falls back.
- No workflow-level permission, persisted credential or hook-proof git behaviour changes.

## Core Separation of Concerns

> The runtime executes the model; the gate owns context, policy, routing and side effects.

Per-role selection is routing, not a behavioural definition. Every behavioural rule — the role
contract, the prompt, the failure taxonomy — remains single-homed in the gate.

## Guiding Principle — Split the runtime, never the contract

- One prompt-in/answer-out contract, one post-processing chain, one failure taxonomy per role.
- Two native lockdown implementations remain acceptable; two behavioural definitions do not.
- Coverage beats elegance: a runtime that loses a chunk is not an improvement.

---

## Diagrams

- [System Context (C1) and routing flow](./diagrams/c4-context.md)

## Architecture Decisions (LADRs)

| LADR | Decision | Status |
|------|----------|--------|
| [LADR-01](./ladrs/LADR-01-role-scoped-runtime-selection.md) | Runtime selection is role-scoped, not per call | Draft |
| [LADR-02](./ladrs/LADR-02-chunk-evidence-parity.md) | pi may review chunks only with equal delivered evidence | Draft |
| [LADR-03](./ladrs/LADR-03-orchestration-incumbent.md) | Orchestration remains on the incumbent runtime | Draft |
| [LADR-04](./ladrs/LADR-04-rtk-per-runtime.md) | RTK initializes per active runtime at its own floor | Draft |
| [LADR-05](./ladrs/LADR-05-per-role-failure-mapping.md) | Failure mapping is per role, not per runtime | Draft |
| [LADR-06](./ladrs/LADR-06-promotion-is-measured.md) | Promoting pi chunks to default is measured | Draft |

## Non-Functional Requirements

| NFR | Attribute | Target (summary) | Status |
|-----|-----------|------------------|--------|
| [NFR-01](./nfrs/NFR-01-per-chunk-evidence-parity.md) | Evidence parity | Same chunk yields identical prompt and delivered context on both runtimes | Draft |
| [NFR-02](./nfrs/NFR-02-chunk-coverage.md) | Coverage | Split-runtime unreviewed/timed-out chunk rate ≤ incumbent baseline | Draft |
| [NFR-03](./nfrs/NFR-03-credential-isolation.md) | Credential isolation | Exactly one provider key per attempt | Draft |
| [NFR-04](./nfrs/NFR-04-selector-failure.md) | Determinism | Unknown selector fails before any model call | Draft |
