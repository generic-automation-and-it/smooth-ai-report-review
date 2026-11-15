# Diagrams — Autonomous Low and Medium Fixer

The C1 is the mandatory floor. The flow below earns its place because the safety of the loop comes
from where each filter and gate runs, not from the components alone.

## System Context (C1)

The fixer runs as a workflow after a successful gate run, reads the gate's artifact and the PR, uses
a model for scoped edits, and relies on the repository's test suites as an independent oracle.

```mermaid
C4Context
    title Autonomous Low and Medium Fixer — System Context

    System(fixer, "Autonomous Fixer Workflow", "Selects low and medium findings, applies safe edits and publishes only after the test gate")
    System_Ext(gate, "PR Review Gate", "Produces the review and run artifact this loop consumes")
    System_Ext(model, "Model Endpoint", "Edit-only model that proposes scoped fixes")
    System_Ext(repo, "Reviewed Repository", "Working tree, test suites and evaluation assets")
    System_Ext(github, "GitHub API", "PR state, comments, commits and artifact storage")

    Rel(gate, fixer, "Triggers on successful completion", "workflow run event")
    Rel(fixer, model, "Sends the fix prompt", "HTTPS")
    Rel(fixer, repo, "Edits files and runs the test gate", "filesystem/CLI")
    Rel(fixer, github, "Reads PR state; pushes and comments", "HTTPS REST")
```

## Fixer Loop

Each cycle narrows the findings, protects the oracle, and publishes only what the gate approved.
Auto-detected suites gate on regressions; explicit test commands gate on any nonzero exit.
Timeouts, exhausted budgets and unavailable baselines fail closed.

```mermaid
flowchart TD
    A[Successful gate run] --> B{Fork, stale artifact or non-actionable review?}
    B -->|yes| Z[Stop]
    B -->|no| C[Extract medium and low findings]
    C --> D[Withhold failing-test findings and pre-decide testing gaps]
    D --> E[Model edits within scope]
    E --> G[Verify pinned tooling is unmodified]
    G --> F[Revert protected test and evaluation edits]
    F --> H{Regression, failed explicit command, timeout, exhausted budget or unavailable baseline?}
    H -->|yes| I[Keep fixes, publish diff, skip push]
    H -->|no| J[Exclude scratch paths, rebase and push]
    J --> K[Comment summary and upload redacted artifact]
    K --> L{Cap reached or no edits?}
    L -->|no| A
    L -->|yes| Z
```
