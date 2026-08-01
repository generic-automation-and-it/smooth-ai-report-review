# git-commit-review-push

## TL;DR

Commits the working tree as one-or-more Conventional-Commit chunks, embeds the `/ai-review` full-review trigger in the **last** commit (preferably immediately before its trailer block), optionally renames the branch to `<type>/<issue>-desc`, and pushes. It only commits and pushes — it never opens or updates a PR.

## Non-Negotiables

- **The `/ai-review` trigger goes on the last chunk only.** The gate (`pipeline-code-review-report.yml`) greps whole PR commit messages for `/ai-review` to force a FULL review, regardless of whether it appears in the subject, body, or before a trailer block; earlier chunk commits must NOT carry it, or the trigger's "last commit" intent is lost.
- **Amend with `%B`, never `%s`.** When adding a missing trigger, reuse the full message and place it immediately before a final `Co-authored-by:` / `Signed-off-by:` / `Refs:` trailer block. Rebuilding from `%s` drops the body and every trailer, while appending after trailers stops Git from parsing them as trailers.

## Key Behaviors

- **Use the gate's trigger matcher.** The check is `git log -1 --format='%B' | grep -qiE '/ai-review'`, matching the whole commit message exactly as the gate does. It accepts subject triggers, triggers with trailing text, and triggers before a final trailer block.
- **Branch rename is opt-in via `--issue <number>`** and is skipped when the branch already conforms to `<type>/<issue>-*`. The `<type>` is taken from the just-made commit's Conventional-Commit type; the description is generated from the subject/diff, not copied from the old branch name verbatim.
- **`models.claude: sonnet`** — the branch-rename + upstream-tracking logic needs broader reasoning than a trivial commit helper.
- **Empty working tree is not an error** — the skill reports "nothing to commit/push" and exits gracefully.

## Changelog

| Date | Change | Ref |
|------|--------|-----|
| 2026-08-01 | Matched trigger verification to the gate's whole-message matcher and preserved Git trailers by placing a missing trigger before their final paragraph. | #103 |
| 2026-07-07 | Folded the merge-commit guard into the step-4 code block (prose-only before), normalized its indentation, and documented the load-bearing `^` anchor. Sole verified finding from the OpenCode review on smooth-llm-imposter#64; both High findings there were false positives. | PR #64 review |
| 2026-07-07 | Initial AGENTS.md for the `git-commit-review-push` skill: trigger placement, `%B` amend, merge-commit skip, and the `^`-anchor rationale. | git-commit-review-push |
