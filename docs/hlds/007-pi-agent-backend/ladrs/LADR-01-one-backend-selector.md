# LADR-01: One Selector Chooses the Backend; OpenCode Stays the Default

**Status:** Draft

## Context

- The gate and the fixer each invoke one coding-agent CLI with a prompt file and read its answer
  from stdout.
- A second runtime is wanted for provider coverage, cost and availability; OpenCode already works
  for every current consumer.
- Two independent pipelines would duplicate review behaviour, its tests and its failure handling.

## Decision

**Add one environment selector** in the gate's existing variable namespace that resolves to exactly
one backend, defaulting to OpenCode. Both backends must honour the same prompt-in/answer-out
contract, so the selector changes only the runtime — every post-processing step, failure channel and
artifact stays shared.

The selector is a runtime choice, not a behaviour switch: no review rule, severity rule or fence may
branch on it. An unknown selector fails before any model call rather than falling back.

## Consequences

- Consumers gain a second runtime without a second review implementation.
- The default path stays byte-identical for existing consumers.
- Two install/version-pin paths, each with a single source of truth, and two runtime test matrices
  must be maintained.
- A backend-specific failure must be translated into the gate's existing failure taxonomy.
- Shared-layer changes — context selection, gate-computed enrichment, merging and presentation —
  land once and apply to both backends; only the runtime changes with the selector.

## Open

- A third backend is designed only when a named consumer requirement appears.

## Related

- **LADR-02** — what every backend receives.
- **LADR-04** — where each backend's configuration comes from.
