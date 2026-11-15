# Diagrams — Review Follow-Through

The C1 is the mandatory floor. The flow below earns its place because the routing split between
Copilot threads and PR-description notes decides where every result lands.

## System Context (C1)

A developer runs the consumer against a posted review. The consumer reads and writes GitHub state,
edits the local checkout, and pushes commits that carry the next review trigger.

```mermaid
C4Context
    title Review Follow-Through — System Context

    Person(dev, "Developer", "Chooses analysis or explicit fix and skip decisions")
    System(consumer, "Review Follow-Through", "Analyses a posted review, applies decisions and routes results")
    System_Ext(github, "GitHub API", "Posted reviews, review threads, PR description and commits")
    System_Ext(repo, "Reviewed Repository", "Working tree, commits and push target")
    System_Ext(judge, "Decision Model Endpoint", "Optional advisory fix-or-skip recommendations")

    Rel(dev, consumer, "Invokes analysis or execution")
    Rel(consumer, github, "Reads reviews; replies, resolves, edits description and pushes", "HTTPS REST/GraphQL")
    Rel(consumer, repo, "Edits fixes and commits them", "git")
    Rel(consumer, judge, "Requests advisory recommendations", "HTTPS")
```

## Follow-Through Flow

Analysis is the default; execution is explicit. The source decides the routing channel, and the
final commit hands control back to the gate.

```mermaid
flowchart TD
    A[Posted review] --> B[Detect review source]
    B --> C[Analyse and recommend]
    C --> D{Explicit execution?}
    D -->|no| E[Stop: read-only analysis]
    D -->|yes| F[Apply authorized fixes]
    F --> K[Commit and push applied fixes, if any]
    K --> G{Source is Copilot?}
    G -->|yes| H[Reply to and resolve each processed thread]
    G -->|no| I[Append AI Review Notes and Skip Areas bullets]
    I --> J[Verify bullets in live PR body]
    H --> L[Create and push a separate empty re-verification commit when Critical or High]
    J --> L
```
