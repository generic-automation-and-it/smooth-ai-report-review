# GitHub Copilot Instructions

These are the authoritative custom instructions for GitHub Copilot in this repository.

## AI Coder Instructions

- **Load and follow [`AGENTS.md`](../AGENTS.md)** as the single source of project context, conventions, and coding rules. Treat it as your primary instruction set.
- **Ignore `.claude/**`** — Claude Code-specific configuration, hooks, and skills.
- **Ignore `.codex/**`** — OpenAI Codex-specific configuration.
- **Skill secret handling**: `.github/instructions/skills/skill-secret-handling.instructions.scoped.md`. Copilot auto-loads `*.instructions.md`, so the `.scoped.` suffix (the gate's injection opt-in, LADR-104) takes this file out of Copilot's automatic set — it is named here instead.

When project context, conventions, or coding rules in `AGENTS.md` conflict with anything in the ignored files above, **`AGENTS.md` always wins.**
