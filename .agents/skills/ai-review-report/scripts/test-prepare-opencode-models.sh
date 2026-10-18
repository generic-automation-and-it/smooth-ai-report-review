#!/bin/bash
# Offline model-registration contract + production initialization blocks.
# Never discovers a real opencode binary or starts a real service.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR" "$BASH" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import yaml

scripts = Path(sys.argv[1])
bash = sys.argv[2]
repo = scripts.parents[3]
helper = scripts / "lib/ensure-opencode-models.sh"
jq = shutil.which("jq")
assert jq, "jq required"
passed = 0


def check(label, condition):
    global passed
    assert condition, label
    passed += 1
    print("PASS:", label)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


def command(path, args, env, cwd):
    return subprocess.run([bash, str(path), *args], env=env, cwd=cwd,
                          text=True, capture_output=True)


with tempfile.TemporaryDirectory(prefix="test-opencode-models-") as temp:
    root = Path(temp)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    # Whitelist tools; never inherit the developer's real CLI via PATH.
    for name in ("basename", "cat", "chmod", "cmp", "cp", "dirname", "grep", "head",
                 "jq", "mkdir", "mktemp", "mv", "rm", "tr"):
        (bin_dir / name).symlink_to(shutil.which(name))
    (bin_dir / "bash").symlink_to(bash)
    write(bin_dir / "opencode", "#!/bin/sh\nexit 98\n")
    write(bin_dir / "timeout", "#!/bin/sh\nexit 98\n")
    env = {"PATH": str(bin_dir), "HOME": str(root / "home"), "TEST_BASH": bash,
           "XDG_CONFIG_HOME": str(root / "xdg-config"),
           "XDG_DATA_HOME": str(root / "xdg-data"), "TMPDIR": str(root),
           "GITHUB_ENV": ""}
    Path(env["HOME"]).mkdir()
    config = root / "resolved.json"

    def ensure(document, models, provider="p", extra=None):
        config.write_text(document if isinstance(document, str) else json.dumps(document))
        before = config.read_bytes()
        inode = config.stat().st_ino
        result = command(helper, [str(config), provider, *models], dict(env, **(extra or {})), root)
        assert result.returncode == 0, result.stderr
        assert not list(root.glob("resolved.json.models.*")), "temporary config leaked"
        return result, before, inode

    for shape in ("provider", "providers"):
        models = {"alias": {"id": "upstream", "modelID": "deployment", "options": {"x": 1},
                            "settings": {"apiKey": "{env:KEEP}"}, "limit": {"context": 12345},
                            "capabilities": {"tools": True}},
                  "null": None, "false": False, "disabled": {"disabled": True}}
        original = {shape: {"p": {"models": models, "options": {"apiKey": "{env:KEY}"}},
                            "other": {"models": {"keep": {}}}}, "instructions": ["keep.md"]}
        result, _, _ = ensure(original, ["new", "new", "vendor/model.v2", 'quote".$[]', "", "--flag"])
        updated = json.loads(config.read_text())
        expected = json.loads(json.dumps(original))
        expected[shape]["p"]["models"].update({m: {} for m in ("new", "vendor/model.v2", 'quote".$[]', "--flag")})
        check(f"{shape}: absent-only batch, opaque IDs, aliases/disabled/metadata/placeholders intact", updated == expected)
        existing = list(expected[shape]["p"]["models"])
        _, before, inode = ensure(expected, existing)
        check(f"{shape}: all-listed invocation is byte/inode-identical", config.read_bytes() == before and config.stat().st_ino == inode)
        first = config.read_bytes()
        result = command(helper, [str(config), "p", *existing], env, root)
        check(f"{shape}: repeated invocation no-op", result.returncode == 0 and config.read_bytes() == first)
        ensure({shape: {"p": {}}}, ["new"])
        check(f"{shape}: missing models map created", json.loads(config.read_text())[shape]["p"]["models"] == {"new": {}})

    invalid = [[], None, False, 7, "text", {"provider": []}, {"providers": []},
               {"provider": {}}, {"providers": {"p": None}, "provider": {"p": {}}}]
    for value in (None, False, [], "text", 7):
        invalid.extend([{"provider": {"p": value}}, {"providers": {"p": {"models": value}}}])
    for index, document in enumerate(invalid):
        result, before, inode = ensure(document, ["new"])
        check(f"unsupported shape {index}: advisory and unchanged", "⚠️" in result.stderr and config.read_bytes() == before and config.stat().st_ino == inode)
    for document in ('{"provider": {', '{// JSONC\n"provider":{"p":{}}}', '{}\n{}'):
        result, before, _ = ensure(document, ["new"])
        check("invalid/JSONC/multiple documents: warn and preserve", "⚠️" in result.stderr and config.read_bytes() == before)
    for models in ([], ["", ""]):
        _, before, inode = ensure({"provider": {"p": {}}}, models)
        check("empty models are a true no-op", config.read_bytes() == before and config.stat().st_ino == inode)
    for args in ([], [str(config)], [str(config), ""], ["", "p", "new"], [str(root / "absent"), "p", "new"]):
        result = command(helper, args, env, root)
        check("missing/empty arguments or file remain advisory", result.returncode == 0 and "⚠️" in result.stderr)
    link = root / "link.json"
    link.symlink_to(config)
    before = config.read_bytes()
    result = command(helper, [str(link), "p", "new"], env, root)
    check("symlink destination rejected", result.returncode == 0 and "⚠️" in result.stderr and config.read_bytes() == before and link.is_symlink())
    no_jq = root / "no-jq"
    no_jq.mkdir()
    result, before, _ = ensure({"provider": {"p": {}}}, ["new"], extra={"PATH": str(no_jq)})
    check("absent jq is advisory and does not invent providers", "jq is unavailable" in result.stderr and config.read_bytes() == before)

    # Each fault hits the real helper. write-pass failures do not accidentally
    # pass by failing the earlier validation probe instead.
    for fault in ("mktemp", "write", "invalid-output", "mv"):
        faults = root / ("fault-" + fault)
        faults.mkdir()
        counter = faults / "calls"
        if fault in ("mktemp", "mv"):
            write(faults / fault, "#!/bin/sh\nexit 1\n")
        else:
            write(faults / "jq", f'''#!{bash}
n=0; [ ! -f "{counter}" ] || read -r n < "{counter}"
n=$((n + 1)); echo "$n" > "{counter}"
if [ "$n" -eq 2 ]; then
  {'echo "{"; exit 0' if fault == 'invalid-output' else 'exit 1'}
fi
exec "{jq}" "$@"
''')
        result, before, _ = ensure({"provider": {"p": {}}}, ["new"], extra={"PATH": f"{faults}:{bin_dir}"})
        check(f"{fault} failure: original retained, warning, no temp leak", "⚠️" in result.stderr and config.read_bytes() == before)
        if fault in ("write", "invalid-output"):
            check("fault reached write pass", int(counter.read_text()) >= 2)

    # Run the production helper under macOS's older Bash too when available.
    if sys.platform == "darwin":
        config.write_text('{"provider":{"p":{}}}')
        result = subprocess.run(["/bin/bash", str(helper), str(config), "p", "bsd"], env=env, capture_output=True, text=True)
        check("helper runs under system Bash 3.2", result.returncode == 0 and "bsd" in json.loads(config.read_text())["provider"]["p"]["models"])

    gate_text = (scripts / "run-review.sh").read_text()
    gate = gate_text.split("# 5c-ter. Resolve", 1)[1].split("# 5g. Probe", 1)[0]
    gate = "# 5c-ter. Resolve" + gate
    local_text = (scripts / "local-review.sh").read_text()
    local = "# Resolve the selected provider" + local_text.split("# Resolve the selected provider", 1)[1].split("if ! command -v jq", 1)[0]
    root_assignment = next(line for line in local_text.splitlines() if line.startswith('REPO_ROOT="'))
    eval_text = (scripts / "eval/run-evals.sh").read_text()
    evaluation = eval_text.split('if [ "$SELFTEST" != "1" ]; then', 1)[1].split('\necho "=========================================="', 1)[0]
    evaluation = 'if [ "$SELFTEST" != "1" ]; then' + evaluation
    workflow = yaml.safe_load((repo / ".github/workflows/pipeline-ai-analyse.yml").read_text())
    steps = workflow["jobs"]["analyse"]["steps"]
    resolve_index = next(i for i, step in enumerate(steps) if step["name"] == "Resolve provider/model chain")
    initialize_index = next(i for i, step in enumerate(steps) if step["name"] == "Initialize OPENCODE")
    check("analyse resolves in a preceding workflow step", resolve_index < initialize_index)
    resolve = steps[resolve_index]["run"]
    initialize = steps[initialize_index]["run"]

    def integration(name, kind, *, override=False, native=False, project=False,
                    analyse_provider="", analyse_model="", older=False, legacy=False,
                    health=0, helper_failure=False, selftest=False, wrong_family=False):
        case = root / name
        workspace = case / "consumer"
        workspace.mkdir(parents=True)
        skill = case / "tooling/node_modules/package/.agents/skills/ai-review-report"
        lib = skill / "scripts/lib"
        lib.mkdir(parents=True)
        assets = skill / "assets"
        assets.mkdir()
        shutil.copyfile(scripts.parent / "assets/opencode.json", assets / "opencode.json")
        original_builtin = (assets / "opencode.json").read_bytes()
        for filename in ("prepare-opencode-config.sh", "resolve-provider.sh", "quarantine-project-config.sh", "gh-retry.sh"):
            shutil.copyfile(scripts / "lib" / filename, lib / filename)
        shutil.copyfile(helper, lib / "ensure-opencode-models.real.sh")
        if not older:
            write(lib / "ensure-opencode-models.sh", f'''#!{bash}
printf 'register:%s\\n' "$2" >> "$TRACE"
{'exit 99' if helper_failure else 'exec "$TEST_BASH" "$(dirname "$0")/ensure-opencode-models.real.sh" "$@"'}
''')
        write(lib / "install-opencode.sh", f"#!{bash}\nexit 0\n")
        write(lib / "opencode-health.sh", f'''#!{bash}
opencode run || exit 1
exit "${{HEALTH_RC:-0}}"
''')
        if legacy:
            (lib / "prepare-opencode-config.sh").unlink()
            write(lib / "setup-opencode-config.sh", f"#!{bash}\nexit 0\n")
        custom = workspace / ".github/custom.json"
        custom.parent.mkdir()
        shape = "providers" if native else "provider"
        custom.write_text(json.dumps({shape: {"openai": {"models": {"keep": {"options": {"apiKey": "{env:KEEP}"}}}}, "anthropic": {}}}))
        original_source = custom.read_bytes()
        if project:
            (workspace / "opencode.json").symlink_to(".github/custom.json")
        trace = case / "trace"
        case_bin = case / "bin"
        case_bin.mkdir()
        write(case_bin / "opencode", f'''#!{bash}
if [ "${{1:-}}" = --version ]; then echo 2.0.29; exit 0; fi
if [ "${{1:-}}" = service ]; then echo stop >> "$TRACE"; exit 0; fi
if [ -n "${{OPENCODE_CONFIG:-}}" ]; then
  if ! jq -e --argjson expected "$EXPECTED_MODELS" '
    . as $config | all($expected[]; . as $m |
      ($config.providers[$m[0]].models // $config.provider[$m[0]].models // {{}}) | has($m[1]))
  ' "$OPENCODE_CONFIG" >/dev/null; then
    echo bad-config >> "$TRACE"; exit 92
  fi
elif [ "$EXPECTED_MODELS" != '[]' ]; then
  echo missing-config >> "$TRACE"; exit 93
fi
if [ "$EXPECT_STANDIN" = 1 ] && ! cmp -s "$OPENCODE_CONFIG" "$GITHUB_WORKSPACE/opencode.json"; then
  echo stale-standin >> "$TRACE"; exit 94
fi
echo "$1" >> "$TRACE"
echo OK
''')
        expected = [["openai", "primary-future"], ["openai", "secondary-future"]]
        if kind != "analyse":
            expected.append(["openai", "orch-future"])
        if analyse_model:
            expected.append(["anthropic" if analyse_provider == "ANTHROPIC" else "openai", analyse_model])
        if older or legacy or helper_failure or selftest:
            expected = []
        case_env = dict(env, PATH=f"{case_bin}:{bin_dir}", HOME=str(case / "home"),
                        XDG_CONFIG_HOME=str(case / "xdg-config"), XDG_DATA_HOME=str(case / "xdg-data"),
                        TRACE=str(trace), GITHUB_ENV=str(case / "github-env"), GITHUB_PATH=str(case / "github-path"),
                        GITHUB_WORKSPACE=str(workspace), REVIEW_SKILL_DIR=str(skill),
                        LIB_DIR=str(lib), SCRIPT_DIR=str(skill / "scripts"), SKILL_SCRIPTS_DIR=str(skill / "scripts"),
                        REPO_ROOT=str(workspace), OPENCODE_REVIEW_REPORT_REPO_ROOT=str(workspace),
                        GITHUB_ACTIONS="true" if kind != "local" else "false", HEALTH_RC=str(health),
                        OPENCODE_REVIEW_REPORT_PROVIDER="ANTHROPIC" if wrong_family else "OPENAI",
                        OPENCODE_REVIEW_REPORT_OPENAI_URL="https://gateway.example/v1", OPENCODE_OPENAI_API_KEY="fixture-key",
                        OPENCODE_ANTHROPIC_API_KEY="fixture-key", OPENCODE_MODEL="primary-future",
                        OPENCODE_REVIEW_REPORT_MODEL_PRIMARY="primary-future",
                        OPENCODE_REVIEW_REPORT_MODEL_SECONDARY="secondary-future",
                        OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR="orch-future",
                        OPENCODE_ANALYSE_PROVIDER=analyse_provider, OPENCODE_ANALYSE_MODEL=analyse_model,
                        OPENCODE_REVIEW_REPORT_DECISIONS_MODEL="never-register-decisions",
                        OPENCODE_REVIEW_REPORT_CONFIG=".github/custom.json" if override else "",
                        EXPECTED_MODELS=json.dumps(expected), EXPECT_STANDIN="1" if project and kind != "local" and not legacy else "0",
                        SELFTEST="1" if selftest else "0", REVIEW_SCRIPT=str(helper),
                        DR_STANDARDS_BASE_SRC=str(helper), DR_SUPPLEMENT_SRC=str(helper))
        Path(case_env["HOME"]).mkdir()
        (workspace / "ci_temp").mkdir()
        if kind == "analyse":
            resolver = case / "resolve.sh"
            write(resolver, resolve)
            result = command(resolver, [], case_env, workspace)
            if wrong_family:
                check(name + ": family error remains fatal before initialization", result.returncode != 0 and not trace.exists())
                return
            assert result.returncode == 0, result.stderr
            # Simulate Actions step transfer as data, never shell-source env files.
            for line in Path(case_env["GITHUB_ENV"]).read_text().splitlines():
                key, value = line.split("=", 1)
                case_env[key] = value
            assert case_env["OPENCODE_REVIEW_REPORT_PROVIDER_ID"] == "openai"
            program = initialize
        else:
            program = gate if kind == "gate" else (root_assignment + "\n" + local if kind in ("local", "npm") else evaluation)
        # The gate's real trap is outside its initialization block; supply its
        # existing restoration contract, not alternate initialization logic.
        prefix = 'set -euo pipefail\ndie() { echo "$*" >&2; exit 1; }\n'
        suffix = '\nif declare -F restore_project_config >/dev/null; then restore_project_config; fi\n'
        driver = case / "initialize.sh"
        write(driver, prefix + program + suffix)
        result = command(driver, [], case_env, workspace)
        lines = trace.read_text().splitlines() if trace.exists() else []
        assert not any(line in ("bad-config", "missing-config", "stale-standin") for line in lines), (name, lines, result.stderr)
        if wrong_family:
            check(name + ": resolver failure not swallowed", result.returncode != 0 and not lines)
            return
        if health == 3 or (health and kind in ("local", "npm", "eval")):
            check(name + ": health failure remains fatal", result.returncode != 0)
            return
        assert result.returncode == 0, (name, result.stdout, result.stderr)
        expected_batches = [] if older or selftest else ["register:openai"]
        if analyse_model and not older and not selftest:
            expected_batches.append("register:anthropic" if analyse_provider == "ANTHROPIC" else "register:openai")
        check(name + ": exact registration batches", [line for line in lines if line.startswith("register:")] == expected_batches)
        service = [line for line in lines if not line.startswith("register:")]
        expected_service = [] if selftest else (["run"] if kind in ("local", "npm") else (["stop", "run"] if kind == "eval" else ["stop", "stats", "run"]))
        check(name + ": registered before single service/model phase", service == expected_service and (not expected_batches or lines[:len(expected_batches)] == expected_batches))
        check(name + ": custom source untouched", custom.read_bytes() == original_source)
        check(name + ": built-in source untouched", (assets / "opencode.json").read_bytes() == original_builtin)
        check(name + ": original tree restored/no stand-in invented", (workspace / "opencode.json").is_symlink() if project else not (workspace / "opencode.json").exists())
        resolved = workspace / "ci_temp/opencode.resolved.json"
        if resolved.exists() and not older and not helper_failure:
            document = json.loads(resolved.read_text())
            registered = document.get("providers", document.get("provider"))
            check(name + ": decisions never registered", all("never-register-decisions" not in p.get("models", {}) for p in registered.values()))
            if kind == "analyse":
                check(name + ": unused orchestrator not registered", "orch-future" not in registered["openai"].get("models", {}))
        if older:
            check(name + ": older helper absence warned", "registration unavailable" in result.stderr)
        if legacy and not older:
            check(name + ": missing legacy config path stays advisory", "readable regular file" in result.stderr or "are required" in result.stderr)
        return case_env, workspace, lib, resolved

    integration("gate-builtin", "gate")
    case_env, workspace, lib, resolved = integration("gate-native-override", "gate", override=True, native=True, project=True)
    # Exercise the exact Step 6 restore/checkout/re-quarantine production block.
    cycle = gate_text.split('  restore_project_config\n', 1)[1].split('\nfi\n', 1)[0]
    cycle = "restore_project_config\n" + cycle
    write(Path(case_env["PATH"].split(":")[0]) / "git", f'''#!{bash}
[ "$1" = checkout ] && [ -L "$GITHUB_WORKSPACE/opencode.json" ] || exit 97
rm "$GITHUB_WORKSPACE/opencode.json"
echo '{{"new-head":true}}' > "$GITHUB_WORKSPACE/opencode.json"
''')
    driver = workspace.parent / "cycle.sh"
    write(driver, f'''#!{bash}
set -euo pipefail
export OPENCODE_CONFIG="{resolved}"
. "{lib}/quarantine-project-config.sh"
quarantine_project_config "$GITHUB_WORKSPACE"
{cycle}
cmp "$OPENCODE_CONFIG" "$GITHUB_WORKSPACE/opencode.json"
restore_project_config
''')
    result = command(driver, [], case_env, workspace)
    check("Step 6 cycle uses updated config and restores new head", result.returncode == 0 and json.loads((workspace / "opencode.json").read_text()) == {"new-head": True})
    integration("local-keeps-root", "local", override=True, project=True)
    integration("npm-out-of-tree", "npm", override=True, project=True)
    integration("analyse-default", "analyse")
    integration("analyse-different-provider", "analyse", override=True, native=True, project=True, analyse_provider="ANTHROPIC", analyse_model="claude-future")
    integration("analyse-same-provider", "analyse", override=True, analyse_provider="OPENAI", analyse_model="analyse-future")
    integration("analyse-inherits", "analyse", analyse_provider="ANTHROPIC")
    integration("analyse-old-helper", "analyse", older=True)
    integration("analyse-old-installer", "analyse", older=True, legacy=True)
    integration("analyse-legacy-no-path", "analyse", legacy=True)
    integration("eval-default", "eval")
    integration("eval-selftest", "eval", selftest=True)
    integration("gate-advisory-health", "gate", health=1)
    integration("analyse-advisory-health", "analyse", health=1)
    integration("gate-binding-fatal", "gate", health=3)
    integration("analyse-binding-fatal", "analyse", health=3)
    integration("local-health-fatal", "local", health=1)
    integration("gate-family-fatal", "gate", wrong_family=True)
    integration("analyse-family-fatal", "analyse", wrong_family=True)
    integration("gate-helper-fails", "gate", helper_failure=True)

print(f"Runtime model registration: {passed} assertions passed")
PY
