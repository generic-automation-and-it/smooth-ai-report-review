# Diagrams — Context Delivery and Toolchain

The C1 is the mandatory floor. The flow below earns its place because the fail-open selection rule
is the design's load-bearing behavior and is not visible in a context diagram.

## System Context (C1)

The gate discovers context in the reviewed repository, queries the code graph when available, and
runs on a pinned OpenCode v2 runtime that reaches the selected model endpoint.

```mermaid
C4Context
    title Context Delivery and Toolchain — System Context

    System(gate, "PR Review Gate", "Selects applicable context, enriches chunks and pins the runtime")
    System_Ext(repo, "Reviewed Repository", "AGENTS.md, scoped instruction files and source tree")
    System_Ext(graph, "Code Review Graph", "Structural risk (including change-frequency), inferred coverage and deleted-symbol data")
    System_Ext(runtime, "OpenCode v2 Runtime", "Model transport, config binding and health surface")
    System_Ext(model, "Model Endpoint", "Selected provider API or compatible gateway")

    Rel(gate, repo, "Discovers and scopes context files", "filesystem")
    Rel(gate, graph, "Queries structure for hints", "CLI and local graph store")
    Rel(gate, runtime, "Installs, prepares config and verifies binding", "CLI")
    Rel(runtime, model, "Sends prompts", "HTTPS")
```

## Context Selection Flow

Custom candidates are filtered by their own declared scope; every uncertain case survives.
Native `AGENTS.md` files stay on OpenCode's runtime discovery path and are never concatenated.

```mermaid
flowchart TD
    N[Native AGENTS.md files] --> O[OpenCode native runtime loading]
    A[Discover scoped instructions and explicit mandatory non-AGENTS.md paths] --> B[Collect chunk file list]
    B --> C{Declared scope matches a chunk file?}
    C -->|yes| K[Keep rule]
    C -->|no, proven mismatch| D[Drop rule]
    C -->|missing or unparseable scope| K
    B -->|mandatory path: bypass scope| K
    K --> E[Strip frontmatter and concatenate custom content]
    E --> F[Write generated AGENTS.md for the chunk]
    F --> G[Run review from that directory]
    G --> O
```
