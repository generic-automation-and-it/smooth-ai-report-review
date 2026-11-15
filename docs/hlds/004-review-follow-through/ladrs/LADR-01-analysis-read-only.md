# LADR-01: Analysis Is Read-Only; Execution Needs an Explicit Opt-In

**Status:** Accepted

## Context

- An AI review frequently contains imperative wording such as "fix this" or "change that".
- Treating that wording as authorization lets a read request mutate a repository.
- Fix and skip decisions can be wrong, and execution has no undo beyond git history.
- A partially executed ambiguous decision is worse than a stopped analysis.

## Decision

**Default** every invocation to read-only analysis. Files, commits, PR descriptions, review threads
and comments are untouched unless the user supplies per-item decisions or the explicit all-item
opt-in. Conflicting mode combinations are rejected before any edit.

Execution requires a resolvable PR and review so results can be routed. If an item cannot be given
a defensible decision or a required fix has no safe concrete action, stop before editing and report
the unresolved analysis rather than executing a subset.

## Consequences

- Reading a review can never surprise the author with a changed branch.
- The user retains control over every applied decision.
- `--fix` remains a deliberate, all-items opt-in rather than a convenience flag.
- Some runs end with analysis only, which is the intended safe outcome.

## Related

- `ai-review` runtime contract in [SKILL.md](../../../../.agents/skills/ai-review/SKILL.md).
