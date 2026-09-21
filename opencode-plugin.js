// opencode plugin: materialize the smooth-ai-review skills into the consuming
// repo's .agents/skills/ so opencode's native skill discovery (and every
// `.agents/skills/...` path referenced by the SKILL.md docs) finds them.
//
// Install (consuming repo's opencode.json):
//   { "plugins": ["@generic-automation-and-it/smooth-ai-review"] }
//
// Idempotent: runs on every opencode startup. A vendored (real-directory)
// copy of a skill always wins — this plugin never overwrites one.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SKILLS = ["ai-review-report", "ai-review", "ai-analyse", "git-commit-review-push"];
const EXCLUDE_MARKER = "# smooth-ai-review plugin (auto-managed skill links)";

export async function materializeSkills(root) {
  try {
    const pkgRoot = path.dirname(fileURLToPath(import.meta.url));
    if (!root) return {};

    const destDir = path.join(root, ".agents", "skills");
    const linked = [];

    for (const name of SKILLS) {
      const src = path.join(pkgRoot, ".agents", "skills", name);
      if (!fs.existsSync(src)) continue;
      const dest = path.join(destDir, name);

      const stat = fs.lstatSync(dest, { throwIfNoEntry: false });
      if (stat?.isSymbolicLink()) {
        // Re-point if the link is stale (e.g. the package cache moved on update).
        if (path.resolve(path.dirname(dest), fs.readlinkSync(dest)) !== src) {
          fs.unlinkSync(dest);
        } else {
          linked.push(name);
          continue;
        }
      } else if (stat) {
        continue; // real dir/file — a vendored copy wins, never clobber
      }

      fs.mkdirSync(destDir, { recursive: true });
      // "junction" gives a directory link without admin rights on Windows;
      // on POSIX Node ignores the type and creates a normal dir symlink.
      fs.symlinkSync(src, dest, "junction");
      linked.push(name);
    }

    excludeFromGit(root, linked);
  } catch (err) {
    console.warn(`smooth-ai-review plugin: skill setup skipped: ${err.message}`);
  }
  return {};
}

// The v2 plugin contract is a default export of `{ id, setup(context) }`.
// `Plugin.define()` from @opencode/plugin is the TypeScript-facing helper for
// exactly this object and is `plugin => plugin` at runtime — so this package
// deliberately does NOT depend on it. This is a skill-distribution package:
// the consumer installs the opencode CLI themselves, and a dependency whose
// only job is an identity function would add an install that can fail (it
// pulls effect/zod/@ai-sdk and four optional peers) to a package that
// otherwise just creates four symlinks. Verified against opencode 2.0.11:
// a plain object literal loads identically.
export default {
  id: "smooth-ai-review.skills",
  async setup(ctx) {
    await materializeSkills(ctx?.location?.directory);
  },
};

// Keep `git status` clean without touching the consumer's .gitignore:
// .git/info/exclude is local-only and never committed.
function excludeFromGit(root, names) {
  const excludeFile = path.join(root, ".git", "info", "exclude");
  if (!fs.existsSync(path.dirname(excludeFile))) return;

  const existing = fs.existsSync(excludeFile)
    ? fs.readFileSync(excludeFile, "utf8")
    : "";
  const missing = names
    .map((name) => `/.agents/skills/${name}`)
    .filter((line) => !existing.split(/\r?\n/).includes(line));
  if (missing.length === 0) return;

  const block = existing.includes(EXCLUDE_MARKER)
    ? missing.join("\n") + "\n"
    : `${EXCLUDE_MARKER}\n${missing.join("\n")}\n`;
  const sep = existing === "" || existing.endsWith("\n") ? "" : "\n";
  fs.appendFileSync(excludeFile, sep + block);
}
