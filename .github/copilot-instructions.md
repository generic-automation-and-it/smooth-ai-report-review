# GitHub Copilot Instructions

These are the authoritative custom instructions for GitHub Copilot in this repository.

## AI Coder Instructions

- **Load and follow [`AGENTS.md`](../AGENTS.md)** as the single source of project context, conventions, and coding rules. Treat it as your primary instruction set.
- **Ignore `.claude/**`** — Claude Code-specific configuration, hooks, and skills.
- **Ignore `.codex/**`** — OpenAI Codex-specific configuration.
- **Skill secret handling** — canonical rule: `.github/instructions/skills/skill-secret-handling.instructions.scoped.md` (read it before editing a skill, a secret-consuming script, or a workflow `env:`/`secrets:` block; the checklist and the open-gap list live there). A skill that needs a secret **must** delegate to a script that reads it from the runtime environment; the secret **value** must never appear in model-visible or committed text. This rule is restated here because the canonical file is named `*.instructions.scoped.md` — the gate's injection opt-in (LADR-104) — and Copilot auto-loads only `*.instructions.md`. Prose cannot import it, so the substance lives here and the file stays the single source of the detail.

When project context, conventions, or coding rules in `AGENTS.md` conflict with anything in the ignored files above, **`AGENTS.md` always wins.**
