# LADR-02: pi may review chunks only with equal delivered evidence

**Status:** Draft

## Context

- A chunk review is only as good as the evidence the model sees: prompt, generated instruction artifact,
  native context, and context a runtime attaches while exploring.
- The runtimes differ in native discovery: one loads context files itself and attaches nested context on
  read; the other must be given both explicitly.
- Missing evidence produces missed findings, which is a quality regression even if latency improves.

## Decision

**Permit a chunk role to select an alternative runtime only when it delivers equal evidence.** The
precondition is: identical prompt bytes; an equal delivered instruction set, including on-read nested
context; exact context files delivered once; and an unchanged consumed rule-source set. A runtime that
cannot meet any one of these is not a valid chunk runtime, whatever its latency profile. Scoped rule
files and formatter configuration stay start-set artifacts and are not delivered on read.

## Consequences

- On-read context attachment is a prerequisite, not a follow-up, for an alternative chunk runtime.
- The parity test is per chunk and per role, not a whole-run smoke test.
- A runtime with better raw throughput but weaker evidence is rejected on quality grounds.

## Related

- **LADR-06** — promotion depends on measured parity.
