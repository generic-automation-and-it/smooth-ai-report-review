#!/usr/bin/env bash
# Harness for scripts/install-skills.sh and, when pwsh is present, scripts/install-skills.ps1.
#
#   bash scripts/test-install-skills.sh
#
# No network: the clone source is a fixture repository built from this checkout's working tree (so
# uncommitted skill changes are what gets installed). Every case runs in a throwaway directory with HOME
# pointed at a scratch home and every tool location variable cleared, so a red run cannot touch the
# operator's real ~/.claude, ~/.codex, ~/.config/opencode or ~/.smooth-ai-review.
#
# The bash port runs under /bin/bash, which is 3.2 on macOS — the floor the installer promises.
# The ps1 cases and the cross-port parity cases are skipped with a stated reason when pwsh is absent
# (as on the ubuntu-latest gate runner); SKILLS_TEST_SKIP_PS1=1 skips them on purpose.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer_sh="$repo_root/scripts/install-skills.sh"
installer_ps1="$repo_root/scripts/install-skills.ps1"
bash_bin=/bin/bash
[ -x "$bash_bin" ] || bash_bin="$(command -v bash)"

scratch="$(mktemp -d)"
scratch="$(cd -P "$scratch" && pwd)"
trap 'rm -rf "$scratch"' EXIT

passed=0
failed=0
skipped=0
have_pwsh=0
if [ -z "${SKILLS_TEST_SKIP_PS1:-}" ] && command -v pwsh >/dev/null 2>&1; then have_pwsh=1; fi

ok() { passed=$((passed + 1)); echo "  ok   $1"; }
no() { failed=$((failed + 1)); echo "  FAIL $1"; [ -z "${2:-}" ] || echo "       $2"; }
skip() { skipped=$((skipped + 1)); echo "  skip $1 ($2)"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

# ---------------------------------------------------------------------------
# Fixture clone source: this checkout's .agents/skills, committed on main.
# ---------------------------------------------------------------------------
source_repo="$scratch/source"
mkdir -p "$source_repo/.agents"
cp -R "$repo_root/.agents/skills" "$source_repo/.agents/skills"
find "$source_repo" -type d -name __pycache__ -prune -exec rm -rf {} +
git -C "$source_repo" init -q -b main
git -C "$source_repo" -c user.name=t -c user.email=t@t add -A
git -C "$source_repo" -c user.name=t -c user.email=t@t commit -q -m fixture

# run PORT DIR [ARGS...] — run one port from DIR with a pinned, empty environment. Output in $scratch/out.
run() {
  local port="$1" dir="$2"; shift 2
  local cmd
  if [ "$port" = sh ]; then cmd=("$bash_bin" "$installer_sh"); else cmd=(pwsh -NoProfile -NonInteractive -File "$installer_ps1"); fi
  (cd "$dir" && env -u SKILLS_ROOT -u SMOOTH_AI_REVIEW_HOME -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u XDG_CONFIG_HOME \
    HOME="$scratch/home-$port" SKILLS_REPO="$source_repo" SKILLS_BRANCH=main "${RUN_ENV[@]+"${RUN_ENV[@]}"}" \
    "${cmd[@]}" "$@") >"$scratch/out" 2>&1
}
RUN_ENV=()

# new_repo NAME [SKILLS_DIR] — a git work tree with an empty skills folder; echoes its path.
new_repo() {
  local dir="$scratch/repos/$1"
  rm -rf "$dir"
  mkdir -p "$dir/${2:-.agents/skills}"
  git -C "$dir" init -q
  printf '%s\n' "$dir"
}

flags() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join("%s=%s" % (s["name"], str(s["installed"]).lower()) for s in d["skills"]))' "$1"
}

tree_listing() { (cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort); }

# ---------------------------------------------------------------------------
# Repo-level guarantees
# ---------------------------------------------------------------------------
echo "== repo"

links_in_source="$(find "$repo_root/.agents/skills" -type l | wc -l | tr -d ' ')"
check "skills ship no symlinks (installed copies stay self-contained)" "0" "$links_in_source"

owned_sh="$(grep -E '^OWNED_(CORE|OPTIONAL)=' "$installer_sh" | sed -E 's/^OWNED_([A-Z]+)=\((.*)\)$/\1 \2/')"
owned_ps1="$(grep -E '^\$Owned(Core|Optional) = ' "$installer_ps1" | sed -E "s/^\\\$Owned([A-Za-z]+) = @\((.*)\)$/\1 \2/" | tr -d "',")"
check "owned lists match across ports" "$(printf '%s\n' "$owned_sh" | tr 'a-z' 'A-Z')" "$(printf '%s\n' "$owned_ps1" | tr 'a-z' 'A-Z')"
for name in $(printf '%s\n' "$owned_sh" | cut -d' ' -f2-); do
  [ -f "$repo_root/.agents/skills/$name/SKILL.md" ] || no "owned skill $name exists in .agents/skills"
done
ok "every owned skill exists in .agents/skills"

# Whole-token, case-sensitive ownership (A3), both ports.
owned_cases="ai-review ai-review-report AI-REVIEW ai-review-x ai ../ai-review ai-review/x"
expect_owned="1 1 0 0 0 0 0"
got_sh="$("$bash_bin" -c "$(sed -n '/^OWNED_CORE=/p;/^OWNED_OPTIONAL=/p;/^is_owned_skill() {/,/^}/p' "$installer_sh")
for n in $owned_cases; do if is_owned_skill \"\$n\"; then printf '1 '; else printf '0 '; fi; done")"
check "sh: ownership is whole-token and case-sensitive" "$expect_owned" "${got_sh% }"
if [ "$have_pwsh" = 1 ]; then
  got_ps1="$(OWNED_CASES="$owned_cases" pwsh -NoProfile -NonInteractive -Command "
$(grep -E '^\$Owned(Core|Optional) = ' "$installer_ps1")
$(sed -n '/^function Test-OwnedSkill {/,/^}/p' "$installer_ps1")
(\$env:OWNED_CASES -split ' ' | ForEach-Object { if (Test-OwnedSkill \$_) { '1' } else { '0' } }) -join ' '")"
  check "ps1: ownership is whole-token and case-sensitive" "$expect_owned" "$got_ps1"
fi

# resolve-repo-root.sh: which repo local-review.sh reviews.
lib="$repo_root/.agents/skills/ai-review-report/scripts/lib/resolve-repo-root.sh"
rr_repo="$(new_repo rr)"
mkdir -p "$rr_repo/.agents/skills/ai-review-report/scripts"
store_scripts="$scratch/rr-store/skills/ai-review-report/scripts"
mkdir -p "$store_scripts"
rr_repo_p="$(cd -P "$rr_repo" && pwd)"
check "resolve-repo-root: an in-repo skill reviews its own repo" "$rr_repo_p" \
  "$(cd "$scratch" && "$bash_bin" -c '. "$1"; resolve_review_repo_root "$2"' _ "$lib" "$rr_repo/.agents/skills/ai-review-report/scripts")"
check "resolve-repo-root: a store install reviews the repo it is run from" "$rr_repo_p" \
  "$(cd "$rr_repo" && "$bash_bin" -c '. "$1"; resolve_review_repo_root "$2"' _ "$lib" "$store_scripts")"
if (cd "$scratch/rr-store" && GIT_CEILING_DIRECTORIES="$scratch" "$bash_bin" -c '. "$1"; resolve_review_repo_root "$2"' _ "$lib" "$store_scripts") >/dev/null 2>&1; then
  no "resolve-repo-root: outside any work tree it fails"
else
  ok "resolve-repo-root: outside any work tree it fails"
fi
grep -q '^REPO_ROOT="${OPENCODE_REVIEW_REPORT_REPO_ROOT:-$(resolve_review_repo_root "$SCRIPT_DIR")}"$' \
  "$repo_root/.agents/skills/ai-review-report/scripts/local-review.sh" \
  && ok "local-review.sh resolves REPO_ROOT through the lib, override first" \
  || no "local-review.sh resolves REPO_ROOT through the lib, override first"

# ---------------------------------------------------------------------------
# Per-port contract
# ---------------------------------------------------------------------------
port_cases() {
  local p="$1" r out m before after

  echo "== $p: per-repo"

  r="$scratch/repos/$p-noroot"; mkdir -p "$r"; git -C "$r" init -q
  if run "$p" "$r"; then no "$p: no skills folder fails"; else
    check "$p: no skills folder fails and creates nothing" "" "$(ls -A "$r" | grep -v '^\.git$' || true)"
  fi

  r="$(new_repo "$p-first")"
  run "$p" "$r" || no "$p: first install exits 0" "$(cat "$scratch/out")"
  m="$r/.agents/skills/_smooth-ai-review-shared/installation.json"
  check "$p: first install records core on, optional off" \
    "ai-analyse=false ai-review=true ai-review-report=false git-commit-review-push=true" "$(flags "$m")"
  check "$p: only core skills land on disk" "_smooth-ai-review-shared ai-review git-commit-review-push" \
    "$(ls "$r/.agents/skills" | tr '\n' ' ' | sed 's/ $//')"
  check "$p: manifest keys in fixed order" "updated skills" \
    "$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))))' "$m")"
  python3 -c 'import json,sys,re; assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", json.load(open(sys.argv[1]))["updated"])' "$m" \
    && ok "$p: updated is ISO-8601 UTC" || no "$p: updated is ISO-8601 UTC"
  [ -x "$r/.agents/skills/ai-review/scripts/review-decisions.sh" ] && ok "$p: runtime scripts stay executable" \
    || no "$p: runtime scripts stay executable"

  # Idempotent (G2).
  before="$(tree_listing "$r/.agents/skills" | grep -v installation.json)"
  run "$p" "$r" || no "$p: re-run exits 0"
  after="$(tree_listing "$r/.agents/skills" | grep -v installation.json)"
  check "$p: a re-run converges" "$before" "$after"

  # -a turns the optional pair on, and it stays on.
  run "$p" "$r" -a || no "$p: -a exits 0" "$(cat "$scratch/out")"
  check "$p: -a turns the optional skills on" \
    "ai-analyse=true ai-review=true ai-review-report=true git-commit-review-push=true" "$(flags "$m")"
  printf 'stale\n' > "$r/.agents/skills/ai-review-report/stale.txt"
  run "$p" "$r" || no "$p: run without -a exits 0"
  check "$p: optional skills stay on and are refreshed without -a" "true|absent" \
    "$(python3 -c 'import json,sys; print(str({s["name"]: s["installed"] for s in json.load(open(sys.argv[1]))["skills"]}["ai-review-report"]).lower())' "$m")|$([ -e "$r/.agents/skills/ai-review-report/stale.txt" ] && echo present || echo absent)"

  # Pruning: what ships is what runs.
  out="$(cd "$r/.agents/skills" && find . \( -name AGENTS.md -o -name 'test-*' -o -name eval -o -name tests \
    -o -name __pycache__ -o -name run-regressions.sh -o -name requirements-test.txt \) | LC_ALL=C sort | tr '\n' ' ')"
  check "$p: AGENTS.md, tests, eval and test tooling are pruned" "" "$out"
  for f in ai-review-report/assets/opencode.json ai-review-report/assets/findings-schema.json \
    ai-review-report/scripts/local-review.sh ai-review-report/scripts/run-review.sh \
    ai-review-report/scripts/lib/resolve-repo-root.sh ai-analyse/SKILL.md ai-review/scripts/copilot-review.sh; do
    [ -f "$r/.agents/skills/$f" ] || no "$p: runtime file $f installed"
  done
  ok "$p: runtime files installed"
  out=""
  for f in $(cd "$r/.agents/skills" && grep -rhoE '(eval/)?lib/[A-Za-z0-9_.-]+\.(sh|py)' --include='*.sh' ai-review-report ai-analyse ai-review | grep -v '^eval/' | sort -u); do
    [ -f "$r/.agents/skills/ai-review-report/scripts/$f" ] || [ -f "$r/.agents/skills/ai-analyse/scripts/$f" ] || out="$out $f"
  done
  check "$p: every lib/ path an installed script names was installed" "" "$out"

  # installed:false keeps local edits (C1); unowned skills are never touched or listed (A1, A2).
  python3 - "$m" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["skills"]:
    if s["name"] == "git-commit-review-push":
        s["installed"] = False
d["skills"].append({"name": "local-skill", "installed": True})
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
  printf 'local edit\n' >> "$r/.agents/skills/git-commit-review-push/SKILL.md"
  mkdir -p "$r/.agents/skills/local-skill"; printf 'mine\n' > "$r/.agents/skills/local-skill/SKILL.md"
  run "$p" "$r" || no "$p: run with operator flags exits 0"
  check "$p: installed:false keeps a local edit" "local edit" "$(tail -n 1 "$r/.agents/skills/git-commit-review-push/SKILL.md")"
  check "$p: unowned entries drop out of the manifest" \
    "ai-analyse=true ai-review=true ai-review-report=true git-commit-review-push=false" "$(flags "$m")"
  check "$p: unowned skills are left untouched" "mine" "$(cat "$r/.agents/skills/local-skill/SKILL.md")"

  # A corrupt or empty manifest is a hard error and is never rewritten (B2).
  for content in '{not json' '' '   ' '[]'; do
    printf '%s' "$content" > "$m"
    if run "$p" "$r"; then no "$p: manifest [$content] fails"; else
      check "$p: manifest [$content] fails and is left as is" "$content" "$(cat "$m")"
    fi
  done

  # Root search order (G1).
  r="$(new_repo "$p-claude" .claude/skills)"
  run "$p" "$r" || no "$p: .claude/skills install exits 0"
  [ -f "$r/.claude/skills/ai-review/SKILL.md" ] && ok "$p: falls back to .claude/skills" || no "$p: falls back to .claude/skills"
  mkdir -p "$r/.agents/skills"
  run "$p" "$r" || true
  [ -f "$r/.agents/skills/ai-review/SKILL.md" ] && ok "$p: prefers .agents/skills" || no "$p: prefers .agents/skills"

  # A link at the skill path (the retired npm plugin's) is replaced; its target survives.
  r="$(new_repo "$p-link")"
  mkdir -p "$scratch/$p-cache/ai-review"; printf 'cached\n' > "$scratch/$p-cache/ai-review/SKILL.md"
  ln -s "$scratch/$p-cache/ai-review" "$r/.agents/skills/ai-review"
  run "$p" "$r" || no "$p: link replacement exits 0"
  check "$p: a link at the skill path becomes a real copy, target untouched" "dir|cached" \
    "$([ -L "$r/.agents/skills/ai-review" ] && echo link || echo dir)|$(cat "$scratch/$p-cache/ai-review/SKILL.md")"

  # Gate precedence warning.
  r="$(new_repo "$p-gate")"
  mkdir -p "$r/.github/workflows"
  printf 'jobs:\n  r:\n    uses: generic-automation-and-it/smooth-ai-report-review/.github/workflows/pipeline-code-review-report.yml@v2\n' \
    > "$r/.github/workflows/review.yml"
  run "$p" "$r"
  check "$p: no gate warning without the optional skills" "0" "$(grep -c 'reusable review gate' "$scratch/out" || true)"
  run "$p" "$r" -a
  check "$p: gate warning when ai-review-report lands beside a reusable-gate caller" "1" "$(grep -c 'reusable review gate' "$scratch/out" || true)"
  r="$(new_repo "$p-nogate")"
  run "$p" "$r" -a
  check "$p: no gate warning without a caller" "0" "$(grep -c 'reusable review gate' "$scratch/out" || true)"

  # Refusals (G3).
  r="$(new_repo "$p-refuse")"
  if [ "$p" = sh ]; then
    run sh "$r" --uninstall && no "$p: --uninstall without -g refused" || ok "$p: --uninstall without -g refused"
    run sh "$r" -x && no "$p: unknown option refused" || ok "$p: unknown option refused"
    run sh "$r" -g --uninstall -a && no "$p: -a with --uninstall refused" || ok "$p: -a with --uninstall refused"
  else
    run ps1 "$r" -Uninstall && no "$p: -Uninstall without -g refused" || ok "$p: -Uninstall without -g refused"
    run ps1 "$r" -g -Uninstall -a && no "$p: -a with -Uninstall refused" || ok "$p: -a with -Uninstall refused"
  fi
  RUN_ENV=(SKILLS_ROOT="$r/.agents/skills")
  run "$p" "$r" -g && no "$p: -g with SKILLS_ROOT refused" || ok "$p: -g with SKILLS_ROOT refused"
  RUN_ENV=(SMOOTH_AI_REVIEW_HOME=relative/store)
  run "$p" "$r" -g && no "$p: relative SMOOTH_AI_REVIEW_HOME refused" || ok "$p: relative SMOOTH_AI_REVIEW_HOME refused"
  RUN_ENV=()

  # A clone source with embedded credentials is refused before it is logged or cloned, and never echoed.
  for url in 'https://user:s3cr3t@example.invalid/x.git' 'https://s3cr3t@example.invalid/x.git' 'ssh://git:s3cr3t@example.invalid/x.git'; do
    RUN_ENV=(SKILLS_REPO="$url")
    if run "$p" "$r"; then no "$p: credential URL refused ($url)"; else
      check "$p: credential URL refused, secret never printed ($url)" "1|0" \
        "$(grep -c 'embeds credentials' "$scratch/out" || true)|$(grep -c 's3cr3t' "$scratch/out" || true)"
    fi
  done
  RUN_ENV=(SKILLS_REPO='ssh://git@example.invalid/x.git' GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='false')
  run "$p" "$r" || true
  check "$p: a user-only ssh URL is not treated as a credential" "0" "$(grep -c 'embeds credentials' "$scratch/out" || true)"
  RUN_ENV=()

  # Every skill switched off still completes and rewrites the manifest (an empty name list must not abort).
  r="$(new_repo "$p-alloff")"
  run "$p" "$r" || no "$p: all-off setup install"
  m="$r/.agents/skills/_smooth-ai-review-shared/installation.json"
  python3 - "$m" <<'EOF2'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["skills"]:
    s["installed"] = False
d["updated"] = "2000-01-01T00:00:00Z"
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF2
  if run "$p" "$r"; then
    check "$p: all skills off still reconciles and rewrites the manifest" \
      "ai-analyse=false ai-review=false ai-review-report=false git-commit-review-push=false|rewritten" \
      "$(flags "$m")|$(grep -q '2000-01-01' "$m" && echo stale || echo rewritten)"
  else
    no "$p: all skills off exits 0" "$(cat "$scratch/out")"
  fi

  echo "== $p: global"
  local home="$scratch/home-$p" store gm
  rm -rf "$home"; mkdir -p "$home/.claude" "$home/.codex/skills/.system"
  printf 'codex\n' > "$home/.codex/skills/.system/keep"
  mkdir -p "$home/.claude/skills/git-commit-review-push"; printf 'operator\n' > "$home/.claude/skills/git-commit-review-push/SKILL.md"
  store="$home/.smooth-ai-review"; gm="$store/installation.json"
  r="$(new_repo "$p-global")"

  run "$p" "$r" -g || no "$p: -g exits 0" "$(cat "$scratch/out")"
  check "$p: -g stores core skills" "ai-review git-commit-review-push" "$(ls "$store/skills" | tr '\n' ' ' | sed 's/ $//')"
  check "$p: -g links into present tools only" "$store/skills/ai-review|$store/skills/ai-review|absent" \
    "$(readlink "$home/.claude/skills/ai-review")|$(readlink "$home/.codex/skills/ai-review")|$([ -e "$home/.config/opencode" ] && echo present || echo absent)"
  check "$p: -g leaves a real folder at a link path alone" "operator" "$(cat "$home/.claude/skills/git-commit-review-push/SKILL.md")"
  check "$p: -g never touches Codex .system" "codex" "$(cat "$home/.codex/skills/.system/keep")"
  check "$p: -g writes no per-repo state" "" "$(ls -A "$r/.agents/skills")"
  check "$p: -g manifest keys in fixed order" "updated harnesses skills links" \
    "$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))))' "$gm")"
  check "$p: -g records each link once, enabled" "claude-code-skill:ai-review:True codex-skill:ai-review:True codex-skill:git-commit-review-push:True" \
    "$(python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
print(" ".join(sorted("%s:%s:%s" % (l["type"], os.path.basename(l["path"]), l["enabled"]) for l in d["links"])))' "$gm")"

  before="$(cat "$gm" | grep -v '"updated"')"
  run "$p" "$r" -g || no "$p: -g re-run exits 0"
  check "$p: -g re-run converges" "$before" "$(cat "$gm" | grep -v '"updated"')"

  # -a under -g: ai-review finds its sibling through the tool's skills folder.
  run "$p" "$r" -g -a || no "$p: -g -a exits 0"
  [ -f "$home/.codex/skills/ai-review/scripts/../../ai-review-report/scripts/lib/recommend-fix-skip.sh" ] \
    && ok "$p: -g -a: ai-review resolves ../../ai-review-report through the tool folder" \
    || no "$p: -g -a: ai-review resolves ../../ai-review-report through the tool folder"

  # A foreign link is never touched; an unrecorded store link is purged when its tool is turned off (D2–D4).
  ln -s "$scratch/elsewhere" "$home/.codex/skills/foreign"
  ln -s "$store/skills/ai-review" "$home/.codex/skills/unrecorded"
  python3 - "$gm" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["harnesses"]["codex"] = False
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
  run "$p" "$r" -g || no "$p: -g with codex off exits 0"
  check "$p: codex off removes every store link there, also unrecorded ones" "absent|absent|$scratch/elsewhere" \
    "$([ -L "$home/.codex/skills/ai-review" ] && echo present || echo absent)|$([ -L "$home/.codex/skills/unrecorded" ] && echo present || echo absent)|$(readlink "$home/.codex/skills/foreign")"
  check "$p: codex off keeps Claude wired and marks codex records disabled" "$store/skills/ai-review|False" \
    "$(readlink "$home/.claude/skills/ai-review")|$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(any(l["enabled"] for l in d["links"] if l["type"] == "codex-skill"))' "$gm")"

  # Uninstall removes exactly what was recorded, keeps store and flags; reinstall works (F8). A recorded
  # path that now holds a link to somewhere else is the operator's and stays.
  ln -s "$scratch/repointed" "$home/.codex/skills/ai-review"
  if [ "$p" = sh ]; then run sh "$r" -g --uninstall; else run ps1 "$r" -g -Uninstall; fi || no "$p: uninstall exits 0" "$(cat "$scratch/out")"
  check "$p: uninstall removes recorded links, keeps the rest" "absent|$scratch/elsewhere|$scratch/repointed|operator|present" \
    "$([ -L "$home/.claude/skills/ai-review" ] && echo present || echo absent)|$(readlink "$home/.codex/skills/foreign")|$(readlink "$home/.codex/skills/ai-review")|$(cat "$home/.claude/skills/git-commit-review-push/SKILL.md")|$([ -d "$store/skills/ai-review" ] && echo present || echo absent)"
  check "$p: uninstall clears links, keeps flags and harnesses" "0|false|ai-analyse=true ai-review=true ai-review-report=true git-commit-review-push=true" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("%d|%s" % (len(d["links"]), str(d["harnesses"]["codex"]).lower()))' "$gm")|$(flags "$gm")"
  run "$p" "$r" -g || no "$p: reinstall exits 0"
  check "$p: reinstall relinks" "$store/skills/ai-review" "$(readlink "$home/.claude/skills/ai-review")"

  # All skills off under -g with a tool turned off: still exits 0, still purges that tool's links.
  python3 - "$gm" <<'EOF2'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["skills"]:
    s["installed"] = False
d["harnesses"]["claude-code"] = False
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF2
  if run "$p" "$r" -g; then
    check "$p: -g with every skill off still purges a turned-off tool" "absent" \
      "$([ -L "$home/.claude/skills/ai-review" ] && echo present || echo absent)"
  else
    no "$p: -g with every skill off exits 0" "$(cat "$scratch/out")"
  fi

  printf '{oops' > "$gm"
  run "$p" "$r" -g && no "$p: corrupt global manifest fails" || check "$p: corrupt global manifest fails, file untouched" "{oops" "$(cat "$gm")"
}

port_cases sh
if [ "$have_pwsh" = 1 ]; then
  port_cases ps1
else
  skip "ps1 cases" "pwsh not available"
fi

# ---------------------------------------------------------------------------
# Cross-port parity: same inputs, same bytes (bar the timestamp)
# ---------------------------------------------------------------------------
echo "== parity"
if [ "$have_pwsh" = 1 ]; then
  for p in sh ps1; do
    rm -rf "$scratch/home-$p"; mkdir -p "$scratch/home-$p/.claude" "$scratch/home-$p/.codex" "$scratch/home-$p/.config/opencode"
    r="$(new_repo "parity-$p")"
    run "$p" "$r" -a || no "parity: $p per-repo"
    run "$p" "$r" -g -a || no "parity: $p global"
  done
  check "parity: per-repo manifests match" \
    "$(grep -v '"updated"' "$scratch/repos/parity-sh/.agents/skills/_smooth-ai-review-shared/installation.json")" \
    "$(grep -v '"updated"' "$scratch/repos/parity-ps1/.agents/skills/_smooth-ai-review-shared/installation.json")"
  check "parity: installed trees match" "$(tree_listing "$scratch/repos/parity-sh/.agents/skills")" "$(tree_listing "$scratch/repos/parity-ps1/.agents/skills")"
  check "parity: global manifests match (home paths normalised)" \
    "$(grep -v '"updated"' "$scratch/home-sh/.smooth-ai-review/installation.json" | sed "s#$scratch/home-sh#HOME#g")" \
    "$(grep -v '"updated"' "$scratch/home-ps1/.smooth-ai-review/installation.json" | sed "s#$scratch/home-ps1#HOME#g")"
else
  skip "parity cases" "pwsh not available"
fi

echo
echo "passed: $passed  failed: $failed  skipped: $skipped"
[ "$failed" -eq 0 ]
