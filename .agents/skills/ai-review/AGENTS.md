---
name: ai-review-agents
description: Maintenance guide for ai-review skill — LADRs, Key Behaviors, env-var provenance, and script layout.
metadata:
  type: maintenance
  last_updated: 2026-08-14
---

# ai-review — Maintenance Guide (AGENTS.md)

## 🎯 TL;DR

Maintenance guide for the `ai-review` skill. Documents the EXIT-trap scope bug fix in `copilot-review.sh` (false failure + temp-file leak resolved via script-scoped registry + by-name assignment helper), Key Behaviors for script editing, bash 3.2.57 compatibility guardrails, and macOS edge cases.

---

This file documents the LADRs, Key Behaviors, environment variables, and internals of the `ai-review` skill — the **runtime contract** lives in `SKILL.md`.

## Recent Changes

### LADR — copilot-review.sh EXIT-trap scope bug (2026-08-14)

**Status:** Applied

**Summary:** `copilot-review.sh` `cmd_threads` and `cmd_describe` functions installed EXIT trap handlers that referenced local variables. When the handler fired after function return, the variable was out of scope, causing `unbound variable` error under `set -euo pipefail` and exiting 1 even though the GitHub write succeeded.

**Root Cause:** Function-local `trap ... EXIT` handlers run *after* the function returns, so local variables are no longer in scope. Trap dies before `rm` runs, leaving temp files leaked in `$TMPDIR`.

**Fix:**
- Moved EXIT trap to script scope (global `CLEANUP_TMPFILES` array)
- Introduced `make_tmpfile()` helper for by-name assignment (avoids subshell registration bug)
- Guarded empty-array expansion with `set -u` safety check
- Added detailed comments explaining why trap must be script-scoped and why helper assigns by name — both bugs are regression-prone

**Impact:**
- Prevents false CI failures on successful GitHub writes
- Stops temp-file leak (14+ stale `ai-review.*` files measured per run batch)
- Fixes exit status visibility for callers checking `$?`

**Testing:**
- Syntax check: `bash -n copilot-review.sh` ✓
- Empty-array guard: safe under `set -euo pipefail` ✓
- Helper creates and registers temp files correctly ✓
- Trap cleans all registered files on exit ✓

## Key Behaviors

1. **Script-scoped cleanup.** EXIT trap is installed at script load, not inside any function. A global `CLEANUP_TMPFILES` array collects temp file paths created during execution. The trap runs after all functions return, so all locals are out of scope — the registry must be global to survive.

2. **By-name assignment for temp files.** The `make_tmpfile()` helper assigns temp file paths into a caller-scoped variable (e.g., `make_tmpfile tmpvar`; `echo "x" > "$tmpvar"`), rather than echoing the path. Command substitution runs in a subshell, so `var="$(helper)"` would register the path in the subshell's registry only — the parent shell's array never sees it, and every file leaks. Dynamic scoping via `eval` ensures the parent gets the assignment.

3. **Helper locals prefixed with `__`.** The `make_tmpfile()` function uses `__varname`, `__template`, `__path` instead of unadorned names. Bash is dynamically scoped, so an unprefixed local named `tmp` inside the helper would shadow the caller's `tmp` variable, breaking the assignment.

4. **No function-local traps.** Do not install trap handlers inside any function definition. All trap installation happens at the script scope before any function is called.

## Environment Variables

None new — this skill inherits env-var handling from `SKILL.md`.

## Script Layout

```
.agents/skills/ai-review/
  SKILL.md                    — Runtime contract (invocation, modes, allowed-tools)
  AGENTS.md                   — This file (maintenance, LADRs, internals)
  scripts/
    copilot-review.sh         — GitHub REST/GraphQL plumbing for Copilot review routing
```

## macOS Compatibility

Script uses `#!/usr/bin/env bash` and bash 3.2.57 (macOS native `/bin/bash`). No bash 4+ features (`declare -n`, `mapfile`, `associative arrays`). Array indexing and expansion via `"${ARR[@]}"` is safe under `set -u` when guarded with `[ "${#ARR[@]}" -gt 0 ]`.
