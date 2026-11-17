# LADR-02: Build the Instruction Artifact Once and Deliver It Per Backend

**Status:** Draft

## Context

- Scoped rule selection is already deterministic and runs before any model call: candidates are
  filtered against the chunk's changed files, and uncertain cases are retained.
- The selected rules are materialized into a generated per-chunk instruction artifact.
- OpenCode loads that artifact by working directory. The second backend loads exact `AGENTS.md` from
  a working directory and its ancestors, but its ancestor walk has no documented stop condition and
  it also accepts injected system-prompt paths.
- Exact `AGENTS.md` files are already loaded natively by both runtimes and must not be duplicated.

## Decision

**Keep the generated per-chunk instruction artifact as the single source of instruction content**,
refining [002 LADR-02](../../002-context-and-toolchain/ladrs/LADR-02-runtime-agents-delivery.md) for a
second runtime, and let each backend deliver that same artifact through whatever channel it supports,
before the first model call. Selection logic, frontmatter stripping, source labelling and
exact-`AGENTS.md` exclusion stay backend-neutral; only delivery is backend-specific.

Delivery must not depend on a path-list read round-trip, and must not rely on an undocumented
directory walk for correctness.

## Consequences

- Both backends receive identical rule content for the same chunk.
- Scoped selection stays testable once, independent of the runtime.
- A backend may need an explicit injection channel rather than directory discovery.
- The artifact remains the audit surface for "which rules reached this chunk".

## Open

- Per-file rule precision inside a chunk is deferred (LADR-05).
- Widening the consumed rule-source set — for example consumer rule directories — is a separate
  decision, triggered by a named consumer requirement.

## Related

- **002 LADR-02** — the runtime-`AGENTS.md` delivery decision this refines.
- **LADR-05** — deferred dynamic rule injection.
