# Project rules — `.github/instructions`

## 🎯 TL;DR

A rule file is injected into AI chunk reviews **only when it is named
`*instructions.scoped.md`** (LADR-104); a plain `*.instructions.md` file is
documentation. `applyTo:` in its frontmatter then scopes it per chunk. The full
convention is below; LADR-104 is the decision record.

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

## Changelog

| Date | Change | Ref |
|:-----|:-------|:----|
| 2026-10-15 | Created as the rule index for this directory. Injection switched from `*.instructions.md` to the `*instructions.scoped.md` opt-in; the sibling rule was renamed to match. | LADR-104 |
