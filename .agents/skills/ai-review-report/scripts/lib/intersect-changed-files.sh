#!/usr/bin/env bash
# intersect-changed-files.sh — NUL-delimited file-list intersection.
#
# Single source of truth for the incremental review intersection (LADR-048
# pattern): both run-review.sh and test-run-review.sh delegate here so a
# regression is caught by the tests rather than requiring separate maintenance.
#
# Usage: bash intersect-changed-files.sh <since_file> <branch_file>
#
# Inputs (positional):
#   since_file   — NUL-delimited list of files changed since the last review
#   branch_file  — NUL-delimited list of files changed in the feature branch
#
# Output: NUL-delimited intersection of the two sets, written to stdout.
#
# Why not tr '\0' '\n' | sort | comm | tr '\n' '\0':
#   That round-trip breaks filenames that contain embedded newlines (legal on
#   Linux/macOS) and was the original bug this script was created to fix.
#   The -z flags on sort and comm keep every byte of each filename intact.
set -euo pipefail

since_file="${1:?Usage: intersect-changed-files.sh <since_file> <branch_file>}"
branch_file="${2:?Usage: intersect-changed-files.sh <since_file> <branch_file>}"

comm -z -12 \
  <(sort -z < "$since_file") \
  <(sort -z < "$branch_file")
