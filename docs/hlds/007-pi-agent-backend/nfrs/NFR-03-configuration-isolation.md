# NFR-03: Configuration Isolation

**Status:** Draft

## Requirement

No file from the reviewed checkout configures the model process on either backend, and on the second
backend the model process receives **exactly one** provider credential. No credential value exists
in any file the model can read.

## Verification

A fixture repository ships hostile project configuration and executable project extensions; the run
must behave identically to the same fixture without them. A child-process environment assertion
enumerates the model process environment and checks the credential allow-list.

## Acceptance Criteria

- Hostile project configuration and project extensions have no effect on either backend.
- On the second backend, the model process environment contains only the selected provider's key
  beyond the fixed runtime variables.
- No credential value appears in any readable file or in the run artifact.
- A provider selector resolves to one credential set, with no silent fallback.

## Applies To

Goal 4; the second backend and both entry points. The OpenCode path is governed by the separate
allow-list hardening decision.
