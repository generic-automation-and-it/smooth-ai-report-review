#!/bin/bash
# resolve-repo-root.sh — which repository local-review.sh reviews.
#
# Usage (sourced):
#   . "$SCRIPT_DIR/lib/resolve-repo-root.sh"
#   REPO_ROOT="$(resolve_review_repo_root "$SCRIPT_DIR")"
#
# In-repo and per-repo installs keep the skill at <repo>/<agent-dir>/skills/ai-review-report/scripts,
# so four levels up is the repo under review. A machine-wide install (scripts/install-skills.sh -g)
# keeps it in ~/.smooth-ai-review/skills/… and links it into ~/.claude/skills, ~/.codex/skills or
# ~/.config/opencode/skills, where four levels up is $HOME or ~/.config — never the repo the operator
# is standing in. When the derived folder is not the top of a git work tree, the current directory's
# work tree is the repo to review instead; outside any work tree this fails rather than guessing.
#
# Compared on physical paths: `git rev-parse --show-toplevel` resolves symlinks, so a logical `pwd`
# under a symlinked checkout would never match and would silently switch to the cwd's repo.
#
# OPENCODE_REVIEW_REPORT_REPO_ROOT still overrides all of this; the caller applies it before calling.

resolve_review_repo_root() {
  local script_dir="$1" derived toplevel
  derived="$(cd "$script_dir/../../../.." 2>/dev/null && pwd -P)" || derived=""
  if [ -n "$derived" ]; then
    toplevel="$(git -C "$derived" rev-parse --show-toplevel 2>/dev/null)" || toplevel=""
    if [ -n "$toplevel" ] && [ "$(cd "$toplevel" && pwd -P)" = "$derived" ]; then
      printf '%s\n' "$derived"
      return 0
    fi
  fi
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || toplevel=""
  if [ -n "$toplevel" ]; then
    (cd "$toplevel" && pwd -P)
    return 0
  fi
  echo "❌ Cannot tell which repository to review: the skill is installed outside a repository and the current directory is not inside a git work tree. cd into the repository, or set OPENCODE_REVIEW_REPORT_REPO_ROOT." >&2
  return 1
}
