# Ralph Loop — Agent Notes

## 🎯 TL;DR

Ralph Loop implements the Ralph Wiggum technique for iterative, self-referential AI development loops. It works in two provider modes: Claude Code (stop hook intercepts exit and feeds the prompt back) and Codex/OpenAI (wrapper script `ralph-loop.sh` runs the model in a while-true loop with completion promise detection). The state file `.claude/ralph-loop.local.md` is shared across both modes for portability.

## Changelog

| Date | Change | Ref |
|------|--------|-----|