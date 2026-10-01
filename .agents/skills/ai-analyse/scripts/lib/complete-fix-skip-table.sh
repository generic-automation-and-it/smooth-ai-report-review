#!/usr/bin/env bash
# Append-only completeness check for the autonomous fixer's FIX/SKIP table.
# $1 scope as sent to model; $2 model output; $3 output count file;
# remaining arguments are pre-decided/withheld reports (excluded defensively).
set -euo pipefail
scope=${1:?usage: complete-fix-skip-table.sh <scope> <model-output> <count-file> [excluded-reports...]}
model=${2:?missing model output}
count_file=${3:?missing count file}
shift 3
python3 - "$scope" "$model" "$count_file" "$@" <<'PY'
import re
import sys
from pathlib import Path

def identifier(raw):
    cell = raw.strip().strip('*`').strip()
    match = re.fullmatch(r'#?([0-9]+)\.?', cell)
    if match:
        return match.group(1)
    match = re.fullmatch(r'([RTPH][0-9]+)\)?', cell, re.I)
    return match.group(1).upper() if match else None

scope = Path(sys.argv[1]).read_text()
model = Path(sys.argv[2]).read_text() if Path(sys.argv[2]).exists() else ''
excluded = set()
for name in sys.argv[4:]:
    path = Path(name)
    if path.exists():
        for line in path.read_text().splitlines():
            match = re.match(r'^\s*(?:- \*\*([RTPH][0-9]+)\)\*\*|([0-9]+)\. )', line)
            if match:
                excluded.add(match.group(1) or match.group(2))

items = []
section = 'Medium'
for line in scope.splitlines():
    if line.startswith('### Low'):
        section = 'Low'
    elif line.startswith('### Medium'):
        section = 'Medium'
    match = re.match(r'^(?:([0-9]+)\. |- \*\*([0-9]+)\.\*\* |\s*- \*\*([RTPH][0-9]+)\)\*\*)', line)
    if match:
        key = match.group(1) or match.group(2) or match.group(3)
        if key not in excluded and key not in {item[0] for item in items}:
            priority = section
            if key.startswith('R'):
                priority = 'Medium (residual risk)'
            elif key.startswith('T'):
                priority = 'Medium (testing gap)'
            items.append((key, priority))

answered = set()
for line in model.splitlines():
    if not line.lstrip().startswith('|'):
        continue
    cells = line.strip().strip('|').split('|')
    if len(cells) < 2 or not re.search(r'\b(FIX|SKIP)\b', cells[1].strip().strip('*`'), re.I):
        continue
    key = identifier(cells[0])
    if key:
        answered.add(key)

missing = [(key, priority) for key, priority in items if key not in answered]
for key, priority in missing:
    display = key + (')' if key[:1].isalpha() else '.')
    print(f'| {display} | SKIP | {priority} | — | Not addressed | not addressed by the autonomous fixer |')
Path(sys.argv[3]).write_text(str(len(missing)) + '\n')
PY
