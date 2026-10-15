# Project rules — `.github/instructions`

## 🎯 TL;DR

The custom loader automatically discovers only
`.github/instructions/**/*.instructions.scoped.md` (root and nested files).
`applyTo:` in frontmatter scopes each candidate per chunk (LADR-104/105).
`MANDATORY_CONTEXT_FILES` defaults to `none`; explicitly listed paths still
opt in regardless of filename/scope. No automatic `*_AGENTS.md` walk or blanket
`.agents/rules/*.md` scan remains. Config `instructions` declarations and native
OpenCode `AGENTS.md` discovery are unchanged.

## Rules in this directory

| File | Kind | Scope | Read it when |
| --- | --- | --- | --- |
| [`skills/skill-secret-handling.instructions.scoped.md`](skills/skill-secret-handling.instructions.scoped.md) | injected | `applyTo: '.agents/skills/**'` | Adding or editing a **skill**, any script that consumes a secret, or any workflow `env:`/`secrets:` block. |

## Naming a new rule

1. Put it under `.github/instructions/` (nested directories are supported).
2. Name it `<subject>.instructions.scoped.md`.
3. Declare `applyTo:` (or `alwaysApply: true`). A scoped rule with no frontmatter
   is **kept** for every chunk — the scope filter fails open on purpose, because
   a wrongly dropped rule changes the review silently while an extra one costs
   a few tokens.

## Changelog

| Date | Change | Ref |
|:-----|:-------|:----|
| 2026-10-15 | Custom loading is scoped-instructions-only; mandatory defaults to `none`. Config globs and native AGENTS.md loading unchanged. | LADR-105 |
| 2026-10-15 | Created as the rule index for this directory. Injection switched from `*.instructions.md` to the `*instructions.scoped.md` opt-in; the sibling rule was renamed to match. | LADR-104 |
