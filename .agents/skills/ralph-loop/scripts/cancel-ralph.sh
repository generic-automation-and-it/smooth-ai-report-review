#!/bin/bash

# Cancel Ralph Loop
# Removes the state file to stop an active loop

RALPH_STATE_FILE=".claude/ralph-loop.local.md"

if [[ ! -f "$RALPH_STATE_FILE" ]]; then
  echo "No active Ralph loop found."
  exit 0
fi

# Read current iteration for the message
ITERATION=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE" | grep '^iteration:' | sed 's/iteration: *//' || echo "unknown")

rm "$RALPH_STATE_FILE"
echo "Cancelled Ralph loop (was at iteration $ITERATION)"