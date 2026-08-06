#!/bin/bash

# Ralph Loop Wrapper for Codex / OpenAI
# Runs the model in a while-true loop, checking for completion after each iteration.
# Usage: bash ralph-loop.sh "PROMPT" [--max-iterations N] [--completion-promise TEXT] [--model-cmd CMD]

set -euo pipefail

# Defaults
MAX_ITERATIONS=0
COMPLETION_PROMISE="null"
MODEL_CMD="${RALPH_MODEL_CMD:-}"

# Parse arguments
PROMPT_PARTS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --max-iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --completion-promise)
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    --model-cmd)
      MODEL_CMD="$2"
      shift 2
      ;;
    -h|--help)
      cat << 'HELP_EOF'
Ralph Loop Wrapper for Codex / OpenAI

USAGE:
  bash ralph-loop.sh "PROMPT" [OPTIONS]

ARGUMENTS:
  PROMPT    Initial prompt to start the loop

OPTIONS:
  --max-iterations <n>           Maximum iterations before auto-stop (default: unlimited)
  --completion-promise '<text>'  Promise phrase (USE QUOTES for multi-word)
  --model-cmd <cmd>              Model invocation command template.
                                 Use {PROMPT} as placeholder for the prompt.
                                 Default: tries opencode, then codex, then openai CLI.
  -h, --help                     Show this help message

DESCRIPTION:
  Runs the model in a while-true loop, checking each iteration's output
  for the completion promise. Passes previous output back as context so
  the model can iteratively improve.

EXAMPLES:
  bash ralph-loop.sh "Build a REST API" --max-iterations 20 --completion-promise DONE
  bash ralph-loop.sh "Fix the auth bug" --model-cmd "opencode run --print {PROMPT}"
  bash ralph-loop.sh "Refactor cache" --model-cmd "codex {PROMPT}"
HELP_EOF
      exit 0
      ;;
    *)
      PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

PROMPT="${PROMPT_PARTS[*]:-}"

if [[ -z "$PROMPT" ]]; then
  echo "❌ Error: No prompt provided" >&2
  echo "Usage: bash ralph-loop.sh \"PROMPT\" [OPTIONS]" >&2
  exit 1
fi

# Resolve default model command if not provided
if [[ -z "$MODEL_CMD" ]]; then
  if command -v opencode &>/dev/null; then
    MODEL_CMD="opencode run --print {PROMPT}"
  elif command -v codex &>/dev/null; then
    MODEL_CMD="codex {PROMPT}"
  elif command -v openai &>/dev/null; then
    MODEL_CMD="openai chat completions.create --model gpt-5.4 --message {PROMPT}"
  else
    echo "❌ Error: No supported CLI found. Install opencode, codex, or openai." >&2
    echo "Or provide a model command with --model-cmd." >&2
    exit 1
  fi
fi

# Create state directory
mkdir -p .claude

# State file for tracking iterations across runs
RALPH_STATE_FILE=".claude/ralph-loop.local.md"

# Check for existing state (resume from previous interrupted loop)
if [[ -f "$RALPH_STATE_FILE" ]]; then
  EXISTING_ITERATION=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE" | grep '^iteration:' | sed 's/iteration: *//' || echo "1")
  EXISTING_PROMPT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE" 2>/dev/null || echo "")
  if [[ -n "$EXISTING_PROMPT" ]] && [[ "$EXISTING_ITERATION" =~ ^[0-9]+$ ]]; then
    echo "🔄 Resuming Ralph loop from iteration $EXISTING_ITERATION"
    ITERATION="$EXISTING_ITERATION"
    PROMPT="$EXISTING_PROMPT"
  else
    ITERATION=1
  fi
else
  ITERATION=1
fi

echo "═══════════════════════════════════════════════════════════"
echo "🔄 Ralph Loop (Codex / OpenAI mode)"
echo "═══════════════════════════════════════════════════════════"
echo "Model cmd: $MODEL_CMD"
echo "Max iter:  $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)"
echo "Promise:   $(if [[ "$COMPLETION_PROMISE" != "null" ]]; then echo "$COMPLETION_PROMISE"; else echo "none"; fi)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Main loop
while true; do
  echo "─── Iteration $ITERATION ───"

  # Build the prompt with previous context (skip on first iteration)
  if [[ $ITERATION -gt 1 ]] && [[ -n "${PREVIOUS_OUTPUT:-}" ]]; then
    LOOP_PROMPT="${PROMPT}

---
Previous output (iteration $((ITERATION - 1))):
${PREVIOUS_OUTPUT}
---

Continue from where you left off. Fix any issues found and proceed toward the completion promise."
  else
    LOOP_PROMPT="$PROMPT"
  fi

  # Run the model using the configured command template
  # Replace {PROMPT} placeholder with the actual prompt (single-quoted to preserve special chars)
  RUN_CMD="${MODEL_CMD//\{PROMPT\}/$(printf '%q' "$LOOP_PROMPT")}"

  set +e
  OUTPUT=$(eval "$RUN_CMD" 2>&1)
  EXIT_CODE=$?
  set -e

  if [[ $EXIT_CODE -ne 0 ]]; then
    echo "⚠️  Model invocation failed (exit code $EXIT_CODE)" >&2
    echo "$OUTPUT" >&2
    # Save state for resume
    cat > "$RALPH_STATE_FILE" <<EOF
---
active: true
iteration: $ITERATION
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PROMPT
EOF
    echo "💾 State saved to $RALPH_STATE_FILE (run again to resume)"
    exit $EXIT_CODE
  fi

  # Display output
  echo "$OUTPUT"
  echo ""

  # Store output for next iteration's context
  PREVIOUS_OUTPUT="$OUTPUT"

  # Check for completion promise (only if set)
  if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
    if echo "$OUTPUT" | grep -qF "<promise>$COMPLETION_PROMISE</promise>"; then
      echo "✅ Ralph loop: Detected <promise>$COMPLETION_PROMISE</promise>"
      rm -f "$RALPH_STATE_FILE"
      exit 0
    fi
  fi

  # Check max iterations
  if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
    echo "🛑 Ralph loop: Max iterations ($MAX_ITERATIONS) reached."
    rm -f "$RALPH_STATE_FILE"
    exit 0
  fi

  # Increment and save state for resume
  ITERATION=$((ITERATION + 1))

  # Save state for resume on interruption
  cat > "$RALPH_STATE_FILE" <<EOF
---
active: true
iteration: $ITERATION
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PROMPT
EOF

  echo "🔄 Continuing to iteration $ITERATION..."
  echo ""
done