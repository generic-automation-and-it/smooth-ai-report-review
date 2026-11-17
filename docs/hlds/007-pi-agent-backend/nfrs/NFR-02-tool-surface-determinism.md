# NFR-02: Tool-Surface Determinism

**Status:** Draft

## Requirement

No invocation in the reviewer role can reach edit, write, shell or network tools, and reads and
searches on credential and VCS paths are denied. No invocation in the fixer role can reach shell or
network tools, or write to tooling, context, temp, VCS or credential paths. The guarantee covers
built-in, extension and MCP tools alike, and must hold under adversarial input.

## Verification

Negative tests attempt each denied tool call against each backend and assert it is **blocked**, not
merely absent from the prompt. A path that cannot be resolved must fail closed. The same test matrix
runs against both backends.

## Acceptance Criteria

- Review role: edit, write, shell and network calls are impossible on both backends.
- Review role: reads and searches on credential and VCS paths are blocked on both backends.
- Fixer role: writes to protected paths are blocked on both backends.
- An unresolvable path is blocked, never allowed.
- No denied action succeeds through an extension or MCP tool path.

## Applies To

Goal 3; the reviewer and fixer roles on both backends.
