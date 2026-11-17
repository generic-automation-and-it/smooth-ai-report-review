# LADR-04: Configuration and Credentials Come Only from Gate-Owned Sources

**Status:** Draft

## Context

- One backend merges project-level configuration above the managed configuration and loads it from
  the reviewed checkout, so the gate already moves project config aside.
- The second backend trust-gates project configuration and project skills; a headless default skips
  them, and granting trust would also load project-provided executable extensions.
- Provider credentials are injected as environment secrets and must never be written to a file.

## Decision

**Both backends are configured from a gate-owned location that exists outside the reviewed
checkout**, and credentials reach the model process only through an environment allow-list
restricted to the selected provider's key. Automatically discovered project configuration from the
reviewed repository is neither merged, executed nor trusted; a configuration file the gate itself
selects through its documented override input — a repo-relative override such as canonical
LADR-047's — is gate-selected and allowed.

For a backend whose configuration is a directory rather than a single file, the gate assembles that
directory from its own assets; for one with a single-file override, the managed file wins.
Gate-owned configuration must not grant project trust to the reviewed checkout: project configuration
and project extensions stay unloaded.

## Consequences

- A hostile pull request cannot change policy or inject executable configuration.
- One credential discipline applies to both runtimes.
- The gate must own a second configuration layout, increasing asset surface.
- The environment allow-list must be maintained alongside the provider selector.

## Open

- Whether the second backend's project trust should be explicitly declined on every invocation or
  left to its headless default is an implementation choice, provided the outcome above holds.
- Applying the single-credential allow-list to the OpenCode path is a separate hardening decision;
  this delivery applies it to the second backend, so the OpenCode path's behaviour stays unchanged.

## Related

- **LADR-01** — the selector this configuration serves.
- **LADR-06** — how provider identity is expressed in that configuration.
