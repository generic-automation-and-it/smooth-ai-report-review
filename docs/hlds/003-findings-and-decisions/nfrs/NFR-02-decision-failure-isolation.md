# NFR-02: Decision Failure Isolation

**Status:** Accepted

## Requirement

A disabled decision path leaves the merged document byte-identical. A failed, malformed or timed-out
request leaves only that finding unscored while successful scores and counts remain recorded. No
decision failure changes severity, confidence, verification or the exit code.

## Verification

Fault-inject a missing key, an unreachable endpoint, a non-JSON response and a per-finding timeout;
diff the merged document against a control run and assert that only the expected decision fields
differ.

## Acceptance Criteria

- Disabled and preflight-failed runs match the control byte for byte.
- A single failed answer produces exactly one unscored finding.
- No failure path writes a chunk-failure flag.

## Applies To

Goal 3; the optional decision-scoring pass.
