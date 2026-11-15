# LADR-01: Scope-Filtered Context, Mandatory List Default None

**Status:** Accepted

## Context

- A repo-wide rule dump dilutes attention and spends context budget on irrelevant guidance.
- A wrongly dropped rule changes review output silently; an extra rule costs a few tokens.
- Consumers differ: some have no mandatory context files, others need a small explicit set.
- Scope metadata can be absent, unparseable or written in globs the filter cannot translate.

## Decision

**Adopt** a scoped-only custom discovery layer over `.github/instructions/**/*.instructions.scoped.md`,
with native `AGENTS.md` discovery left to the runtime. A candidate is dropped only when its declared
`applyTo`/`globs`/`paths` scope provably matches no file in the chunk.

Every uncertain case is retained: no frontmatter, unparseable frontmatter, no scope key,
`alwaysApply: true`, an untranslatable glob, and every explicitly mandatory path. Mandatory context
defaults to none and is an opt-in override matched by existence, not filename.

## Consequences

- Irrelevant rules stop consuming chunk context.
- A filter bug fails toward an extra rule, never a missing one.
- Consumers with no context files need no configuration.
- The legacy ancestor `*AGENTS.md` walk and blanket rule scan are gone; repos relying on them must
  opt in explicitly.

## Related

- Canonical **LADR-089**, **LADR-104**, **LADR-105** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
