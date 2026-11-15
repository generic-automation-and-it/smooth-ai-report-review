# Diagrams — PR Review Gate Pipeline

The C1 is the mandatory floor. The flow below earns its place because the gate's safety comes from
its decision path, which C1 cannot show.

## System Context (C1)

The gate runs on GitHub-hosted runners, reads the reviewed repository and its history, sends prompts
to the selected provider endpoint, and posts reviews back to GitHub.

```mermaid
C4Context
    title PR Review Gate Pipeline — System Context

    System(gate, "PR Review Gate", "Resolves scope, chunks diffs, reviews chunks, aggregates and posts one pinned verdict")
    System_Ext(github, "GitHub Actions and API", "CI runtime, PR events, reviews and GraphQL operations")
    System_Ext(model, "Model Endpoint", "Selected provider API or compatible gateway")
    System_Ext(repo, "Reviewed Repository", "Git history, source tree and project context files")

    Rel(gate, github, "Reads events and diffs; posts and minimizes reviews", "HTTPS REST/GraphQL")
    Rel(gate, model, "Sends chunk and aggregation prompts", "HTTPS")
    Rel(gate, repo, "Reads diff, files and context", "git/filesystem")
```

## Gate Flow

One review path: prove scope, bound the work, survive failure, then post a pinned verdict.

```mermaid
flowchart TD
    T[Trigger: PR event, trusted comment or dispatch] --> B[Resolve diff base]
    B -->|not an ancestor| F[Fail the run: no review]
    B --> D[Collect diff and changed files]
    D --> G{Scope gates}
    G -->|too many files or trivial| S[Post guidance and stop]
    G --> C[Chunk by shape]
    C --> X[Build per-chunk context]
    X --> R[Review: primary then secondary]
    R -->|chunk passed| M[Merge findings and coverage]
    R -->|chunk failed| Y[Retry once]
    Y --> M
    M --> A[Aggregate summary and derive action]
    A --> P[Post pinned review and upload artifact]
```
