#!/bin/bash
# resolve-diff-base.sh — resolve a TRUE merge-base for the review diff range.
#
# Sourced (not exec'd) by run-review.sh, so the resolved value and the cache
# land in the caller's shell.
#
# Exposes:
#   resolve_diff_base <base_ref> <head_sha>
#       → echoes the merge-base SHA on stdout, rc 0
#       → on failure: emits an actionable ::error:: on stderr and returns 1
#   rdb_is_shallow
#       → rc 0 when the working repository carries a shallow graft
#
# LADR-075 — "Diff scope degrades loudly, never silently".
#
# Why this exists
# ---------------
# The four call sites in run-review.sh used to be:
#
#     git fetch upstream "${base_ref}" --depth=1 2>&1 || true
#     MERGE_BASE="$(git merge-base "upstream/${base_ref}" "$head_sha" \
#                    2>/dev/null || echo "$base_sha")"
#     git diff --name-only "${MERGE_BASE}..${head_sha}"
#
# Three compounding faults:
#
#   1. `--depth=1` writes a shallow graft into `.git/shallow` even when the
#      repository was previously complete (the gate checks out with
#      fetch-depth: 0). `git merge-base` cannot walk past that graft.
#   2. The `|| echo "$base_sha"` fallback substitutes `pull_request.base.sha`
#      — the base branch TIP, which is NOT an ancestor of head once the base
#      has moved on since the branch point.
#   3. `A..B` (two-dot) is only equivalent to `A...B` when A is an ancestor of
#      B. With the base tip on the left, the range spans the divergence in
#      both directions: every commit the base gained since the branch point
#      enters the review scope with its changes INVERTED.
#
# The result was a confident, well-evidenced review of already-merged code
# belonging to somebody else's PR — reported against v1 (upstream #120), seen
# on a 4-file PR reviewed as 34 files with four High findings, all foreign.
#
# The failure was invisible: the model reads the working tree, so its file
# evidence is real and only the attribution is wrong. Nothing in the posted
# output lets a reader detect it.
#
# Two things this module must keep getting right
# ----------------------------------------------
#   * A plain (non-shallow) fetch does NOT repair an already-shallow
#     repository. Only `--unshallow` / `--deepen` do. This matters because
#     run-review.sh Step 6 fetches the PR head with `--depth=1` on every
#     issue_comment / workflow_dispatch run — i.e. every `/ai-review` re-run
#     arrives here already grafted, regardless of how the base is fetched.
#   * Falling back to a three-dot range is NOT a safe degradation on a shallow
#     repository: `git diff A...B` errors with `fatal: no merge base`, and the
#     `2>/dev/null || true` on run-review.sh's pr_diff build would swallow it
#     into an EMPTY diff — a review of nothing, which is worse than a review
#     of the wrong thing. There is no correct range to fall back to, so this
#     module hard-fails instead, matching local-review.sh's existing
#     strictness rather than the old silent substitution.

# Memoised across the (at most two) call sites in a single run.
_RDB_CACHE_KEY=""
_RDB_CACHE_VAL=""

# rdb_is_shallow — rc 0 when the repository carries a shallow graft.
# `--is-shallow-repository` is git >= 2.15; the `.git/shallow` probe is the
# fallback for anything older.
rdb_is_shallow() {
  local _out
  if _out="$(git rev-parse --is-shallow-repository 2>/dev/null)"; then
    [ "$_out" = "true" ]
    return
  fi
  local _gitdir
  _gitdir="$(git rev-parse --git-dir 2>/dev/null || echo .git)"
  [ -f "${_gitdir}/shallow" ]
}

# _rdb_merge_base <base_ref> <head_sha> — echo the merge-base, rc 1 if none.
_rdb_merge_base() {
  local _mb
  _mb="$(git merge-base "upstream/${1}" "$2" 2>/dev/null)" || return 1
  [ -n "$_mb" ] || return 1
  printf '%s' "$_mb"
}

# resolve_diff_base <base_ref> <head_sha>
resolve_diff_base() {
  local base_ref="$1" head_sha="$2"
  local key="${base_ref}@${head_sha}" mb="" depth

  if [ -n "$_RDB_CACHE_VAL" ] && [ "$key" = "$_RDB_CACHE_KEY" ]; then
    printf '%s\n' "$_RDB_CACHE_VAL"
    return 0
  fi

  echo "Resolving diff base against upstream/${base_ref}..." >&2

  # 1. Fetch the base ref with its ancestry. NEVER --depth=1 here: see header.
  git fetch upstream "$base_ref" >/dev/null 2>&1 || true

  # 2. Repair a pre-existing graft (Step 6's --depth=1 head fetch, or a caller
  #    that checked out with fetch-depth: 1). Try the base repo first, then
  #    origin — for a fork PR the head-side objects live on origin.
  if rdb_is_shallow; then
    echo "  ↳ shallow repository detected — restoring ancestry" >&2
    git fetch upstream "$base_ref" --unshallow >/dev/null 2>&1 \
      || git fetch origin --unshallow >/dev/null 2>&1 \
      || true
  fi

  if mb="$(_rdb_merge_base "$base_ref" "$head_sha")"; then
    echo "  ↳ merge-base ${mb:0:7} (resolved from full ancestry)" >&2
    _RDB_CACHE_KEY="$key"
    _RDB_CACHE_VAL="$mb"
    printf '%s\n' "$mb"
    return 0
  fi

  # 3. Still unreachable — deepen progressively. `--deepen` is cumulative
  #    relative to the current shallow boundary, so each pass moves further
  #    back. Both remotes are tried because the merge-base may only be
  #    reachable from one of them on a fork PR.
  for depth in 100 1000 10000; do
    echo "  ↳ merge-base unreachable — deepening history by ${depth}" >&2
    git fetch upstream "$base_ref" --deepen="$depth" >/dev/null 2>&1 || true
    git fetch origin --deepen="$depth" >/dev/null 2>&1 || true
    if mb="$(_rdb_merge_base "$base_ref" "$head_sha")"; then
      echo "  ↳ merge-base ${mb:0:7} (resolved after --deepen=${depth})" >&2
      _RDB_CACHE_KEY="$key"
      _RDB_CACHE_VAL="$mb"
      printf '%s\n' "$mb"
      return 0
    fi
  done

  # 4. LADR-075: refuse to guess. Substituting the base TIP into a two-dot
  #    range is what produced foreign, inverted review scope; a three-dot
  #    range cannot be computed here either (no merge base is exactly what
  #    failed above). Fail loudly.
  {
    echo "::error::Cannot resolve a merge-base between upstream/${base_ref} and ${head_sha:0:7}. Refusing to review — a guessed base produces a review of commits this PR never touched (LADR-075)."
    echo "❌ Unable to resolve the diff base." >&2
    echo "   Tried: fetch upstream/${base_ref}, --unshallow, --deepen up to 10000." >&2
    echo "   Likely causes:" >&2
    echo "     • the base branch was force-pushed and head no longer descends from it" >&2
    echo "     • the PR head and base share no history (wrong base branch)" >&2
    echo "     • the checkout is shallow and the remote refuses to deepen" >&2
    echo "   Fix: merge or rebase '${base_ref}' into the PR branch, then re-run /ai-review." >&2
  } >&2
  return 1
}
