#!/usr/bin/env bash
# Count changed files from a NUL-delimited changed_files.txt.
# Emits the integer count on stdout; 0 if the file is empty or missing.
set -euo pipefail

changed_files="${1:-ci_temp/changed_files.txt}"

if [ ! -s "$changed_files" ]; then
  echo 0
else
  tr '\0' '\n' < "$changed_files" | grep -c . || echo 0
fi