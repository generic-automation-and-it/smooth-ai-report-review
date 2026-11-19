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
  const escaped = glob
    .replace(/[.+^${}()|\\]/g, "\\$&")
    .replace(/\*\*/g, "\u0000")
    .replace(/\*/g, "[^]*")
    .replace(/\u0000/g, "[^]*")
    .replace(/\?/g, "[^/]");
  return new RegExp(`^${escaped}$`);
}

function matchesAny(patterns, relative, absolute) {
  return patterns.some((p) => {
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

    const classDef = cls === "edit" ? roleDef.edit : roleDef.read;
    if (matchesAny(classDef.allowPaths || [], relative, resolved)) {
      return undefined;
    }
    if (matchesAny(classDef.denyPaths || [], relative, resolved)) {
      return block(`policy: ${cls} on "${relative}" is denied for role ${role}`);
    }
    return undefined;
  });
}
