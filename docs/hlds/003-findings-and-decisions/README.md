# Findings Integrity and Decision Scoring — High-Level Design

| | |
|---|---|
| **Status** | Accepted (as built, 2026-11-15) |
| **Owner** | `ai-review-report` (consumed by `ai-review` and `ai-analyse`) |
| **Tracker** | [Repository issues](https://github.com/generic-automation-and-it/smooth-ai-report-review/issues) |
| **Evidence** | [ai-review-report SKILL.md](../../../.agents/skills/ai-review-report/SKILL.md) + [findings-schema.json](../../../.agents/skills/ai-review-report/assets/findings-schema.json) at `0a8a7a2`; canonical LADRs in each LADR's Related section |
| **Last updated** | 2026-11-15 |

> Design record for the delivered findings pipeline. It states **intent + spec**; execution
> sequencing lives in the issue tracker.

## Intent

A review is only useful if every finding is reproducible, deduplicated and honestly scored. Model
prose alone yields duplicates, unverifiable claims and unstable numbering that downstream parsers
and humans cannot act on. This design specifies the evidence gate, the deterministic merge, the
optional decision judge, and the presentation rules that keep every consumer stable.

## Key Goals

### 1. Evidence before assertion

Every structured finding anchored at 75 or 100 quotes the motivating line at its location, and
every structured finding carries a discrete confidence anchor chosen by behavior, not by feel. A finding that claims a
project-standard violation names the rule it rests on and cites its source. Missing evidence lowers
confidence, never severity.

**Acceptance criteria / DoD**

- A structured 75 or 100 finding without a quoted line is demoted to 50 and counted.
- Non-critical findings below 75 are suppressed; Critical findings are retained.
- A standards claim without a cited rule is withdrawn to its own code evidence.
- A `[SPECULATIVE]` finding never carries an anchor above 50.

### 2. Deterministic merge and stable identity

Chunk findings merge across the PR by file, line and title, using conservative field resolution.
The merged set is sorted and numbered deterministically, and each item class keeps its own sequence.
Partial coverage is rendered loudly with the missing chunks named.

**Acceptance criteria / DoD**

- The same chunk documents produce the same merged document and numbering.
- Coverage is counted from merged chunks, never from sidecar files on disk.
- Findings, residual risks, testing gaps and pre-existing items never share a sequence.
- No posted identifier renders as a GitHub autolink.

### 3. Judge, never author

An optional structured decision model scores the merged findings and may recommend fix or skip. It
never rewrites severity, confidence or verification, and its recommendations can only withhold,
never add or upgrade. Escalation is one-directional; the only softening path is fenced by full
coverage.

**Acceptance criteria / DoD**

- With decisions disabled, output is byte-identical to a run without the feature.
- A failed decision request leaves only that finding unscored.
- `filter` mode degrades to annotation outside the coverage fence.
- A decision answer never becomes a human decision label.

### 4. Presentation stays parseable

Finding permalinks are appended last and read by no parser. Suggested-fix references are repointed
from the block anchor, not the prose. The structured sidecar is stripped inclusive of its sentinel
range, and an unterminated block never becomes a failed chunk.

**Acceptance criteria / DoD**

- Every consumer parser produces identical results with links enabled or disabled.
- A fix whose finding was dropped is reworded without a number and explained.
- A partial or malformed sidecar never writes a chunk-failure flag.

## Core Separation of Concerns

> A finding is a claim with evidence; a decision is a judgement kept separate from that claim.

Chunk reviewers produce claims. Merge makes claims comparable and stable. The decision model judges
them but cannot mutate them. Rendering presents the result without becoming a new source of truth
for any parser.

## Guiding Principle — Evidence earns severity; judgement never rewrites evidence

- A model opinion is not evidence, and a heuristic is not a verdict.
- Conservative merging protects the author from a stricter duplicate.
- Every consumer reads the same ordered document, not a private copy.

## Related HLDs

- [001 PR Review Gate Pipeline](../001-review-gate-pipeline/README.md) — where findings are produced and posted.
- [002 Context Delivery and Toolchain](../002-context-and-toolchain/README.md) — what the chunk reviewer was given.
- [004 Review Follow-Through](../004-review-follow-through/README.md) — how humans act on these findings.

---

## Diagrams

- [System Context (C1) + finding lifecycle](./diagrams/c4-context.md)

## Architecture Decisions (LADRs)

| LADR | Decision | Status |
|------|----------|--------|
| [LADR-01](./ladrs/LADR-01-structured-findings-second-transport.md) | Structured findings are a second transport, never a replacement | Accepted |
| [LADR-02](./ladrs/LADR-02-evidence-demotes-confidence.md) | Missing quoted evidence demotes confidence, never severity | Accepted |
| [LADR-03](./ladrs/LADR-03-deterministic-merge-numbering.md) | Merge and numbering are deterministic; coverage is loud | Accepted |
| [LADR-04](./ladrs/LADR-04-decision-model-judges-only.md) | The decision model judges, never authors, and softens only inside a fence | Accepted |
| [LADR-05](./ladrs/LADR-05-presentation-only-links.md) | Permalinks and cross-reference repair are presentation-only | Accepted |

**Delegated to the findings pipeline:** recommendation sync (canonical LADR-085), holistic-section
removal (LADR-100), consumer routing completeness (LADR-101), quote verification (LADR-119),
author-notes envelope (LADR-118), and eval intents (LADR-111).

## Non-Functional Requirements

| NFR | Attribute | Target (summary) | Status |
|-----|-----------|------------------|--------|
| [NFR-01](./nfrs/NFR-01-merge-determinism.md) | Determinism | Identical inputs produce identical output and numbering | Accepted |
| [NFR-02](./nfrs/NFR-02-decision-failure-isolation.md) | Fault isolation | Disabled runs are byte-identical; a failure affects at most the failed finding | Accepted |
| [NFR-03](./nfrs/NFR-03-identifier-safety.md) | Render safety | Zero auto-linking `#`+digit tokens in posted bodies | Accepted |
