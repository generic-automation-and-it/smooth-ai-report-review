# NFR-04: Selector failure determinism

**Status:** Draft

## Requirement

An unknown selector value, for either role, exits non-zero before any probe, install or model call, and
names the accepted values.

## Verification

Selector tests cover blank, each accepted value, and representative rejected values per role; a rejected
value must produce a non-zero exit and no runtime invocation.

## Acceptance Criteria

- Blank resolves to the role's default runtime.
- Every accepted value resolves to exactly one runtime.
- Every rejected value exits non-zero before any runtime invocation.

## Applies To

Goal 1; both role selectors; both packagings and local runs.
