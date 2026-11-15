# NFR-01: Installer Parity and Idempotence

**Status:** Accepted

## Requirement

The two installer ports expose byte-identical owned lists after normalization and implement the same
behavior for per-repository and machine-wide installs. Repeated runs reconcile flags without
duplicating state, and a corrupt manifest fails the run without being reset.

## Verification

Normalize both ports' owned lists and compare them; run each port twice against a fixture consumer
repository and a fixture machine-wide store; inject empty, whitespace-only and non-object manifests.
Assert owned files, link records and manifest state.

## Acceptance Criteria

- Owned lists compare equal.
- A second run produces the same state as the first.
- Every corrupt-manifest case fails and leaves the file unchanged.
- Purging removes only installer-owned links.

## Applies To

Goal 2; both installer ports.
