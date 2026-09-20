#!/bin/bash
# Offline contract test for the npm package's OpenCode v2 plugin entrypoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "❌ $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "✅ $*"; }

PKG="$TMP/pkg"
CONSUMER="$TMP/consumer"
# Deliberately NO node_modules: the package must load with zero runtime
# dependencies (see the dependency-free assertion below).
mkdir -p "$PKG/.agents/skills" "$CONSUMER/.git/info"
cp "$REPO_ROOT/opencode-plugin.js" "$PKG/opencode-plugin.js"
cp "$REPO_ROOT/index.js" "$PKG/index.js"

cat > "$PKG/package.json" <<'JSON'
{"type":"module"}
JSON

for skill in ai-review-report ai-review ai-analyse git-commit-review-push; do
  mkdir -p "$PKG/.agents/skills/$skill"
done

node --input-type=module - "$PKG/index.js" "$CONSUMER" <<'JS'
import { pathToFileURL } from "node:url";
const [pluginPath, consumer] = process.argv.slice(2);
const loaded = await import(pathToFileURL(pluginPath));
if (loaded.default?.id !== "smooth-ai-review.skills") throw new Error("missing stable v2 plugin id");
if (typeof loaded.default?.setup !== "function") throw new Error("missing v2 setup(ctx)");
await loaded.default.setup({ location: { directory: consumer } });
JS

for skill in ai-review-report ai-review ai-analyse git-commit-review-push; do
  [ -L "$CONSUMER/.agents/skills/$skill" ] || fail "v2 setup did not link $skill"
done
ok "index.js default entrypoint materializes all four skills through setup(ctx), with no node_modules"

grep -q '# smooth-ai-review plugin' "$CONSUMER/.git/info/exclude" \
  || fail "v2 plugin did not maintain the local git exclude"
ok "v2 plugin keeps generated links out of git status"

# This package distributes SKILL FILES; the consumer installs the opencode CLI
# themselves. The v2 contract is a default-exported `{ id, setup(context) }`
# object — @opencode/plugin's `Plugin.define` is the TS-facing helper for that
# shape and is `plugin => plugin` at runtime, so depending on it would add a
# failable install (effect/zod/@ai-sdk plus four optional peers) that buys
# nothing and can only stop the four symlinks from being created. The
# materialization test above runs with no node_modules at all, which is the
# real proof; this pins the intent.
node --input-type=module - "$REPO_ROOT/package.json" <<'JS'
import fs from "node:fs";
const pkg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
for (const field of ["dependencies", "peerDependencies", "optionalDependencies"]) {
  const declared = Object.keys(pkg[field] ?? {});
  if (declared.length) {
    throw new Error(`${field} must stay empty, got: ${declared.join(", ")}`);
  }
}
JS
ok "package stays dependency-free (skills only; consumer owns the opencode CLI)"

# OpenCode v2 loads a plugin package by reading `<package>/index.js` and
# IGNORES package.json `main`/`exports`. Verified on 2.0.11: with the entry
# named opencode-plugin.js and no index.js, the plugin is skipped with no
# error and no log line — `opencode plugin list` just says "No plugins found",
# so the npm channel dies silently. Pin the entrypoint's existence, its
# re-export, and its presence in the published file list.
[ -f "$REPO_ROOT/index.js" ] \
  || fail "no index.js — opencode v2 resolves a plugin package by that filename only"
ok "package ships the index.js entrypoint v2 actually loads"

node --input-type=module - "$PKG/index.js" <<'JS'
import { pathToFileURL } from "node:url";
const loaded = await import(pathToFileURL(process.argv[2]));
if (loaded.default?.id !== "smooth-ai-review.skills") {
  throw new Error("index.js does not re-export the default v2 plugin");
}
if (typeof loaded.materializeSkills !== "function") {
  throw new Error("index.js does not re-export materializeSkills");
}
JS
ok "index.js re-exports the default plugin and materializeSkills"

node --input-type=module - "$REPO_ROOT/package.json" <<'JS'
import fs from "node:fs";
const [pkgPath] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
if (!pkg.files?.includes("index.js")) throw new Error("index.js missing from package files");
if (pkg.main !== "./index.js") throw new Error("main does not point at ./index.js");
JS
ok "index.js is published and is the declared main"

echo "All $pass OpenCode v2 plugin tests passed"
