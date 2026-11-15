# LADR-01: Structured Findings Are a Second Transport, Never a Replacement

**Status:** Accepted

## Context

- Prose findings are readable but hard to deduplicate and count mechanically.
- A JSON sidecar enables deterministic merge, but a model can truncate it.
- The sidecar is emitted after the prose, so it is the first casualty of a cut-off answer.
- Downstream consumers already parse the posted body and must keep working.

## Decision

**Add** a structured findings sidecar alongside the markdown and keep the markdown as the posted
truth. The extractor removes the sentinel range inclusive, anchored on the last complete pair, and
never writes a chunk-failure flag for a partial or malformed sidecar.

The sidecar must stay small because it is emitted last. When coverage is partial, the merged summary
still renders and names every chunk that contributed nothing.

## Consequences

- Mechanical merge becomes possible without making prose optional.
- A truncated sidecar degrades coverage visibly instead of failing a chunk.
- Coverage must be counted from merged content, never from files present on disk.
- Two transports must stay consistent, which review and tests enforce.

## Related

- Canonical **LADR-055**, **LADR-064**, **LADR-079** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
