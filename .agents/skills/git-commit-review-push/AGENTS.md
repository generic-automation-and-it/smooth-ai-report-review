# git-commit-review-push

## TL;DR

Commits the working tree as one-or-more Conventional-Commit chunks, embeds the `/ai-review` full-review trigger in the **last** commit (preferably immediately before its trailer block), optionally renames the branch to `<type>/<issue>-desc`, and pushes. It only commits and pushes — it never opens or updates a PR.

## Non-Negotiables

- **The `/ai-review` trigger goes on the last chunk only.** The gate (`pipeline-code-review-report.yml`) greps whole PR commit messages for `/ai-review` to force a FULL review, regardless of whether it appears in the subject, body, or before a trailer block; earlier chunk commits must NOT carry it, or the trigger's "last commit" intent is lost.
- **Amend with `%B`, never `%s`.** When adding a missing trigger, reuse the full message and place it immediately before a final `Co-authored-by:` / `Signed-off-by:` / `Refs:` trailer block. Rebuilding from `%s` drops the body and every trailer, while appending after trailers stops Git from parsing them as trailers.

## Key Behaviors

- **Use the gate's trigger matcher.** The check is `git log -1 --format='%B' | grep -qiE '/ai-review'`, matching the whole commit message exactly as the gate does. It accepts subject triggers, triggers with trailing text, and triggers before a final trailer block.
- **Branch rename is opt-in via `--issue <number>`** and is skipped when the branch already conforms to `<type>/<issue>-*`. The `<type>` is taken from the just-made commit's Conventional-Commit type; the description is generated from the subject/diff, not copied from the old branch name verbatim.
- **No model pin.** The skill uses `effort: low`; this does not relax its pre-push checks.
- **A clean tree still verifies the trigger before pushing.** With nothing to commit, the skill checks for unpushed commits (`git log @{u}..HEAD`; a missing upstream means everything local is unpushed) and runs the same trigger check + `%B` amend on HEAD before pushing — amending is safe exactly because the commit is unpushed. Without this, a hand-made untriggered commit gets pushed and the gate runs only an incremental review instead of the full one this skill promises.
- **Empty working tree with no unpushed commits is not an error** — the skill reports "nothing to commit/push" and stops without pushing.

## Changelog

| Date | Change | Ref |
|------|--------|-----|
| 2026-09-27 | `effort: low` replaces per-tool models; "Low effort, not low care": ask when unclear, and double-check before push (clean tree, intended commits, conforming messages, trigger on HEAD only, expected upstream). | |
| 2026-08-04 | Clean-tree gap closed: step 5 verifies/amends the trigger on HEAD before pushing unpushed commits and stops when there is nothing to push — a clean tree used to push an untriggered commit (incremental, not full, review). | OpenCode review e732a3f |
| 2026-08-03 | Trigger check matches the gate's whole-message matcher (`%B`, unanchored); a missing trigger goes before the trailer paragraph; the amend awk guards single-paragraph messages (it printed the trigger above the subject). | #103, #104 |
| 2026-07-07 | Merge-commit guard moved into the step-4 code block (it was prose only); the `^` anchor is load-bearing. | PR #64 review |
| 2026-07-07 | Initial AGENTS.md for the `git-commit-review-push` skill: trigger placement, `%B` amend, merge-commit skip, and the `^`-anchor rationale. | git-commit-review-push |
