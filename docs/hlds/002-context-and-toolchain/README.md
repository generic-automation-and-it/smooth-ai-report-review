# Context Delivery and Toolchain — High-Level Design

| | |
|---|---|
| **Status** | Accepted |
| **Owner** | `ai-review-report` |
| **Tracker** | [Repository issues](https://github.com/generic-automation-and-it/smooth-ai-report-review/issues) |
| **Evidence** | [ai-review-report SKILL.md](../../../.agents/skills/ai-review-report/SKILL.md) + [opencode.json](../../../.agents/skills/ai-review-report/assets/opencode.json) at `0a8a7a2`; canonical LADRs in each LADR's Related section |
| **Last updated** | 2026-11-15 |

> Design record for the delivered context layer and runtime pinning. It states **intent + spec**;
> implementation sequencing lives in the issue tracker.

## Intent

A chunk reviewer is only as correct as the project context around it and the runtime that executes
it. Too little context produces false positives; too much dilutes attention and inflates cost. This
design specifies how applicable context reaches each chunk exactly once, how optional enrichment
stays advisory, and how the runtime is pinned and verified before any model call.

## Key Goals

### 1. Deliver only applicable context

Native `AGENTS.md` discovery stays in force. The custom layer discovers scoped instruction files and
drops a candidate only when its declared scope matches no file in the chunk. Mandatory context is
opt-in and defaults to none.

**Acceptance criteria / DoD**

- A scoped rule is dropped only on a proven scope mismatch.
- Missing, unparseable or unscoped frontmatter, `alwaysApply`, untranslatable globs and mandatory
  paths are all retained.
- Brace and character-class globs are translated, never treated as literals.

### 2. Use one context channel, without double injection

The applicable scoped set is materialized as a generated per-chunk `AGENTS.md` containing rule
content. The chunk runs from that directory so the runtime loads the file as active instructions,
not as paths the model must read. Exact `AGENTS.md` basenames are never concatenated, and leading
YAML frontmatter is stripped.

**Acceptance criteria / DoD**

- Each chunk sees exactly one copy of each applicable rule.
- No path-list read round-trip is required before review.
- The aggregation pass receives the merged set the same way.

### 3. Keep enrichment advisory and fail-open

Code-graph risk and inferred coverage hints, precomputed blame provenance, and version notices
enrich a chunk when available. Each is capped, each is optional, and none can block a review or
become a verdict on its own.

**Acceptance criteria / DoD**

- A failed graph build yields a review without graph blocks.
- No graph signal alone justifies Critical or High, or satisfies quote-the-line evidence.
- Version notices are bounded and never fail the run.

### 4. Pin and verify the toolchain

One installer source per tool, OpenCode v2 only, config binding confirmed before any model call,
requested model IDs registered in the resolved config, and the RTK plugin initialized only above its
compatibility floor.

**Acceptance criteria / DoD**

- A v1 binary is rejected even if cached or already on PATH.
- A foreign config binding is fatal regardless of liveness. An unreadable binding is fatal unless
  the liveness probe also fails; that combined diagnostic failure is advisory in CI.
- A missing model key is added without altering existing metadata.
- An RTK below the floor keeps its binary, warns and skips initialization.

### 5. Select the provider and model surface

Provider selection maps one selector to one provider ID, credential set and SDK surface: eight
selectors across native APIs, compatible gateways and three OpenCode Go surfaces. The default is
OpenAI; non-OpenAI runs must supply provider-relative model IDs for every tier.

**Acceptance criteria / DoD**

- A selector resolves to exactly one provider ID and credential set.
- A model family or surface mismatch aborts before any review call.
- Dispatch presets override the Variables and still require that provider's key.
- An unknown selector fails instead of falling back to a default.

## Core Separation of Concerns

> Context informs, the toolchain executes, and neither decides the verdict.

Context selection is a filter over candidate files, not a judgment about their value. The toolchain
prepares and proves the runtime; it does not reinterpret review output. Keeping both away from the
verdict preserves one source of truth for review decisions.

## Guiding Principle — Fail open on context, fail closed on the toolchain

- An extra rule costs tokens; a wrongly dropped rule changes the review silently.
- A wrong runtime silently invalidates every model call, so its checks are fatal.
- Enrichment may disappear; the review may not.

## Related HLDs

- [HLD index](../README.md) — ownership map, numbering convention and source precedence.
- [001 PR Review Gate Pipeline](../001-review-gate-pipeline/README.md) — the consumer of this layer.
- [003 Findings Integrity and Decision Scoring](../003-findings-and-decisions/README.md) — what the enriched chunk produces.

---

## Diagrams

- [System Context (C1) + context selection flow](./diagrams/c4-context.md)

## Architecture Decisions (LADRs)

| LADR | Decision | Status |
|------|----------|--------|
| [LADR-01](./ladrs/LADR-01-scoped-context-fails-open.md) | Scope-filtered context, mandatory list default none | Accepted |
| [LADR-02](./ladrs/LADR-02-runtime-agents-delivery.md) | Rules reach the model as a generated runtime `AGENTS.md` | Accepted |
| [LADR-03](./ladrs/LADR-03-enrichment-is-advisory.md) | Graph and provenance signals are hints, never verdicts | Accepted |
| [LADR-04](./ladrs/LADR-04-single-toolchain-source.md) | One install source per tool with a hard v2 floor | Accepted |
| [LADR-05](./ladrs/LADR-05-one-selector-provider-surface.md) | One selector resolves the provider and model surface | Accepted |

**Delegated to the runtime contract:** version notices (canonical LADR-053), blame provenance
(LADR-061), config quarantine (LADR-103), and legacy rule-path removal (LADR-105).

## Non-Functional Requirements

| NFR | Attribute | Target (summary) | Status |
|-----|-----------|------------------|--------|
| [NFR-01](./nfrs/NFR-01-context-selection-completeness.md) | Context completeness | Zero false drops; every uncertain case retained | Accepted |
| [NFR-02](./nfrs/NFR-02-enrichment-non-blocking.md) | Availability | Enrichment failure never blocks or softens a review | Accepted |
| [NFR-03](./nfrs/NFR-03-toolchain-determinism.md) | Runtime determinism | Same pin yields v2 with a verified binding | Accepted |
