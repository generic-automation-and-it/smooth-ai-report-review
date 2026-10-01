#!/usr/bin/env bash
# Remove testing-gap items before autonomous analysis when test edits are off.
# stdin: one severity section; $1: report path (with a companion .count).
set -euo pipefail

report=${1:?usage: split-testing-gaps.sh <report-file>}
case "$(printf '%s' "${OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) enabled=1 ;;
  *) enabled=0 ;;
esac

input_file=$(mktemp)
trap 'rm -f "$input_file"' EXIT
cat > "$input_file"
python3 - "$report" "$enabled" "$input_file" <<'PY'
import re
import sys
from pathlib import Path

report = Path(sys.argv[1])
enabled = sys.argv[2] == '1'
lines = Path(sys.argv[3]).read_bytes().splitlines(keepends=True)
kept, skipped = bytearray(), bytearray()
count = 0
in_gap = False
for line in lines:
    if re.match(rb'^- \*\*T[0-9]+\)\*\*', line):
        in_gap = not enabled
        if in_gap:
            count += 1
    elif re.match(rb'^(?:- |[0-9]+\. )', line) or (line and not line[:1].isspace()):
        in_gap = False
    (skipped if in_gap else kept).extend(line)
report.parent.mkdir(parents=True, exist_ok=True)
report.write_bytes(skipped)
Path(str(report) + '.count').write_text(str(count) + '\n')
sys.stdout.buffer.write(kept)
PY
