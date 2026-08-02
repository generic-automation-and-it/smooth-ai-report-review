# Ralph Loop — Agent Notes

## 🎯 TL;DR

Ralph Loop implements the Ralph Wiggum technique for iterative, self-referential AI development loops. It works in two provider modes: Claude Code (stop hook intercepts exit and feeds the prompt back) and Codex/OpenAI (wrapper script `ralph-loop.sh` runs the model in a while-true loop with completion promise detection). The state file `.claude/ralph-loop.local.md` is shared across both modes for portability.

## Key Files

- `SKILL.md` — runtime contract and prompt best practices
- `scripts/setup-ralph-loop.sh` — creates state file for Claude Code mode
- `scripts/stop-hook.sh` — Claude Code stop hook that blocks exit and feeds prompt back
- `scripts/ralph-loop.sh` — Codex/OpenAI wrapper that runs the model in a loop
- `scripts/cancel-ralph.sh` — cancels an active loop by removing the state file
- `agents/openai.yaml` — OpenAI-compatible model config

## State File

`.claude/ralph-loop.local.md` — YAML frontmatter + prompt text. Shared between both modes.

## Provider Adaptation Notes

- Claude Code: stop hook is the native mechanism; no wrapper script needed
- Codex/OpenAI: no stop hook; `ralph-loop.sh` wraps the CLI in a while-true loop
- The state file format is identical across modes for portability