# Diagrams — Pi Agent Backend

The **C1 System Context** below is the mandatory floor for every HLD. Additional diagrams are
deferred until the contract is approved; the candidate is a dispatch/lockdown flow, which earns a
place only if the per-role tool contract proves hard to read from the goals and LADRs alone.

## System Context (C1)

The gate is one backend-neutral pipeline. It reads a pull request, builds a scoped instruction set,
runs a selected runtime, and owns every side effect. The runtime is a replaceable external
dependency; the reviewed repository is untrusted input, not configuration.

```mermaid
C4Context
    title Pi Agent Backend — System Context

    System(gate, "Review Gate and Fixer", "Backend-neutral chunked review, findings pipeline and bounded low/medium fixing")

    System_Ext(github, "GitHub Actions and API", "CI runtime, pull requests, reviews and GraphQL")
    System_Ext(repo, "Reviewed Repository (PR head)", "Untrusted diff, rules and project configuration")
    System_Ext(opencode, "OpenCode CLI (default backend)", "Executes review and fix prompts")
    System_Ext(pi, "Pi coding agent (second backend)", "Executes the same prompts behind the backend selector")
    System_Ext(endpoint, "Model Endpoint", "Selected provider's API — LiteLLM proxy or native")

    Rel(gate, github, "Reads diffs, posts reviews and comments")
    Rel(gate, repo, "Reads diff and rules; never trusts project configuration")
    Rel(gate, opencode, "Runs the prompt and reads the answer", "stdin/stdout")
    Rel(gate, pi, "Runs the prompt and reads the answer", "stdin/stdout")
    Rel(opencode, endpoint, "Sends prompts", "HTTPS")
    Rel(pi, endpoint, "Sends prompts", "HTTPS")
```
