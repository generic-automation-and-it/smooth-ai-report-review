#!/bin/bash
# Push commits to remote repository
# Usage: push.sh

set -e

# Get current branch name
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Check if upstream is configured
if ! git rev-parse --abbrev-ref @{u} >/dev/null 2>&1; then
    # No upstream configured: push and set upstream
    echo "Pushing new branch '$BRANCH' to origin..."
    git push -u origin "$BRANCH"
    exit 0
fi

# Upstream is configured: check for unpushed commits using plumbing
if [ -z "$(git log @{u}..HEAD --oneline)" ]; then
    echo "No commits to push"
    exit 0
fi

# Push to remote
git push
