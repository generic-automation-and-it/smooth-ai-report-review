#!/usr/bin/env bash
# Exercise the workflow's actual run blocks, offline, without a model or GitHub.
set -euo pipefail
python3 - <<'PY'
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path.cwd()
workflow = (root / '.github/workflows/pipeline-ai-analyse.yml').read_text().splitlines()
analyse_dir = root / '.agents/skills/ai-analyse'
review_dir = root / '.agents/skills/ai-review-report'

def block(name):
    at = next(i for i, line in enumerate(workflow) if line == f'      - name: {name}')
    start = next(i for i in range(at + 1, len(workflow)) if workflow[i] == '        run: |') + 1
    lines = []
    for line in workflow[start:]:
        if line and not line.startswith('          '):
            break
        lines.append(line[10:] if line else '')
    return '\n'.join(lines) + '\n'

build = block('Build analyse prompt')
run = block('Run ai-analyse')
summary = block('Post ai-analyse summary')

def invoke(script, cwd, env):
    result = subprocess.run(['bash', '-euo', 'pipefail', '-c', script], cwd=cwd,
                            env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout

with tempfile.TemporaryDirectory() as tmp:
    scratch = Path(tmp)
    shim = scratch / 'ai-review/scripts'
    shim.mkdir(parents=True)
    helper = shim / 'copilot-review.sh'
    helper.write_text('#!/bin/bash\ncat\n')
    helper.chmod(0o755)
    env = dict(os.environ, ANALYSE_SKILL_DIR=str(analyse_dir),
               REVIEW_SKILL_DIR=str(review_dir), AI_REVIEW_DIR=str(scratch / 'ai-review'),
               PR_NUMBER='1', MEDIUM_SECTION='- **T1)** 🟡 Testing gap: no test covers when an upstream test fails',
               LOW_SECTION='', SUGGESTED_FIXES='', OPENCODE_ANALYSE_ENABLE_DECISIONS='0',
               OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX='0')

    # T-only: no model call, no failing-test misclassification, one posted SKIP.
    invoke(build, scratch, env)
    assert (scratch / 'ci_temp/analyse_no_scope').exists()
    assert 'upstream test fails' not in (scratch / 'ci_temp/analyse_prompt.md').read_text()
    assert (scratch / 'ci_temp/filter_reports/medium_testing_gaps.count').read_text().strip() == '1'
    assert not (scratch / 'ci_temp/filter_reports/medium_withheld').exists() or not (scratch / 'ci_temp/filter_reports/medium_withheld').read_text()
    invoke(run, scratch, env)
    posted = invoke(summary, scratch, env)
    assert 'model call skipped' in posted
    assert '| T1) | SKIP | Medium (testing gap)' in posted
    print('T-only default-off path: PASS')

    # Flag-on keeps the exact T item in the prompt and calls the model.
    shutil.rmtree(scratch / 'ci_temp')
    enabled = dict(env, OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX='TRUE',
                   MEDIUM_SECTION='- **T1)** 🟡 Testing gap: no test covers the new guard branch')
    invoke(build, scratch, enabled)
    assert not (scratch / 'ci_temp/analyse_no_scope').exists()
    assert enabled['MEDIUM_SECTION'] in (scratch / 'ci_temp/analyse_prompt.md').read_text()
    assert (scratch / 'ci_temp/filter_reports/medium_testing_gaps.count').read_text().strip() == '0'
    print('T flag-on pass-through: PASS')

    # Mixed scope: the model answers one finding, the completeness guard adds R.
    shutil.rmtree(scratch / 'ci_temp')
    mixed = dict(env, MEDIUM_SECTION='1. 🟡 Finding one\n- **R1)** 🟡 Residual risk: retry path\n' + env['MEDIUM_SECTION'])
    invoke(build, scratch, mixed)
    assert 'R1)' in (scratch / 'ci_temp/analyse_prompt.md').read_text()
    assert 'upstream test fails' not in (scratch / 'ci_temp/analyse_prompt.md').read_text()
    (scratch / 'ci_temp/analyse_out.md').write_text('| 1. | FIX | Medium | a.sh | one | mechanical |\n')
    posted = invoke(summary, scratch, mixed)
    assert '| T1) | SKIP | Medium (testing gap)' in posted
    assert '| R1) | SKIP | Medium (residual risk)' in posted
    assert '**Warning:** 1 in-scope item(s)' in posted
    assert '| 1. | FIX | Medium | a.sh | one | mechanical |' in posted
    print('mixed scope and posted completeness: PASS')

    # The default-branch YAML must still work against an older PR checkout.
    old = scratch / 'old-analyse'
    (old / 'scripts/lib').mkdir(parents=True)
    (old / 'SKILL.md').symlink_to(analyse_dir / 'SKILL.md')
    (old / 'scripts/lib/filter-failing-test-findings.sh').symlink_to(analyse_dir / 'scripts/lib/filter-failing-test-findings.sh')
    shutil.rmtree(scratch / 'ci_temp')
    legacy = dict(env, ANALYSE_SKILL_DIR=str(old),
                  MEDIUM_SECTION='- **T1)** 🟡 Testing gap: no test covers the new guard branch')
    invoke(build, scratch, legacy)
    assert not (scratch / 'ci_temp/analyse_no_scope').exists()
    assert legacy['MEDIUM_SECTION'] in (scratch / 'ci_temp/analyse_prompt.md').read_text()
    print('older checkout without new libs: PASS')
PY
