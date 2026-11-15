# NFR-03: Version Tag Consistency

**Status:** Accepted

## Requirement

The major tag moves only to a release tag whose version matches the plugin manifest. No package
manifest or publish workflow exists, and no supported consumer channel depends on a registry.

## Verification

Run the tag-update logic against a matching tag and a mismatched tag; assert that only the matching
case moves the major tag. Scan the repository for a package manifest or publish workflow.

## Acceptance Criteria

- A mismatched tag fails without moving the major tag.
- No package manifest or publish workflow is present.
- Every documented channel resolves its version from the plugin manifest or its own explicit pin.

## Applies To

Goal 4; the release and tag-update flow.
