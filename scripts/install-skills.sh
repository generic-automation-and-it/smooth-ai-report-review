#!/bin/bash
# Skills installer for macOS/Linux (bash). PowerShell 7 port: install-skills.ps1 (same contract).
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/generic-automation-and-it/smooth-ai-report-review/main/scripts/install-skills.sh | bash
#
# Installs the review skills this repo owns into the repo you stand in (default) or, with -g, once per
# machine into ~/.smooth-ai-review, linked into Claude Code, Codex and OpenCode. Contract and rationale:
# scripts/SKILLS_INSTALLER.md. Requirement IDs (A1, B2, …) refer to smooth-devex-template's
# docs/wiki/installer-recipe.md.
#
#   core      ai-review, git-commit-review-push       installed by default
#   optional  ai-review-report, ai-analyse            only with -a (or installed:true in the manifest)
#
# The optional pair is opt-in because a per-repo copy of ai-review-report changes what the CI gate runs:
# pipeline-code-review-report.yml prefers a local .agents/skills/ai-review-report over the tooling it
# fetches at the pinned ref, so a vendored copy silently takes over the gate and drifts.
#
# Switches: -a include the optional skills, -g global install, --uninstall (needs -g), --help.
#
# The owned lists live in OWNED_CORE / OWNED_OPTIONAL below AND in install-skills.ps1;
# test-install-skills.sh holds the two ports to each other.
#
# Dependencies: bash (3.2+), git, python3 (JSON only).
#
# Environment overrides:
#   SKILLS_REPO          git URL or local path to clone from (default: the upstream GitHub repo)
#   SKILLS_BRANCH        branch or tag to clone (default: main; empty = the remote's default branch)
#   SKILLS_ROOT          force a per-repo skills root, skipping the search; refused with -g
#   SMOOTH_AI_REVIEW_HOME  the -g store (default ~/.smooth-ai-review; must be absolute)
#   CLAUDE_CONFIG_DIR / CODEX_HOME / XDG_CONFIG_HOME
#                        where -g finds each tool (~/.claude, ~/.codex, ~/.config/opencode)

set -euo pipefail

SKILLS_REPO="${SKILLS_REPO:-https://github.com/generic-automation-and-it/smooth-ai-report-review.git}"
# `-`, not `:-`: an explicitly empty SKILLS_BRANCH means "the remote's default branch".
SKILLS_BRANCH="${SKILLS_BRANCH-main}"

OWNED_CORE=(ai-review git-commit-review-push)
OWNED_OPTIONAL=(ai-review-report ai-analyse)

STATE_DIR_NAME="_smooth-ai-review-shared"
HARNESSES="claude-code codex opencode"

die() { echo "install-skills: $*" >&2; exit 1; }
log() { echo "install-skills: $*" >&2; }

usage() {
  cat <<'EOF'
Usage: install-skills.sh [-a] [-g [--uninstall]]

  (none)        install ai-review and git-commit-review-push into this repo's skills folder
                (.agents/skills, else .claude/skills, else .codex/skills)
  -a            also install ai-review-report and ai-analyse
  -g            install once into ~/.smooth-ai-review and link into Claude Code, Codex, OpenCode
  --uninstall   with -g: remove the links this installer made (the store is kept)

State: <skills-root>/_smooth-ai-review-shared/installation.json (per repo) or
~/.smooth-ai-review/installation.json (-g). Set a skill's "installed" to false to stop updating it.
EOF
}

# ---------------------------------------------------------------------------
# Owned set (A1–A3)
# ---------------------------------------------------------------------------

# Whole-token and case-sensitive: `ai-review` never matches `ai-review-report` or `AI-REVIEW`.
is_owned_skill() {
  local name
  case "$1" in '' | *[/\\]* | *..*) return 1 ;; esac
  for name in "${OWNED_CORE[@]}" "${OWNED_OPTIONAL[@]}"; do
    [ "$1" = "$name" ] && return 0
  done
  return 1
}

is_optional_skill() {
  local name
  for name in "${OWNED_OPTIONAL[@]}"; do
    [ "$1" = "$name" ] && return 0
  done
  return 1
}

# Owned folders carrying a SKILL.md under DIR, one per line, sorted.
list_owned_skills() {
  local dir="$1" entry name
  [ -d "$dir" ] || return 0
  for entry in "$dir"/*/; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    is_owned_skill "$name" || continue
    [ -f "$entry/SKILL.md" ] && printf '%s\n' "$name"
  done | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

DO_OPTIONAL=0
DO_GLOBAL=0
DO_UNINSTALL=0

parse_arguments() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -a) DO_OPTIONAL=1 ;;
      -g) DO_GLOBAL=1 ;;
      --uninstall) DO_UNINSTALL=1 ;;
      --help | -\?) usage; exit 0 ;;
      *) die "unknown option: $arg (use -a, -g, --uninstall, --help)" ;;
    esac
  done
  if [ "$DO_GLOBAL" = "0" ] && [ "$DO_UNINSTALL" = "1" ]; then
    die "--uninstall only applies to the global install — use: install-skills.sh -g --uninstall"
  fi
  if [ "$DO_UNINSTALL" = "1" ] && [ "$DO_OPTIONAL" = "1" ]; then
    die "-a has no meaning with --uninstall"
  fi
}

# ---------------------------------------------------------------------------
# Manifest (B1–B6)
# ---------------------------------------------------------------------------

# Prints the file's JSON, or nothing when it does not exist (a first install). An empty, whitespace-only
# or unparseable file is a hard error: reading it as a first install would re-enable every skill the
# operator switched off.
json_read() {
  python3 - "$1" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    raise SystemExit(0)
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except ValueError as exc:
    sys.stderr.write("install-skills: %s is not valid JSON (%s); fix or delete it - not treating it as a first install\n" % (path, exc))
    raise SystemExit(2)
if not isinstance(data, dict):
    sys.stderr.write("install-skills: %s is not a JSON object; fix or delete it - not treating it as a first install\n" % path)
    raise SystemExit(2)
print(json.dumps(data))
PYEOF
}

# reconcile_skills EXISTING_JSON CATALOG — the manifest's skills list. A new core skill joins as true and
# a new optional one as false (true with -a); the operator's flag is kept, false included; -a turns the
# optional skills on; names outside CATALOG (the owned union of source and disk) are dropped.
reconcile_skills() {
  python3 - "$1" "$2" "$DO_OPTIONAL" "${OWNED_OPTIONAL[*]}" <<'PYEOF'
import json, sys
raw, catalog, do_optional, optional = sys.argv[1], sys.argv[2], sys.argv[3] == "1", set(sys.argv[4].split())
known = {}
if raw.strip():
    for entry in json.loads(raw).get("skills", []) or []:
        if isinstance(entry, dict) and isinstance(entry.get("name"), str):
            known[entry["name"]] = bool(entry.get("installed", False))
out = []
for name in sorted(set(n for n in catalog.split() if n)):
    if name in optional and do_optional:
        flag = True
    elif name in known:
        flag = known[name]
    else:
        flag = name not in optional
    out.append({"name": name, "installed": flag})
print(json.dumps(out))
PYEOF
}

# reconcile_harnesses EXISTING_JSON — exactly the supported tools, in a fixed order (D1).
reconcile_harnesses() {
  python3 - "$1" "$HARNESSES" <<'PYEOF'
import json, sys
raw, names = sys.argv[1], sys.argv[2].split()
found = json.loads(raw).get("harnesses") if raw.strip() else None
found = found if isinstance(found, dict) else {}
print(json.dumps({n: bool(found.get(n, True)) for n in names}))
PYEOF
}

# json_field JSON EXPR — a small python read helper; EXPR sees the parsed document as `d`.
json_field() {
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
$2
" "$1"
}

installed_names() {
  json_field "$1" "
for s in d:
    if s.get('installed'):
        print(s['name'])"
}

harness_on() {
  [ "$(json_field "$1" "print(1 if d.get('$2', True) else 0)")" = "1" ]
}

# write_manifest PATH SKILLS_JSON [HARNESSES_JSON] — fixed key order, ISO-8601 UTC (B5, B6). For the
# global manifest LINKS (tab-separated "type path target" records) are merged into the recorded history
# by (type, path), and each record's `enabled` is recomputed from disk (D7).
LINKS=()
write_manifest() {
  local links=""
  if [ "${#LINKS[@]}" -gt 0 ]; then links="$(printf '%s\n' "${LINKS[@]}")"; fi
  python3 - "$1" "$2" "${3:-}" "$links" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
path, skills, harnesses, links_raw = sys.argv[1:5]
data = {"updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
if harnesses:
    data["harnesses"] = json.loads(harnesses)
data["skills"] = json.loads(skills)
if harnesses:
    merged, index = [], {}
    previous = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            previous = json.load(f)
    for rec in previous.get("links", []) or []:
        if isinstance(rec, dict):
            index[(rec.get("type"), rec.get("path"))] = len(merged)
            merged.append(rec)
    for line in links_raw.splitlines():
        if not line:
            continue
        kind, link, target = line.split("\t")
        rec = {"type": kind, "path": link, "detail": target}
        key = (kind, link)
        if key in index:
            merged[index[key]] = rec
        else:
            index[key] = len(merged)
            merged.append(rec)
    for rec in merged:
        p = rec.get("path", "")
        rec["enabled"] = os.path.islink(p) and os.readlink(p) == rec.get("detail")
    data["links"] = merged
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PYEOF
}

# ---------------------------------------------------------------------------
# Source clone and copy (G4)
# ---------------------------------------------------------------------------

INSTALL_TMP=""
cleanup() { [ -z "$INSTALL_TMP" ] || rm -rf "$INSTALL_TMP"; }
trap cleanup EXIT INT TERM HUP

# reject_credential_url URL — refuse a clone source that embeds a secret before it is logged or passed to
# git (argv is visible to other processes). Any userinfo on an http(s)/ftp(s) URL is a token or password;
# elsewhere only `user:password@` is. `ssh://git@host` and scp-style `git@host:path` carry no secret.
# The URL itself is never echoed.
reject_credential_url() {
  local scheme rest authority userinfo
  case "$1" in *://*) ;; *) return 0 ;; esac
  scheme="${1%%://*}"
  rest="${1#*://}"
  authority="${rest%%/*}"
  case "$authority" in *@*) ;; *) return 0 ;; esac
  userinfo="${authority%@*}"
  case "$(printf '%s' "$scheme" | tr 'A-Z' 'a-z')" in
    http | https | ftp | ftps) ;;
    *) case "$userinfo" in *:*) ;; *) return 0 ;; esac ;;
  esac
  die "SKILLS_REPO embeds credentials in its URL — remove them and authenticate with a git credential helper or 'gh auth login' instead"
}

clone_source() {
  local url="$SKILLS_REPO"
  reject_credential_url "$url"
  INSTALL_TMP="$(mktemp -d)"
  # git ignores --depth for a bare local path; file:// makes it apply.
  case "$url" in
    *://* | /*) ;;
    *) url="file://$PWD/$url" ;;
  esac
  case "$url" in /*) url="file://$url" ;; esac
  log "Cloning $SKILLS_REPO (${SKILLS_BRANCH:-default branch})…"
  if [ -n "$SKILLS_BRANCH" ]; then
    git -c core.symlinks=true clone --quiet --depth 1 --branch "$SKILLS_BRANCH" "$url" "$INSTALL_TMP/repo" >/dev/null 2>&1 \
      || die "failed to clone $SKILLS_REPO at '$SKILLS_BRANCH' (set SKILLS_BRANCH empty for the default branch)"
  else
    git -c core.symlinks=true clone --quiet --depth 1 "$url" "$INSTALL_TMP/repo" >/dev/null 2>&1 \
      || die "failed to clone $SKILLS_REPO"
  fi
  SOURCE_SKILLS="$INSTALL_TMP/repo/.agents/skills"
}

# prune_non_shippable DIR — an installed copy carries what runs, not how this repo develops or tests it:
# the skill's own AGENTS.md (A6, LADR history), test harnesses (test-*, tests/, run-regressions.sh,
# requirements-test.txt), the eval corpus (scripts/eval/) and interpreter output (__pycache__/).
# Matches the old npm package's exclusions plus the tests, as the sibling installers do.
prune_non_shippable() {
  local dest="$1"
  rm -f "$dest/AGENTS.md"
  rm -rf "$dest/scripts/eval" "$dest/tests"
  find "$dest" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  find "$dest" -type f \( -name 'test-*' -o -name 'run-regressions.sh' -o -name 'requirements-test.txt' \) -exec rm -f {} + 2>/dev/null || true
}

# install_skill NAME DEST_ROOT — replace DEST_ROOT/NAME with the source copy. A link at that path (the
# retired npm plugin linked skills into .agents/skills) is replaced by the copy; its target is untouched.
install_skill() {
  local name="$1" dest="$2/$1"
  is_owned_skill "$name" || { log "WARNING: $name is not owned here — left untouched"; return 0; }
  if [ ! -f "$SOURCE_SKILLS/$name/SKILL.md" ]; then
    log "WARNING: $name not found in $SKILLS_REPO — left untouched"
    return 0
  fi
  if [ -L "$dest" ]; then
    log "Replacing link $dest -> $(readlink "$dest") with an installed copy"
    rm -f "$dest"
  else
    rm -rf "$dest"
  fi
  cp -R "$SOURCE_SKILLS/$name" "$dest"
  prune_non_shippable "$dest"
  log "Updated $name"
}

# catalog_for DEST_ROOT — the owned union of what the source offers and what is already at DEST_ROOT.
catalog_for() {
  { list_owned_skills "$SOURCE_SKILLS"; list_owned_skills "$1"; } | LC_ALL=C sort -u | tr '\n' ' '
}

# ---------------------------------------------------------------------------
# Per-repo install (G1–G3)
# ---------------------------------------------------------------------------

find_skills_root() {
  local dir
  for dir in .agents/skills .claude/skills .codex/skills; do
    [ -d "$dir" ] && { printf '%s\n' "$dir"; return 0; }
  done
  return 1
}

# The reusable review gate and the analyse workflow prefer a local .agents/skills copy over the tooling
# they fetch at the pinned ref. Say so loudly when this run puts one there in a repo that calls them.
warn_gate_precedence() {
  local skills_root="$1" names="$2"
  case "$names" in *ai-review-report*) ;; *) return 0 ;; esac
  [ "$(cd "$skills_root" && pwd -P)" = "$(cd .agents/skills 2>/dev/null && pwd -P)" ] || return 0
  grep -qsE 'smooth-ai-report-review/\.github/workflows/pipeline-(code-review-report|ai-analyse)\.yml@' \
    .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null || return 0
  log "WARNING: .agents/skills/ai-review-report now exists, so the reusable review gate runs this copy"
  log "         instead of the tooling pinned by its @ref. Re-run with -a to keep it current, or set it"
  log "         installed:false and delete the folder to go back to the pinned tooling."
}

run_repo_install() {
  local skills_root manifest existing skills names
  if [ -n "${SKILLS_ROOT:-}" ]; then
    skills_root="$SKILLS_ROOT"
    [ -d "$skills_root" ] || die "SKILLS_ROOT '$skills_root' does not exist"
  else
    skills_root="$(find_skills_root)" \
      || die "no skills directory found — expected one of .agents/skills, .claude/skills, .codex/skills (create one, or set SKILLS_ROOT)"
  fi
  manifest="$skills_root/$STATE_DIR_NAME/installation.json"
  log "Skills root: $skills_root"

  existing="$(json_read "$manifest")" || die "cannot read $manifest — fix or delete it, then re-run"
  clone_source
  skills="$(reconcile_skills "$existing" "$(catalog_for "$skills_root")")"
  names="$(installed_names "$skills")"
  [ -n "$names" ] || log "No skills marked installed:true — nothing to update."
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    install_skill "$name" "$skills_root"
  done <<< "$names"
  warn_gate_precedence "$skills_root" "$names"

  # Written last (B3).
  mkdir -p "$skills_root/$STATE_DIR_NAME"
  write_manifest "$manifest" "$skills"
  log "Done. State: $manifest"
}

# ---------------------------------------------------------------------------
# Global install (-g): store + symlinks (D1–D7)
# ---------------------------------------------------------------------------

resolve_global_paths() {
  GLB_ROOT="${SMOOTH_AI_REVIEW_HOME:-$HOME/.smooth-ai-review}"
  case "$GLB_ROOT" in
    /*) ;;
    *) die "SMOOTH_AI_REVIEW_HOME must be an absolute path (got '$GLB_ROOT') — links into a relative store would dangle" ;;
  esac
  while [ "${GLB_ROOT%/}" != "$GLB_ROOT" ] && [ "$GLB_ROOT" != "/" ]; do GLB_ROOT="${GLB_ROOT%/}"; done
  GLOBAL_MANIFEST="$GLB_ROOT/installation.json"
}

tool_dir() {
  case "$1" in
    claude-code) printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    codex) printf '%s\n' "${CODEX_HOME:-$HOME/.codex}" ;;
    opencode) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode" ;;
  esac
}

# purge_store_links DIR — remove every symlink in DIR that points into the store, found on disk rather
# than from records, so a lost record cannot leave a live link (D3). Anything else is never touched (D4).
purge_store_links() {
  local dir="$1" link
  [ -d "$dir" ] || return 0
  for link in "$dir"/* "$dir"/.[!.]*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in
      "$GLB_ROOT/skills/"*) rm -f "$link"; log "Unlinked $link (tool turned off)" ;;
    esac
  done
}

# link_skill LINK TARGET TYPE — create only when nothing is there; keep and re-record a correct link.
link_skill() {
  local link="$1" target="$2" kind="$3"
  if [ -L "$link" ]; then
    if [ "$(readlink "$link")" = "$target" ]; then
      LINKS+=("$kind	$link	$target")
    else
      log "WARNING: $link is a link to somewhere else — left untouched"
    fi
    return 0
  fi
  if [ -e "$link" ]; then
    log "WARNING: $link already exists — left untouched"
    return 0
  fi
  mkdir -p "$(dirname "$link")"
  if ln -s "$target" "$link" 2>/dev/null; then
    LINKS+=("$kind	$link	$target")
    log "Linked $link -> $target"
  else
    log "WARNING: could not create $link -> $target — left untouched"
  fi
}

run_global_install() {
  local existing harnesses skills names tool dir name
  existing="$(json_read "$GLOBAL_MANIFEST")" || die "cannot read $GLOBAL_MANIFEST — fix or delete it, then re-run"
  mkdir -p "$GLB_ROOT/skills"
  clone_source

  harnesses="$(reconcile_harnesses "$existing")"
  skills="$(reconcile_skills "$existing" "$(catalog_for "$GLB_ROOT/skills")")"
  names="$(installed_names "$skills")"
  [ -n "$names" ] || log "No skills marked installed:true — nothing to update."
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    install_skill "$name" "$GLB_ROOT/skills"
  done <<< "$names"

  for tool in $HARNESSES; do
    dir="$(tool_dir "$tool")"
    if ! harness_on "$harnesses" "$tool"; then
      log "Tool $tool is off — removing what this installer linked"
      purge_store_links "$dir/skills"
      continue
    fi
    if [ ! -d "$dir" ]; then
      log "$tool not found ($dir) — skipped"
      continue
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      link_skill "$dir/skills/$name" "$GLB_ROOT/skills/$name" "$tool-skill"
    done <<< "$names"
  done

  write_manifest "$GLOBAL_MANIFEST" "$skills" "$harnesses"
  log "Done. State: $GLOBAL_MANIFEST"
}

# Remove exactly the recorded links that still point where recorded (F8); keep the store and the flags.
run_global_uninstall() {
  local existing records kind link target
  [ -f "$GLOBAL_MANIFEST" ] || { log "No global install at $GLOBAL_MANIFEST — nothing to uninstall"; return 0; }
  existing="$(json_read "$GLOBAL_MANIFEST")" || die "cannot read $GLOBAL_MANIFEST — fix or delete it, then re-run"
  records="$(json_field "$existing" "
for r in d.get('links', []) or []:
    print('%s\t%s\t%s' % (r.get('type', ''), r.get('path', ''), r.get('detail', '')))")"
  while IFS=$'\t' read -r kind link target; do
    [ -n "$link" ] || continue
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
      rm -f "$link"
      log "Removed $link"
    fi
  done <<< "$records"
  python3 - "$GLOBAL_MANIFEST" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
data["links"] = []
with open(path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
PYEOF
  log "Uninstalled — store left at $GLB_ROOT (delete it to reclaim space)"
}

main() {
  parse_arguments "$@"
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  if [ "$DO_GLOBAL" = "1" ]; then
    [ -z "${SKILLS_ROOT:-}" ] || die "-g cannot be combined with SKILLS_ROOT — the global install owns its own store"
    resolve_global_paths
    if [ "$DO_UNINSTALL" = "1" ]; then run_global_uninstall; else run_global_install; fi
    return 0
  fi
  run_repo_install
}

main "$@"
