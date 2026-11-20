// LADR-132: on-read nested AGENTS.md attachment, matching OpenCode's behaviour.
// OpenCode injects a directory's AGENTS.md when the model reads a file there;
// pi has no native equivalent, so this extension appends it to the read result
// once per directory. Fail open: a context miss never blocks a read.
import fs from "node:fs";
import path from "node:path";

const MAX_BYTES = 32 * 1024;

function workspaceRoot() {
  const raw = process.env.PI_WORKSPACE_ROOT || "";
  try {
    return fs.realpathSync(raw);
  } catch {
    return null;
  }
}

export default function onReadContext(pi) {
  const delivered = new Set(
    (process.env.PI_CONTEXT_DELIVERED_DIRS || "")
      .split(path.delimiter)
      .filter(Boolean),
  );
  const attached = new Set();

  pi.on("tool_result", async (event) => {
    if (!event || event.toolName !== "read" || event.isError) return undefined;
    const wsRoot = workspaceRoot();
    const raw = event.input && event.input.path;
    if (!wsRoot || typeof raw !== "string" || !raw) return undefined;

    let fileAbs;
    try {
      fileAbs = fs.realpathSync(path.isAbsolute(raw) ? raw : path.join(wsRoot, raw));
    } catch {
      return undefined;
    }
    if (!fileAbs.startsWith(wsRoot + path.sep)) return undefined;

    const parts = [];
    let budget = MAX_BYTES;
    let dir = path.dirname(fileAbs);
    while (dir.startsWith(wsRoot) && dir !== wsRoot && budget > 0) {
      if (!delivered.has(dir) && !attached.has(dir)) {
        const candidate = path.join(dir, "AGENTS.md");
        try {
          const text = fs.readFileSync(candidate, "utf8");
          const clipped = text.length > budget
            ? text.slice(0, budget) + "\n[... truncated ...]"
            : text;
          budget -= Math.min(text.length, budget);
          attached.add(dir);
          parts.push({
            type: "text",
            text: `\n\n<project-context path="${path.relative(wsRoot, candidate)}">\n${clipped}\n</project-context>`,
          });
        } catch {
          // no nested context in this directory
        }
      }
      const parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
    if (parts.length === 0) return undefined;
    return { content: [...(Array.isArray(event.content) ? event.content : []), ...parts] };
  });
}
