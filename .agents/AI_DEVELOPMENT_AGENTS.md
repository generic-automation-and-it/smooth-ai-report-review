# AGENTS.md - AI Development Experience

🤖 AI Context: Unified AI development folder structure and best practices. Updated: 2026-06-10 Maintainer: Engineering Team

## 🎯 TL;DR

The `.agents` folder provides a tool-agnostic structure for AI-assisted development, with symbolic links (`.claude`, `.codex`) ensuring compatibility across multiple AI coding tools without duplication or vendor lock-in. In this repo it is deliberately minimal: it carries only the AI PR review pipeline skills and their supporting configuration — the generic devex scaffolding (rule system, hooks, prompt/role/document templates, auxiliary skills) was removed in the 2026-06-10 cleanup (#34).

## 📋 Overview

This is a unified AI development experience folder that centralizes skills and configuration for AI-assisted coding tools.

**Scope:**
- In: Skill definitions, tool permissions, AI review pipeline tooling
- Out: Tool-specific internal state (handled by individual tools), model weights, API credentials, generic devex rules/hooks/templates (removed — see #34)
- Depends: Git (for version control), bash/shell (for scripts), symbolic link support (Unix-like systems)

## 🏗️ Architecture

### Folder Structure

| Path | Purpose |
| :---- | :---- |
| `.agents/` | Root folder for all AI development tooling |
| `.agents/settings.json` | Tool permissions, compile/test commands |
| `.agents/hooks.json` | Hook configuration (currently empty — all hook scripts were removed in #34) |
| `.agents/setup/scripts/` | `agents-setup.sh` / `agents-setup.ps1` — recreate the symlink aliases if needed |
| `.agents/skills/` | Executable skills (multi-file workflows) — flat dirs, one level deep |
| `.agents/skills/ai-review/` | Analyze and execute AI PR review decisions |
| `.agents/skills/ai-review-report/` | Chunked AI PR review pipeline (CI gate + local runner) |
| `.agents/skills/git-commit-review-push/` | Commit (with `/ai-review` trigger on the final commit) and push to remote |
| `.claude` → `.agents` | Symbolic link for Claude Code compatibility |
| `.codex` → `.agents` | Symbolic link for OpenAI Codex compatibility |
| `CLAUDE.md` → `AGENTS.md` | Symbolic link alias for Claude-compatible root context discovery |

### Tool Compatibility Matrix

| Tool | Access Method | Status |
| :---- | :---- | :---- |
| **Claude Code** | Via `.claude` symlink | ✅ Active |
| **GitHub Copilot** | `.github/copilot-instructions.md` pointing at root `AGENTS.md` for repo-wide context | ✅ Active |
| **OpenAI Codex** | Via `.codex` symlink | ✅ Active |
| **Aider** | Direct `.agents` access (CLI) | ✅ Compatible |

## 📐 Architecture Decisions (Lightweight ADRs)

### LADR-001: Agnostic .agents Folder Structure

- **Date**: 2026-02-12
- **Status**: Accepted
- **Context**: Project was using `.claude` folder, but team wanted to support multiple AI coding tools without duplicating configuration or creating vendor lock-in
- **Decision**: Create tool-agnostic `.agents` folder as single source of truth, with symbolic links for tool-specific compatibility
- **Consequences**:
  - Single configuration folder to maintain
  - Easy to add support for new AI tools (just create symlink)
  - Backward compatible with existing `.claude` references
  - Requires symbolic link support (standard on Unix/Linux/macOS)

### LADR-002: Symbolic Link Strategy for Backward Compatibility

- **Date**: 2026-02-12
- **Status**: Accepted
- **Context**: Existing scripts, documentation, and workflows reference `.claude` paths explicitly
- **Decision**: Use symbolic links (`.claude` → `.agents`, `.cursor` → `.agents`, `.codex` → `.agents`) to maintain backward compatibility while migrating to agnostic structure
- **Consequences**:
  - Zero-downtime migration (existing references continue working)
  - Tools automatically access unified configuration
  - Symbolic links are committed to git

### LADR-003: Git Ignore Strategy

- **Date**: 2026-02-12
- **Status**: Accepted
- **Context**: Some AI tools generate local state files that should not be committed
- **Decision**:
  - Commit `.agents` folder structure and configuration to git
  - Commit symlinks to git for zero-setup developer experience
  - Ignore tool-specific local state: `.agents/settings.local.json`
- **Consequences**:
  - Clean git history without local state pollution
  - Symlinks available immediately after clone

### LADR-004: Rule Files Physically Located in `.github/instructions` (Symlink Inversion)

- **Date**: 2026-06-06
- **Status**: ~~Accepted~~ **Retired 2026-06-10** — the rule system was removed entirely in the devex cleanup (#34): `.github/instructions/` and the `.agents/rules` symlink no longer exist. Retained for history only.
- **Context**: GitHub Copilot's Coding Agent / Code Review runs on github.com against a server-side checkout and did not reliably traverse a symlinked rules directory, so the rule files were inverted to physically live in `.github/instructions/` with `.agents/rules` as a symlink back to it.
- **Outcome**: Superseded by removal. Copilot guidance now comes solely from `.github/copilot-instructions.md` + root `AGENTS.md`. Note: `ai-review-report`'s gate still warn-and-skips `MANDATORY_CONTEXT_FILES` rule paths that exist only in *consuming* repos — that cross-repo contract is unaffected by this repo dropping its own rule tree.

### LADR-005: Devex Cleanup — `.agents` Reduced to the Review Pipeline

- **Date**: 2026-06-10
- **Status**: Accepted
- **Context**: This repo's deliverable is the AI PR review pipeline, but `.agents/` still carried the full devex template scaffolding it was seeded from: a rule system, 7 hook scripts, document templates, and 10 auxiliary skills unrelated to the deliverable.
- **Decision**: Remove the templating (#34): delete `.agents/hooks/`, `.agents/rules` + `.github/instructions/`, `.agents/templates/`, `.agents/config.toml`, `.agents/launch.json`, `agents-terminals.*`, and all skills except `ai-review`, `ai-review-report`, and `git-commit-review-push` (renamed from `git-commit-push`, with the commit logic inlined and the `/ai-review` full-review trigger appended to the final chunk commit).
- **Consequences**:
  - `.agents/` now contains only the review-pipeline skills, `settings.json`, an empty `hooks.json`, and the symlink setup scripts.
  - **Open item**: the LLM eval harness (`scripts/eval/run-evals.sh`, `.github/workflows/llm-eval-harness.yml`) still expects `.github/instructions/code-review-standards.instructions.md` as the DR-standards fixture source — relocate the standards or update the harness (tracked on #34).

## 📊 Setup Instructions

**Symlinks (`.claude`, `.codex`, `CLAUDE.md`) are committed to git and available immediately after clone, so no setup script is required.**

```bash
# Verify links are present after clone
ls -la | grep -E '(\.claude|\.codex)'
# Expected output:
# lrwxr-xr-x ... .claude -> .agents
# lrwxr-xr-x ... .codex -> .agents
```

**Optional: Run setup script to recreate symlink aliases if needed:**
```bash
# Mac/Linux
./.agents/setup/scripts/agents-setup.sh

# Windows (Administrator)
./.agents/setup/scripts/agents-setup.ps1
```

## 📝 Changelog

| Date | Change | Reason |
| :---- | :---- | :---- |
| 2026-05-30 | Initial version. | |
| 2026-06-10 | Devex cleanup: removed rules/hooks/templates/auxiliary skills; kept only the review-pipeline skills; retired LADR-004; added LADR-005. | #34 |
| 2026-06-10 | Dropped Cursor and Gemini support: `.cursor` and `GEMINI.md` symlinks removed (also from the setup scripts). | #34 |
