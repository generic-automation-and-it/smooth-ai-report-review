---
name: ralph-loop
description: Start a Ralph Loop for iterative self-referential AI development. Run the model in a while-true loop with the same prompt until task completion, using a stop hook (Claude Code) or a wrapper script (Codex/OpenAI).
switches:
  - "`<prompt>` - the task description for the Ralph loop. Required."
  - "`--max-iterations N` - stop after N iterations (default: unlimited). Use as a safety net."
  - "`--completion-promise TEXT` - exact string that signals genuine completion. Must be output inside <promise> tags."
  - "`--cancel` - cancel an active Ralph loop (removes the state file)."
  - "`--help` / `-h` - show usage information."
allowed-tools:
  - Bash(.agents/skills/ralph-loop/scripts/setup-ralph-loop.sh:*)
  - Bash(.agents/skills/ralph-loop/scripts/ralph-loop.sh:*)
  - Bash(.agents/skills/ralph-loop/scripts/cancel-ralph.sh:*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/.agents/skills/ralph-loop/scripts/*:*)
models:
  claude: sonnet      # stop-hook mode; iteration tracking and transcript parsing require broader reasoning
  copilot: auto
  codex: gpt-5.4
  openai: gpt-5.4
---

# Ralph Loop

A Ralph Loop is a self-referential development loop: the same prompt is fed back to the model on each iteration, with previous work persisting in files and git history. The loop continues until the model outputs the completion promise or the iteration limit is reached.

## Starting a Loop

Run the setup script to create the loop state file:

    /ralph-loop "PROMPT" --max-iterations N --completion-promise "TEXT"

The setup script writes `.claude/ralph-loop.local.md` with YAML frontmatter tracking the iteration count, max iterations, and completion promise.

## How the Loop Works

### Claude Code (stop hook)

When running inside Claude Code, the stop hook (`scripts/stop-hook.sh`) is registered as a Claude Code stop hook. It intercepts exit attempts and feeds the same prompt back as input, creating a self-referential feedback loop.

The stop hook reads the state file to track iteration count and check for completion. It blocks session exit until the completion promise is detected or the max iteration count is reached.

### Codex / OpenAI (wrapper script)

When running with Codex or OpenAI (no stop hook available), use the wrapper script:

    bash .agents/skills/ralph-loop/scripts/ralph-loop.sh "PROMPT" --max-iterations N --completion-promise TEXT

The wrapper runs the model in a loop, checking each iteration's output for the completion promise. It passes previous output back as context so the model can iteratively improve.

The wrapper uses a configurable model command (`--model-cmd`) with `{PROMPT}` as a placeholder. By default it tries `opencode`, then `codex`, then `openai` CLI in order.

### Cancel

To cancel an active Ralph loop:

    /cancel-ralph

Or run the cancel script directly:

    bash .agents/skills/ralph-loop/scripts/cancel-ralph.sh

This removes the state file `.claude/ralph-loop.local.md`, which stops the loop on the next exit check (Claude Code) or next iteration check (Codex/OpenAI).

## Prompt Writing Best Practices

### 1. Clear Completion Criteria

Bad: "Build a todo API and make it good."

Good:
```markdown
Build a REST API for todos.

When complete:
- All CRUD endpoints working
- Input validation in place
- Tests passing (coverage > 80%)
- README with API docs
- Output: <promise>COMPLETE</promise>
```

### 2. Incremental Goals

Bad: "Create a complete e-commerce platform."

Good:
```markdown
Phase 1: User authentication (JWT, tests)
Phase 2: Product catalog (list/search, tests)
Phase 3: Shopping cart (add/remove, tests)

Output <promise>COMPLETE</promise> when all phases done.
```

### 3. Self-Correction

Bad: "Write code for feature X."

Good:
```markdown
Implement feature X following TDD:
1. Write failing tests
2. Implement feature
3. Run tests
4. If any fail, debug and fix
5. Refactor if needed
6. Repeat until all green
7. Output: <promise>COMPLETE</promise>
```

### 4. Escape Hatches

Always use `--max-iterations` as a safety net to prevent infinite loops on impossible tasks:

```bash
# Recommended: Always set a reasonable iteration limit
/ralph-loop "Try to implement feature X" --max-iterations 20

# In your prompt, include what to do if stuck:
# "After 15 iterations, if not complete:
#  - Document what's blocking progress
#  - List what was attempted
#  - Suggest alternative approaches"
```

The `--completion-promise` uses exact string matching, so you cannot use it for multiple completion conditions (like "SUCCESS" vs "BLOCKED"). Always rely on `--max-iterations` as your primary safety mechanism.

## State File

The loop state is stored in `.claude/ralph-loop.local.md` with YAML frontmatter:

```yaml
---
active: true
iteration: 1
session_id: <session-id>
max_iterations: 20
completion_promise: "COMPLETE"
started_at: "2026-08-02T00:00:00Z"
---

<PROMPT>
```

The stop hook reads this file to track iteration count and check for completion. The wrapper script (`ralph-loop.sh`) also uses it for state persistence across Codex/OpenAI iterations.