# NFR-03: Version Tag Consistency

**Status:** Accepted

## Requirement

The updater derives the floating major tag (`vN`) from the plugin manifest and moves it to the
default-branch HEAD, without validating a release tag. No package manifest or publish workflow
exists, and no supported consumer channel depends on a registry.

## Verification

Check that the tag-update logic derives `vN` from the manifest's major version and creates or updates
that tag to the resolved default-branch HEAD. Scan the repository for a package manifest or publish
workflow.

## Acceptance Criteria

- The tag name is derived from the manifest's major version and its target is the default-branch HEAD.
- No package manifest or publish workflow is present.
- Every documented channel resolves its version from the plugin manifest or its own explicit pin.

## Applies To

Goal 4; the release and tag-update flow.
