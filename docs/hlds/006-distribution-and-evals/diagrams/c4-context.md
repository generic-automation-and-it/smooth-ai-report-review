# Diagrams — Distribution and Evaluation

The C1 is the mandatory floor. The flow below earns its place because the same source reaches
consumers through five different channels, and which channel a team uses determines its pin.

## System Context (C1)

Consumers reach this repository through a workflow call, a local-job copy, an installer, a
marketplace, or a documented copy-install. Evaluation runs inside this repository's CI against the
same artifacts.

```mermaid
C4Context
    title Distribution and Evaluation — System Context

    Person(team, "Consumer Team", "Adopts the review gate or its skills in a repository")
    System(dist, "Distribution and Evaluation", "Publishes skills and workflows, runs regressions and names versions")
    System_Ext(github, "GitHub Releases and Actions", "Pinned refs, tags, reusable workflows and eval runs")
    System_Ext(tools, "AI Tool Skill Folders", "Claude Code, Codex and OpenCode discovery paths")
    System_Ext(market, "Claude Code Marketplace", "Optional plugin install of the same skill folders")

    Rel(team, dist, "Adopts a channel", "workflow call, copy or installer")
    Rel(dist, github, "Publishes tags, workflows and eval results", "HTTPS")
    Rel(dist, tools, "Installs or links skills", "filesystem")
    Rel(market, tools, "Installs optional plugins", "filesystem")
    Rel(team, market, "Installs optional plugins")
```

## Delivery Channels

Every channel resolves the same artifacts; only the pin and the placement differ.

```mermaid
flowchart TD
    S[Repository source of truth] --> R[Reusable workflow call]
    S --> L[Local-job caller at a pinned commit]
    S --> I[Skills installer per repository or machine-wide]
    S --> M[Claude Code marketplace plugin]
    S --> C[Documented copy-install]
    R --> E[Consumer CI runs the pinned entrypoint]
    L --> E
    I --> T[Consumer AI tool skill folders]
    M --> T
    C --> E
    S --> Q[Repository CI runs offline regressions]
    Q --> V{Offline regressions green?}
    V -->|yes| G[Artifacts are shippable]
    V -->|no| H[Block the change]
```
