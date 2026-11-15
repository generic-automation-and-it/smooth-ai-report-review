# NFR-01: Context Selection Completeness

**Status:** Accepted

## Requirement

Zero applicable rules are dropped. A rule is removed only when a parsed scope provably matches no
file in the chunk. Every no-frontmatter, unparseable, unscoped, `alwaysApply`, untranslatable-glob
and mandatory-path case is retained, and brace plus character-class globs are translated.

## Verification

Run the scope filter against fixtures derived from the configured instruction patterns, covering
each fail-open case and both glob syntaxes. Assert the retained and dropped sets explicitly, not
only that the command succeeds.

**Test mapping:** `test-context-scope.sh` and `test-find-context-files.sh`.

## Acceptance Criteria

- Every fail-open fixture survives.
- Brace and class globs match the files they describe.
- A no-Python environment passes the candidate list through unchanged.

## Applies To

Goal 1; the context discovery and scope-filter flow.
