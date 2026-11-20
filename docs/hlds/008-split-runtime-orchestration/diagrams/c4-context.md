# Diagrams — Split runtime — pi chunk review, OpenCode orchestration

## System Context (C1)

The gate is one system with two model-execution roles: chunk review and orchestration. Each role resolves
a runtime from its selector; both runtimes reach the selected provider endpoint. GitHub supplies the diff,
PR metadata and side effects; the evaluation harness observes both runtimes report-only.

```mermaid
C4Context
    title Split runtime — System Context

    System(gate, "Review Gate", "Selects a runtime per role; owns prompt, context, policy and side effects")
    System_Ext(github, "GitHub Actions + API", "CI runtime, PR diffs, reviews and comments")
    System_Ext(chunkRt, "Chunk Runtime", "Executes chunk-review model calls")
    System_Ext(orchRt, "Orchestration Runtime", "Executes semantic-grouping and aggregation calls")
    System_Ext(provider, "Model Endpoint", "Selected provider's API, publicly reachable")

    Rel(gate, github, "Reads diffs, posts reviews")
    Rel(gate, chunkRt, "Runs chunk calls")
    Rel(gate, orchRt, "Runs orchestration calls")
    Rel(chunkRt, provider, "Sends prompts", "HTTPS")
    Rel(orchRt, provider, "Sends prompts", "HTTPS")
```

## Routing flow (Flow)

The role resolver is the only place a runtime is chosen; both roles share the resolver's failure
behaviour, and a rejected selector fails before any runtime starts.

```mermaid
flowchart TD
    A[Run start] --> B{Role selector set?}
    B -->|blank| C[Inherit whole-run runtime]
    B -->|value| D{Accepted value?}
    D -->|no| E[Fail before any model call]
    D -->|yes| F[Resolve role runtime]
    C --> F
    F --> G[Install + initialize role runtime]
    G --> H[Execute role calls]
```
