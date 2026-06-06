#!/bin/bash
set -e

# Get PR metadata from current branch
# Extracts: PR type, ticket number
# Output: JSON object with type, ticket, and branch fields

BRANCH=$(git branch --show-current)

# Extract branch prefix and determine PR type
PREFIX=$(echo "$BRANCH" | cut -d'/' -f1)
case "$PREFIX" in
    bugfix|fix)
        TYPE="Bugfix"
        ;;
    feature|feat)
        TYPE="Feature"
        ;;
    chore|maintenance)
        TYPE="Maintenance"
        ;;
    hotfix)
        TYPE="Hotfix"
        ;;
    doc|docs)
        TYPE="Documentation"
        ;;
    *)
        TYPE="Feature"
        ;;
esac

# Extract ticket number (e.g. VEM-1234, PROJ-567 — any uppercase prefix followed by digits)
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1 || echo "")

# Output JSON
jq -n \
    --arg type "$TYPE" \
    --arg ticket "$TICKET" \
    --arg branch "$BRANCH" \
    '{type: $type, ticket: $ticket, branch: $branch}'
