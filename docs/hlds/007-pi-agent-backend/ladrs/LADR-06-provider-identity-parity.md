# LADR-06: Preserve Provider and Model Identity Across Backends

**Status:** Draft

## Context

- The gate's model chain and presets use provider-qualified model identifiers, and non-default
  providers must supply provider-relative identifiers for every tier.
- Each backend declares its own providers and models, with different native identifier formats.
- Credentials are referenced by environment variable name, never stored in configuration.

## Decision

**Extend** the existing one-selector/provider-surface decision
([002 LADR-05](../../002-context-and-toolchain/ladrs/LADR-05-one-selector-provider-surface.md)) to both
backends: map every provider selector to the same provider identity and model identifier, declared in
each backend's own configuration, with credentials resolved from environment variables by name. The
model-chain and preset vocabulary must not change when the backend changes.

Identifiers that contain a path separator must resolve to the same provider and model on both
runtimes; a mismatch is a preflight failure, not a fallback.

## Consequences

- Model tiers, presets and fallback chains are reused unchanged.
- Adding a provider means updating both configurations in one change.
- Model metadata (reasoning support, input limits) may need separate declaration per backend.
- Ambiguous identifier parsing becomes a testable preflight concern.

## Related

- **002 LADR-05** — the selector/provider-surface decision this extends.
- **LADR-01** — the backend that consumes this mapping.
- **LADR-04** — the credential allow-list.
