#!/bin/bash
# strip-finding-links.sh — remove the LADR-112 ` · [open](…)` permalink suffix
# from numbered finding lines. Reads a review body on stdin, writes it to stdout.
#
# Used by run-review.sh's body-size ladder: a body still over the posting limit
# after compaction drops its links before head/tail truncation can cut the
# Issues Summary mid-list. Only the trailing suffix of an `N. ` finding line is
# touched, so the stripped body is byte-identical to a render without links.
set -euo pipefail

sed -E 's/^([0-9]+\. .*) · \[open\]\([^)]*\)$/\1/'
