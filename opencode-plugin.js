// opencode plugin: materialize the smooth-ai-review skills into the consuming
// repo's .agents/skills/ so opencode's native skill discovery (and every
// `.agents/skills/...` path referenced by the SKILL.md docs) finds them.
//
// Install (consuming repo's opencode.json):
//   { "plugin": ["@generic-automation-and-it/smooth-ai-review"] }
//
// Idempotent: runs on every opencode startup. A vendored (real-directory)
// copy of a skill always wins — this plugin never overwrites one.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SKILLS = ["ai-review-report", "ai-review", "ai-analyse", "git-commit-review-push"];
const EXCLUDE_MARKER = "# smooth-ai-review plugin (auto-managed skill links)";

export const SmoothAiReviewSkills = async ({ worktree, directory }) => {
  try {
    const pkgRoot = path.dirname(fileURLToPath(import.meta.url));
    const root = worktree || directory;
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
