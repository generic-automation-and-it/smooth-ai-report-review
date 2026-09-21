// OpenCode v2 plugin entrypoint.
//
// v2 resolves a plugin package by loading `<package>/index.js` directly — it
// ignores package.json `main` and `exports`. Verified on opencode 2.0.11:
// with the entry named `opencode-plugin.js` and pointed at by both fields,
// and no index.js present, the plugin is skipped with NO error and NO log
// line (`opencode plugin list` simply reports "No plugins found"); adding
// this file makes it load and materialize the four skills. So this thin
// re-export is load-bearing, not decoration — deleting it silently disables
// the whole npm consumption channel (LADR-038/087).
//
// The implementation stays in ./opencode-plugin.js, whose own
// `import.meta.url` resolves to this same package root.
export { default, materializeSkills } from "./opencode-plugin.js";
