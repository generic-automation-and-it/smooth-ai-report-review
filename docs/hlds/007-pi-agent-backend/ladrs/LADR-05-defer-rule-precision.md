# LADR-05: Defer Per-File Rule Precision and Formatters

**Status:** Draft

## Context

- Rules are currently selected per chunk, from the chunk's changed files. That over-includes rules
  for areas in the chunk and under-includes rules for files the model reads only for context.
- Formatters have no role in a read-only reviewer. The fixer has no shell, so a formatter would need
  a new execution surface.
- No named requirement exists yet for either capability.

## Decision

**Do not build per-file rule injection or a formatter step now.** Each is deferred as one line with a
trigger, rather than designed speculatively.

- Per-file rule injection is revisited only if instrumented runs show findings missed because a rule
  for a read-only path was never delivered.
- A formatter step is revisited only if the fixer gains an approved, allow-listed formatter execution
  surface; the reviewer stays read-only.

## Consequences

- The first delivery stays small and testable.
- Chunk-level rule precision remains a known, documented limitation.
- Revisiting later costs a new decision, not a rewrite of this contract.

## Related

- **LADR-02** — the instruction artifact this defers extending.
