#!/bin/bash
# Intersect two NUL-delimited file lists while preserving NUL delimiters.
#
# Temp files rather than `<(...)`: process substitution needs /dev/fd, which is
# not guaranteed on every shell this repo's scripts run under (Git Bash, and
# some container images mount it incompletely). This is the last remaining use
# in the shipped scripts — `merge-findings.sh` and `run-test-gate.sh` already
# avoid it for the same reason.
#
# The failure it removes was not silent: run-review.sh sets `set -euo pipefail`,
# so a failing `comm` aborted the whole incremental review. Fail-closed, but an
# outage — and it made test-run-review.sh red in every environment without
# /dev/fd, including the sandboxes this repo is developed in.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <file_list_a> <file_list_b> <output_file>" >&2
  exit 1
fi

input_a="$1"
input_b="$2"
output_file="$3"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

sort -z < "$input_a" > "${scratch}/a"
sort -z < "$input_b" > "${scratch}/b"

comm -z -12 "${scratch}/a" "${scratch}/b" > "$output_file"
