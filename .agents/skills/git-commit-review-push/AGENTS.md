# git-commit-review-push

## TL;DR

Commits the working tree as one-or-more Conventional-Commit chunks, embeds the `/ai-review` full-review trigger as the final line of the **last** commit body, optionally renames the branch to `<type>/<issue>-desc`, and pushes. It only commits and pushes — it never opens or updates a PR.

## Non-Negotiables

- **The `/ai-review` trigger goes on the last chunk only, as the final non-empty body line.** The gate (`pipeline-code-review-report.yml`) greps PR commit messages for `/ai-review` to force a FULL review; earlier chunk commits must NOT carry it, or the trigger's "last commit" intent is lost.
- **Amend with `%B`, never `%s`.** When appending the missing trigger, reuse the full message (`git commit --amend -m "$(git log -1 --format='%B')" -m "/ai-review"`). Rebuilding from `%s` drops the body and every `Co-authored-by:` / `Signed-off-by:` / `Refs:` trailer.
- **Skip the trigger check on merge commits.** A merge commit's `%b` is the merged-branch list, not a usable body, so the check would spuriously fail and provoke an `--amend` that corrupts the merge. Detect via `git log -1 --format=%P | wc -w` > 1 (multiple parents) or a `Merge*` subject, and the guard must wrap the check *in the code block*, not only in prose — an agent following SKILL.md literally executes the block.

## Key Behaviors

- **The trigger regex anchor `^` is load-bearing — do not "simplify" it away.** The check is `awk 'NF { last=$0 } END { exit (last ~ "^[[:space:]]*/ai-review[[:space:]]*$") ? 0 : 1 }'`. `awk` isolates the last non-empty line into `last`, but the match is still unanchored: without `^`, a line like `deploy /ai-review` would satisfy `[[:space:]]*/ai-review[[:space:]]*$` and pass, falsely reporting the trigger present. `^` forces the whole line to be *only* optional-space + `/ai-review` + optional-space. (A code reviewer once flagged `^` as redundant — it is not; that suggestion is a false positive.)
- **The regex tolerates trailing whitespace / CRLF** (`[[:space:]]*$`), unlike a strict string compare — intentional, so a body ending in `/ai-review\r\n` still matches.
- **Branch rename is opt-in via `--issue <number>`** and is skipped when the branch already conforms to `<type>/<issue>-*`. The `<type>` is taken from the just-made commit's Conventional-Commit type; the description is generated from the subject/diff, not copied from the old branch name verbatim.
- **`models.claude: sonnet`** — the branch-rename + upstream-tracking logic needs broader reasoning than a trivial commit helper.
- **Empty working tree is not an error** — the skill reports "nothing to commit/push" and exits gracefully.

## Changelog

| Date | Change | Ref |
|------|--------|-----|
| 2026-07-07 | Folded the merge-commit guard into the step-4 code block (prose-only before), normalized its indentation, and documented the load-bearing `^` anchor. Sole verified finding from the OpenCode review on smooth-llm-imposter#64; both High findings there were false positives. | PR #64 review |
| 2026-07-07 | Initial AGENTS.md for the `git-commit-review-push` skill: trigger placement, `%B` amend, merge-commit skip, and the `^`-anchor rationale. | git-commit-review-push |
