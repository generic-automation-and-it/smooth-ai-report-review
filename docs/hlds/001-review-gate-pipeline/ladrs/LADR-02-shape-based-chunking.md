# LADR-02: Chunk by Shape with Hard Diff-Payload Budgets

**Status:** Accepted

## Context

- One model call over a large diff degrades recall and risks context exhaustion.
- File count alone is a poor proxy for review difficulty; cohesion matters.
- Per-file and per-chunk prompt size is the real constraint on reliable output.
- A PR too large to review reliably should be refused, not sampled arbitrarily.

## Decision

**Start with** shape rules: one chunk at or below ten files; semantic grouping at fifteen or more
when that pass is available; directory-depth splitting between them. Per-file diff payloads and each
chunk's combined diff payload carry hard byte caps. Instructions, context and truncation markers add
overhead beyond those caps; the complete prompt has a size warning, not a hard cap. A file whose diff
is truncated is marked so the reviewer cannot claim Critical or High from it without reading the
current file.

Changed-file count above the configured limit is a separate gate: the PR receives a
request-changes review asking for a split rather than a partial review.

## Consequences

- Deterministic shape cases produce reproducible boundaries; semantic grouping can vary between runs.
- Cohesive changes stay together, including moves between files.
- Semantic grouping adds one orchestrator call and can vary in grouping quality.
- Large PRs are blocked rather than slowly reviewed, which shifts work to the author.

## Related

- Canonical **LADR-001**, **LADR-010**, **LADR-011**, **LADR-032**, **LADR-035** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
