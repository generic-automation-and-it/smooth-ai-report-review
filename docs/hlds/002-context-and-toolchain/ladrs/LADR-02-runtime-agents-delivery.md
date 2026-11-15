# LADR-02: Rules Reach the Model as a Generated Runtime AGENTS.md

**Status:** Accepted

## Context

- The runtime's config `instructions` array does not resolve on the supported v2 runtime.
- A list of paths the model must read spends exploration turns before review work starts.
- Exact `AGENTS.md` files are discovered natively by directory scope and would double-inject.
- Scope-filter frontmatter is metadata, not review instruction.

## Decision

**Deliver** the applicable scoped set as content: concatenate it into a generated `AGENTS.md` in the
chunk's working directory and run the review from there. The runtime then loads the file through
its normal directory-scope discovery with no read round-trip.

Exact `AGENTS.md` basenames are never concatenated, and each file's leading YAML frontmatter is
stripped before concatenation. The aggregation pass receives the merged set the same way. Because
the chunk working directory is no longer the repository root, file-access guidance is absolute-only.

## Consequences

- Rules arrive as active instructions rather than as a reading assignment.
- Context cost is paid once, at prompt build time.
- A path-based context contract cannot be reintroduced without losing the runtime's native loading.
- Generated files are scratch state, never a committed source of truth.

## Related

- Canonical **LADR-087**, **LADR-090** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
