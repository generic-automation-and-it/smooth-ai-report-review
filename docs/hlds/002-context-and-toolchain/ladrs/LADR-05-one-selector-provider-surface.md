# LADR-05: One Selector Resolves the Provider and Model Surface

**Status:** Accepted

## Context

- Eight selectors span native APIs, compatible gateways and three OpenCode Go SDK surfaces.
- Model IDs are provider-relative; a family or surface mismatch fails after chunk work starts.
- Dispatch presets must not require a second credential path.

## Decision

**Resolve** one selector to exactly one provider ID, credential set and SDK surface before any
review call. Model family and surface are validated at resolution; a mismatch aborts. Presets
override the Variables but still require the selected provider's key. An unknown selector fails
rather than falling back.

## Consequences

- The call site stays provider-agnostic.
- A bad selector fails before spending a chunk budget.
- Adding a provider is a config and resolver change, not a new review path.
- Presets remain a thin overlay on the same resolver.

## Related

- Canonical **LADR-026**, **LADR-027**, **LADR-039**, **LADR-040**, **LADR-086**, **LADR-087** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
