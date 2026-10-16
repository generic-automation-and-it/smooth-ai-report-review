#!/bin/bash
# quarantine-project-config.sh — move the repo-under-review's own
# opencode.json(c) files aside and stand the gate's managed config in their
# place for the duration of the run (LADR-103).
#
# Why: opencode merges project config (opencode.json(c) at the repo root and
# .opencode/opencode.json(c)) ABOVE the gate's OPENCODE_CONFIG, and loads it
# from the untrusted PR head. A consumer repo that ships its own
# opencode.json (e.g. broad shell/edit grants) trips newer opencode builds'
# "untrusted project OpenCode config is not allowed in CI" hard-fail, and —
# worse — a hostile PR could override the review agent's permission lockdown
# (LADR-029) the way LADR-071 already describes. The gate never honoured
# consumer project config anyway (providers come from the managed copy), so
# quarantining it changes no review behaviour — it only removes the untrusted
# input.
#
# What is quarantined (relative to the workspace root — the repo under
# review, NOT the tooling checkout):
#   opencode.json, opencode.jsonc,
#   .opencode/opencode.json, .opencode/opencode.jsonc
# Regular files AND symlinks (a root opencode.json symlinking into e.g.
# .github/assets/opencode.json is moved as a link — the target is untouched).
# .github/opencode.json is NEVER touched: opencode does not auto-discover it;
# it only matters when explicitly selected via OPENCODE_REVIEW_REPORT_CONFIG
# (LADR-047), in which case it is already the managed source.
#
# Replacement: when at least one file was moved aside and OPENCODE_CONFIG
# points at a readable file (the prepare-opencode-config.sh resolved copy —
# built-in asset, LADR-047 override, or a client file such as
# .github/assets/opencode.json passed via opencode_config), a byte copy is
# placed at <root>/opencode.json. Any reader — opencode's config walk or the
# model — then sees exactly the managed config, never PR-head content.
# When nothing was quarantined the tree is left byte-identical (no replacement
# is created for a problem that does not exist).
#
# Restore is mandatory and must never fail the run: local-review.sh runs on
# the user's live repo, and pipeline-ai-analyse.yml stages and commits the
# tree — a leftover replacement would be committed to the PR. Both entry
# points restore deterministically (EXIT trap / before staging), and restore
# is idempotent.
#
# Usage (sourced — it must share the caller's shell for the trap path):
#   . lib/quarantine-project-config.sh
#   quarantine_project_config "${GITHUB_WORKSPACE:-$PWD}"
#   ...
#   restore_project_config   # always returns 0
# CLI (for workflow steps that cannot share a shell):
#   bash lib/quarantine-project-config.sh --restore
#   (reads the manifest path from $QPC_MANIFEST, forwarded via $GITHUB_ENV
#   at quarantine time)
#
# Bash 3.2 safe (local-review.sh on macOS): no ${var,,}, no associative
# arrays, no mapfile. Like prepare-opencode-config.sh this file is SOURCED,
# so every variable lives inside function-locals — no file-scope state.

# quarantine_project_config <workspace_root>
# Moves candidates aside, writes the replacement, records everything in a
# manifest under a private backup dir. Safe to call when nothing exists
# (no-op) and safe to re-run after restore_project_config (fresh backup,
# fresh manifest).
quarantine_project_config() {
  local root candidates backup manifest rel src dest count
  local replaced replacement_src
  root="$1"
  candidates="opencode.json
opencode.jsonc
.opencode/opencode.json
.opencode/opencode.jsonc"
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "quarantine-project-config: workspace root '${root:-<empty>}' is not a directory — skipping." >&2
    return 0
  fi

  backup="$(mktemp -d "${TMPDIR:-/tmp}/qpc-backup.XXXXXX" 2>/dev/null)" || {
    echo "quarantine-project-config: cannot create backup dir — skipping (project config left in place)." >&2
    return 0
  }
  manifest="$backup/MANIFEST"
  : > "$manifest" || {
    echo "quarantine-project-config: cannot write manifest — skipping." >&2
    rmdir "$backup" 2>/dev/null
    return 0
  }
  printf '%s\n' "$root" > "$backup/ROOT"
  : > "$backup/REPLACEMENT"
  count=0

  for rel in $candidates; do
    src="$root/$rel"
    # -e misses dangling symlinks; -L catches any link. Anything else
    # (directories, fifos) is not something opencode would load as config.
    if [ -e "$src" ] || [ -L "$src" ]; then
      if [ ! -f "$src" ] && [ ! -L "$src" ]; then
        echo "quarantine-project-config: $rel is not a file/symlink — left in place." >&2
        continue
      fi
      dest="$backup/files/$rel"
      mkdir -p "$(dirname "$dest")" 2>/dev/null || {
        echo "quarantine-project-config: cannot stage backup for $rel — restoring and skipping." >&2
        QPC_MANIFEST="$manifest" restore_project_config >/dev/null 2>&1
        return 0
      }
      # mv moves a symlink as a link — its target is never touched.
      if mv -- "$src" "$dest" 2>/dev/null; then
        printf '%s\n' "$rel" >> "$manifest"
        count=$((count + 1))
        echo "quarantine-project-config: moved aside $rel"
      else
        echo "quarantine-project-config: cannot move $rel — restoring and skipping." >&2
        QPC_MANIFEST="$manifest" restore_project_config >/dev/null 2>&1
        return 0
      fi
    fi
  done

  # Replacement: only when something was actually quarantined.
  replaced=""
  if [ "$count" -gt 0 ]; then
    replacement_src="${OPENCODE_CONFIG:-}"
    if [ -z "$replacement_src" ] || [ ! -f "$replacement_src" ]; then
      echo "quarantine-project-config: OPENCODE_CONFIG unset/unreadable — files held aside with no stand-in." >&2
    elif [ "$root/opencode.json" -ef "$replacement_src" ] 2>/dev/null; then
      echo "quarantine-project-config: root opencode.json already is the managed config — no stand-in needed."
    elif cp -- "$replacement_src" "$backup/_replacement.opencode.json" 2>/dev/null \
      && cp -- "$replacement_src" "$root/opencode.json" 2>/dev/null; then
      printf '%s\n' "opencode.json" > "$backup/REPLACEMENT"
      replaced="yes"
      echo "quarantine-project-config: root opencode.json now carries the managed config ($count file(s) held aside)"
    else
      echo "quarantine-project-config: stand-in copy failed — files held aside with no replacement." >&2
    fi
  else
    echo "quarantine-project-config: no project opencode.json(c) under $root — tree untouched."
  fi

  QPC_MANIFEST="$manifest"
  export QPC_MANIFEST
  QPC_QUARANTINED="$(tr '\n' ' ' < "$manifest" 2>/dev/null)"
  export QPC_QUARANTINED
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'QPC_MANIFEST=%s\n' "$manifest" >> "$GITHUB_ENV"
  fi
  return 0
}

# restore_project_config [manifest_path]
# Returns every moved file (links included) and withdraws the stand-in.
# Idempotent, fail-open (always returns 0 — it runs in EXIT traps and before
# commit staging, where a failure must never change the run's outcome).
# If something new appeared at an original path in the meantime (e.g. the
# model recreated it), that occupant is preserved under the backup dir, never
# silently destroyed.
restore_project_config() {
  local manifest backup_dir root rel dest replacement replacement_slot
  manifest="${1:-${QPC_MANIFEST:-}}"
  if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
    return 0
  fi
  backup_dir="$(dirname "$manifest")"
  if [ ! -f "$backup_dir/ROOT" ]; then
    return 0
  fi
  root="$(cat "$backup_dir/ROOT" 2>/dev/null)"
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    return 0
  fi

  # 1. Withdraw the stand-in, but only if it is still ours.
  replacement="$backup_dir/_replacement.opencode.json"
  replacement_slot=""
  if [ -f "$backup_dir/REPLACEMENT" ]; then
    replacement_slot="$(cat "$backup_dir/REPLACEMENT" 2>/dev/null)"
  fi
  if [ -n "$replacement_slot" ] && [ -f "$replacement" ]; then
    dest="$root/$replacement_slot"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if cmp -s "$dest" "$replacement" 2>/dev/null; then
        rm -f "$dest" 2>/dev/null
      else
        mkdir -p "$backup_dir/occupied" 2>/dev/null
        mv -- "$dest" "$backup_dir/occupied/opencode.json" 2>/dev/null
        echo "quarantine-project-config: root opencode.json changed during the run — occupant preserved, stand-in withdrawn." >&2
      fi
    fi
  fi

  # 2. Return every held file to its original path.
  while IFS= read -r rel; do
    if [ -z "$rel" ]; then
      continue
    fi
    if [ -f "$backup_dir/files/$rel" ] || [ -L "$backup_dir/files/$rel" ]; then
      dest="$root/$rel"
      if [ -e "$dest" ] || [ -L "$dest" ]; then
        mkdir -p "$backup_dir/occupied" 2>/dev/null
        mv -- "$dest" "$backup_dir/occupied/$(printf '%s' "$rel" | tr '/' '_')" 2>/dev/null
        echo "quarantine-project-config: $rel reappeared during the run — occupant preserved, original restored." >&2
      fi
      mkdir -p "$(dirname "$dest")" 2>/dev/null
      if mv -- "$backup_dir/files/$rel" "$dest" 2>/dev/null; then
        echo "quarantine-project-config: restored $rel"
      else
        echo "quarantine-project-config: could not restore $rel — original kept at $backup_dir/files/$rel." >&2
      fi
    fi
  done < "$manifest"

  QPC_MANIFEST=""
  export QPC_MANIFEST
  QPC_QUARANTINED=""
  export QPC_QUARANTINED
  return 0
}

# CLI entry for workflow steps that cannot share the caller's shell.
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --restore)
      restore_project_config "${2:-}"
      exit 0
      ;;
    *)
      echo "usage: quarantine-project-config.sh --restore [manifest]" >&2
      exit 64
      ;;
  esac
fi
