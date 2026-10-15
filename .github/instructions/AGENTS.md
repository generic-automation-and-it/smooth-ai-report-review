# Project rules — `.github/instructions`

## 🎯 TL;DR

A rule file is injected into AI chunk reviews **only when it is named
`*instructions.scoped.md`** (LADR-104); a plain `*.instructions.md` file is
documentation. `applyTo:` in its frontmatter then scopes it per chunk. The full
convention is below; LADR-104 is the decision record.

## System Context

This directory holds the repository's rule files. There are two kinds, and the
**file name is the opt-in** (LADR-104):

- **`*instructions.scoped.md`** — declares its scope in YAML frontmatter
  (`applyTo:` / `globs:` / `paths:`, or `alwaysApply: true`). The gate's
  `find-context-files.sh` discovers these and `filter-context-scope.sh` applies
  the declared scope per chunk, so the rule is injected as active instructions
  only into reviews whose files match. This is the only kind that reaches a
  chunk review automatically.
- **`*.instructions.md`** — documentation. Read by humans and by any agent that
  opens this directory; **not** injected into chunk reviews.

Neither kind is loaded by OpenCode's `instructions` config array: v2 accepts the
key but resolves none of its entries (verified on v2.0.29 with a mock provider
capturing the raw request, see LADR-087). That is why the gate enumerates and
injects them itself.

## Rules in this directory

| File | Kind | Scope | Read it when |
| --- | --- | --- | --- |
| [`skills/skill-secret-handling.instructions.scoped.md`](skills/skill-secret-handling.instructions.scoped.md) | injected | `applyTo: '.agents/skills/**'` | Adding or editing a **skill**, any script that consumes a secret, or any workflow `env:`/`secrets:` block. |

## Naming a new rule

1. Put it under `.github/instructions/` (or `.agents/rules/`, which is
   enumerated without the suffix convention — every `.md` there is injected).
2. Name it `<subject>.instructions.scoped.md`.
3. Declare `applyTo:` (or `alwaysApply: true`). A scoped rule with no frontmatter
   is **kept** for every chunk — the scope filter fails open on purpose, because
   a wrongly dropped rule changes the review silently while an extra one costs
   a few tokens.

## Related

- Root [`AGENTS.md`](../../AGENTS.md) — the gate's own architecture contract
  (LADRs, key behaviors, non-negotiables). Loaded natively by OpenCode v2.
- [`.agents/opencode.json`](../../.agents/opencode.json) — declares the
  instruction globs for tooling that honours them (and stays inert, by design,
  until OpenCode v2 wires the array to the prompt).

## Changelog

| Date | Change | Ref |
|:-----|:-------|:----|
| 2026-10-15 | Created as the rule index for this directory. Injection switched from `*.instructions.md` to the `*instructions.scoped.md` opt-in; the sibling rule was renamed to match. | LADR-104 |
