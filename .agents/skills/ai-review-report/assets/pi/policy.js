// LADR-127: pi's role lockdown. pi has no declarative permission language, so
// every tool call is decided here against the shared role contract. Decisions
// use resolved real paths and the contract only — never prompt content. Fail
// closed whenever the role, contract or workspace root cannot be read.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const CONTRACT_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "role-contract.json",
);

// pi tool name -> contract tool class
const CLASS_OF = {
  read: "read",
  find: "find",
  ls: "list",
  glob: "glob",
  edit: "edit",
  write: "write",
  grep: "content-search",
  bash: "shell",
  codemode: "network",
  tool_search: "unknown",
};

const PATH_INPUT_KEYS = ["path", "file", "filePath", "target"];

function loadContract() {
  try {
    return JSON.parse(fs.readFileSync(CONTRACT_PATH, "utf8"));
  } catch {
    return null;
  }
}

function globToRegex(glob) {
  const absolute = glob.startsWith("/");
  const escaped = glob
    .replace(/[.+^${}()|\\]/g, "\\$&")
    .replace(/\*\*/g, "\u0000")
    .replace(/\*/g, "[^]*")
    .replace(/\u0000/g, "[^]*")
    .replace(/\?/g, "[^/]");
  // A relative pattern matches the name at any depth, so a nested `.git/…`
  // cannot slip past a `.git/**` deny.
  return absolute ? new RegExp(`^${escaped}$`) : new RegExp(`(^|/)${escaped}$`);
}

function matchedPatterns(patterns, relative, absolute) {
  if (!Array.isArray(patterns)) return [];
  return patterns.filter((p) => {
    const re = globToRegex(p);
    if (p.startsWith("/")) return re.test(absolute) || re.test(relative);
    return re.test(relative) || re.test(path.basename(relative)) || re.test(absolute);
  });
}

function resolvePath(root, input) {
  const raw = typeof input === "string" ? input : "";
  if (!raw) return null;
  const expanded = raw.startsWith("~/") ? path.join(os.homedir(), raw.slice(2)) : raw;
  let candidate = path.isAbsolute(expanded) ? expanded : path.resolve(root, expanded);
  try {
    candidate = fs.realpathSync(candidate);
  } catch {
    let parent = path.dirname(candidate);
    const tail = [path.basename(candidate)];
    while (!fs.existsSync(parent) && path.dirname(parent) !== parent) {
      tail.unshift(path.basename(parent));
      parent = path.dirname(parent);
    }
    try {
      candidate = path.join(fs.realpathSync(parent), ...tail);
    } catch {
      return null;
    }
  }
  return candidate;
}

function withinRoot(root, resolved) {
  if (resolved === root) return true;
  return resolved.startsWith(root.endsWith(path.sep) ? root : root + path.sep);
}

function block(reason) {
  return { block: true, reason };
}

export default function policy(pi) {
  pi.on("tool_call", async (event) => {
    const role = process.env.PI_ROLE || "";
    const rootRaw = process.env.PI_WORKSPACE_ROOT || "";
    const contract = loadContract();
    if (!role || !rootRaw || !contract || !contract.roles[role]) {
      return block("policy: role, workspace root or role contract unavailable");
    }
    let root;
    try {
      root = fs.realpathSync(rootRaw);
    } catch {
      return block("policy: workspace root cannot be resolved");
    }

    const name = String(event && event.toolName ? event.toolName : "");
    const cls = CLASS_OF[name] || (name.startsWith("mcp__") ? "mcp" : "unknown");
    const roleDef = contract.roles[role];

    if (cls === "content-search") {
      return block(`policy: content search is ${contract.contentSearch}`);
    }
    if (!roleDef.allowedTools.includes(cls)) {
      return block(`policy: tool "${name}" is not allowed for role ${role}`);
    }

    const input = (event && event.input) || {};
    const rawPath = PATH_INPUT_KEYS.map((k) => input[k]).find((v) => typeof v === "string" && v);
    const resolved = resolvePath(root, rawPath || ".");
    if (!resolved) {
      return block(`policy: path "${rawPath || ""}" cannot be resolved`);
    }
    if (!withinRoot(root, resolved)) {
      return block(`policy: path "${resolved}" is outside the workspace root`);
    }
    const relative = path.relative(root, resolved) || ".";
    // Decide on the resolved target AND the path as written: a symlink whose
    // name is protected (`.env`) stays denied even when it targets a benign file.
    const rawExpanded = (rawPath || ".").startsWith("~/")
      ? path.join(os.homedir(), (rawPath || ".").slice(2))
      : (rawPath || ".");
    const logicalAbs = path.isAbsolute(rawExpanded) ? rawExpanded : path.resolve(root, rawExpanded);
    if (!withinRoot(root, logicalAbs)) {
      return block(`policy: path "${logicalAbs}" is outside the workspace root`);
    }
    const relativeLogical = path.relative(root, logicalAbs) || ".";

    const classDef = cls === "edit" ? roleDef.edit : roleDef.read;
    const denyHits = [
      ...matchedPatterns(classDef.denyPaths, relative, resolved),
      ...matchedPatterns(classDef.denyPaths, relativeLogical, logicalAbs),
    ];
    // A missing deny list is a contract fault, not "everything allowed".
    if (!Array.isArray(classDef.denyPaths) || classDef.denyPaths.length === 0) {
      return block(`policy: deny list missing for ${cls} (role ${role})`);
    }
    if (denyHits.length > 0) {
      // The allow list only excuses credential patterns; a structural deny
      // (.git, tooling, context, temp, "*") is never overridden, and the
      // exception does not apply inside a VCS tree.
      const structural = denyHits.some((p) => !/^\.env(\.|$)/.test(p));
      const underVcs = relative.split(path.sep).includes(".git")
        || relativeLogical.split(path.sep).includes(".git");
      // The exception must hold for the resolved target too, so an
      // `.env.example` symlink cannot expose a different protected file.
      const allowLogical = matchedPatterns(classDef.allowPaths || [], relativeLogical, logicalAbs);
      const allowResolved = matchedPatterns(classDef.allowPaths || [], relative, resolved);
      if (!structural && !underVcs && allowLogical.length > 0 && allowResolved.length > 0) {
        return undefined;
      }
      return block(`policy: ${cls} on "${relative}" is denied for role ${role}`);
    }
    return undefined;
  });
}
