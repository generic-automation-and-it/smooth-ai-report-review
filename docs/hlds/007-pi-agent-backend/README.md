# Pi Agent Backend — High-Level Design

| | |
|---|---|
| **Status** | Draft |
| **Owner** | `ai-review-report` + `ai-analyse` |
| **Tracker** | [Repository issues](https://github.com/generic-automation-and-it/smooth-ai-report-review/issues) |
| **Evidence** | Not yet delivered — this record specifies the intent and the contract |
| **Last updated** | 2026-11-17 |

> Discovery HLD. This document delivers **intent + spec** — what we are building and why, the
> decisions behind it, and the quality bar it must meet. It does **not** contain an implementation
> plan; execution (phasing, sub-issues, sequencing) is tracked in the issue tracker.

## Intent

The review gate and the autonomous fixer currently execute one coding-agent CLI. Consumers want a
second runtime so provider coverage, cost and availability are not tied to a single vendor's CLI,
without forking review behaviour or weakening the fixer's safety fences. This design specifies the
backend contract that lets a second CLI run the same review and fix workloads, and defines what
"equivalent" means for instructions, tool lockdown, configuration, credentials and output.

## Key Goals

### 1. Add a backend without forking behaviour

One environment selector chooses the backend; OpenCode remains the default and is unchanged. Both
backends consume the same prompt file and produce the same answer contract, and every step after the
model call is backend-neutral.

**Acceptance criteria / DoD**

- The selector resolves to exactly one backend, and the OpenCode path is unchanged when it is
  selected.
- The selected runtime resolves from one pinned install source; a missing or mismatched runtime fails
  before any model call.
- The selector is declared in every packaging's environment contract in the same change.
- No review behaviour or post-processing step exists in a backend-specific variant.
- A backend failure maps to the same failure channel the gate already handles.

### 2. Deliver the same instructions before the first turn

Scoped rule selection stays deterministic and backend-neutral: the per-chunk instruction artifact is
built once, and each backend receives it through its own supported delivery channel before the first
model call. Exactly one copy of each applicable rule is delivered.

**Acceptance criteria / DoD**

- The injected instruction content is identical by content hash for both backends on the same chunk.
- The consumed rule-source set is unchanged; no new rule directory is discovered because of the
  backend.
- No path-list read round-trip is required, and exact `AGENTS.md` basenames are never duplicated.
- Missing, unparseable or unscoped frontmatter, `alwaysApply` and untranslatable globs remain
  retained on both backends.

### 3. Enforce an equivalent tool lockdown

Each role keeps its tool surface regardless of backend: the reviewer is read-only with no shell and
no network, and the fixer is edit-only with a deny matrix over tooling, context, temp, VCS and
credential paths. Lockdown is proven by behaviour, not by sharing one configuration format.

**Acceptance criteria / DoD**

- A denied tool call is blocked on both backends, not merely absent from the prompt.
- No review invocation can edit, write, or reach a shell or network tool; no fixer invocation can
  reach a shell or network tool.
- An unresolvable path in the fixer fails closed.
- Built-in, extension and MCP tools are all covered by the same role contract.
- Workflow-level permissions, persisted credentials and hook-proof git remain workflow-owned and are
  unaffected by the backend.

### 4. Own configuration and credentials outside the reviewed repository

Both backends are configured from a gate-owned location, never from the reviewed checkout. A
reviewed repository's own agent configuration is ignored, and the model process receives only the
credential its selected provider needs.

**Acceptance criteria / DoD**

- Project-level configuration in the reviewed checkout has no effect on either backend.
- The model process environment contains only the selected provider's key.
- No credential value appears in any file the model can read.
- A provider selector resolves to the same provider and model identity on both backends.

### 5. Preserve self-fix safety

The fixer's guarantees are runtime-independent: the oracle fences, the failing-test rule, the
regression-relative test gate and workflow-owned git side effects behave identically whichever
backend applies the edits.

**Acceptance criteria / DoD**

- Zero test, framework or evaluation edits are committed while test self-fix is off, on both
  backends.
- A green-to-red regression, timeout or unavailable baseline blocks the push on both backends.
- The FIX/SKIP summary contract and completeness pass are unchanged.

## Core Separation of Concerns

> The backend executes the model; the gate owns context, policy and side effects.

A backend is a model-execution runtime, not a policy owner. Context selection, tool lockdown,
credential injection, failure classification and every irreversible action remain the gate's, so
adding a runtime can never silently change what a review means or what the fixer may publish.

## Guiding Principle — Swap the runtime, never the contract

- One prompt-in/answer-out contract, one set of post-processing steps, one failure taxonomy.
- Two native lockdown implementations are acceptable; two behavioural definitions are not.
- We will not trust, execute or merge configuration from the repository under review.

---

## Diagrams

- [System Context (C1)](./diagrams/c4-context.md)

## Architecture Decisions (LADRs)

| LADR | Decision | Status |
|------|----------|--------|
| [LADR-01](./ladrs/LADR-01-one-backend-selector.md) | One selector chooses the backend; OpenCode stays the default | Draft |
| [LADR-02](./ladrs/LADR-02-instructions-before-first-turn.md) | The per-chunk instruction artifact is built once and delivered per backend | Draft |
| [LADR-03](./ladrs/LADR-03-lockdown-by-behaviour.md) | Tool lockdown is a role contract proven by behaviour, not one config format | Draft |
| [LADR-04](./ladrs/LADR-04-gate-owned-configuration.md) | Configuration and credentials come only from gate-owned sources | Draft |
| [LADR-05](./ladrs/LADR-05-defer-rule-precision.md) | Per-file rule precision and formatters are deferred with triggers | Draft |
| [LADR-06](./ladrs/LADR-06-provider-identity-parity.md) | Provider and model identity are preserved across backends | Draft |

## Non-Functional Requirements

| NFR | Attribute | Target (summary) | Status |
|-----|-----------|------------------|--------|
| [NFR-01](./nfrs/NFR-01-review-output-parity.md) | Output parity | Same chunk yields a shape-valid review on both backends | Draft |
| [NFR-02](./nfrs/NFR-02-tool-surface-determinism.md) | Tool-surface determinism | No role reaches a tool outside its contract | Draft |
| [NFR-03](./nfrs/NFR-03-configuration-isolation.md) | Configuration isolation | Reviewed-repo config has zero effect; one credential in the child | Draft |
| [NFR-04](./nfrs/NFR-04-fixer-safety-parity.md) | Fixer safety | Zero protected edits committed; zero unsafe pushes | Draft |
