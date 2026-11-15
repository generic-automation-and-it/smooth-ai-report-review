# Diagrams — Findings Integrity and Decision Scoring

The C1 is the mandatory floor. The flow below earns its place because the ordering of extraction,
merge, judgement and rendering is what keeps every consumer stable.

## System Context (C1)

The pipeline receives chunk reviews and their structured sidecars, merges them, optionally verifies
quotes against the reviewed tree, optionally calls a decision endpoint, and renders the posted document.

```mermaid
C4Context
    title Findings Integrity and Decision Scoring — System Context

    System(findings, "Findings Pipeline", "Extracts, merges, verifies, scores and renders findings")
    System_Ext(gate, "Chunk Reviewers", "Produce markdown findings and an optional structured sidecar")
    System_Ext(repo, "Reviewed Repository", "Source tree at the reviewed revision")
    System_Ext(judge, "Decision Model Endpoint", "Structured scoring and fix-or-skip answers")
    System_Ext(github, "GitHub API", "Receives the posted review body")

    Rel(gate, findings, "Supplies chunk documents", "filesystem")
    Rel(findings, repo, "Optionally verifies quoted lines and reads context", "filesystem")
    Rel(findings, judge, "Sends typed scoring questions", "HTTPS")
    Rel(findings, github, "Posts the rendered review", "HTTPS REST")
```

## Finding Lifecycle

Each claim is extracted once, merged conservatively and confidence-gated, optionally tree-verified
and judged, then rendered for every consumer from one ordered document. Tree verification is off
by default.

```mermaid
flowchart TD
    A[Chunk review plus structured sidecar] --> B[Extract sidecar, excluding its sentinel range]
    B --> D[Merge by file, line and title using conservative rules]
    D --> E[Demote unsupported confidence and suppress weak non-critical items]
    E --> C{Tree quote verification enabled? Default off}
    C -->|yes| V[Verify at reviewed revision; demote definite misses and suppress weak non-critical items]
    C -->|no| F{Decision scoring enabled?}
    V --> F
    F -->|yes| G[Annotate scores; filter only inside the coverage fence]
    F -->|no| H[Render merged findings]
    G --> H
    H --> I[Post one ordered document and record coverage]
```
