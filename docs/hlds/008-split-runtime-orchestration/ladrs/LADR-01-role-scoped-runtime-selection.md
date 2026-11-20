# LADR-01: Runtime selection is role-scoped, not per call

**Status:** Draft

## Context

- The gate runs one runtime for every model call today; the selector is whole-run.
- Chunk review and orchestration have different optima (volume vs synthesis).
- Selecting a runtime per call site would let behaviour drift between calls of the same role.

## Decision

**Adopt role-scoped selection.** A whole-run selector names the default runtime; one override per role
(`chunk`, `orchestration`) may name a different one. A blank override inherits the whole-run value, and
any unknown value fails before a model call. All call sites of a role share one resolved runtime, so a
role never executes on two runtimes in one run.

## Consequences

- Routing becomes an explicit gate responsibility with one resolver per role.
- Each role's parity and failure tests run against its resolved runtime.
- Defaults preserve today's behaviour; the split is opt-in.
- A hybrid run installs and initializes both runtimes.

## Open

- Whether the whole-run selector survives as the only public Variable, with role overrides internal to
  the packagings — resolved by the first implementation PR's env contract.

## Related

- **LADR-02**, **LADR-03** — constrain which runtime a role may select.
