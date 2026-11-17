---
name: ship
description: Delivery pipeline for a code change in this repo - branch, implement, bin/ci, independent review, pull request, wait for the CI check, squash merge, report. Use when the owner asks for a change to be shipped - a PR, a merge to main, or "the usual pipeline". Not for work they only want implemented or reviewed locally.
argument-hint: "[what to ship]"
---

# Ship a change

The outcome: the change is on `main` through a squash-merged pull request with a green `CI` check, and
the owner gets a short report. Skip stages that add nothing for the change at hand (a docs-only change
needs no review) and say which you skipped.

1. **Branch.** Work on a feature branch (`feat/…`, `fix/…`, `chore/…`, `docs/…`), or on the worktree's
   own branch in a coding-agent worktree. Never commit to `main`. In a fresh worktree run
   `bin/worktree-setup` first (links `.env` and `config/master.key` from the main checkout, prepares this
   worktree's own test database).
2. **Implement.** Follow `CLAUDE.md` and `docs/domain.md`. Keep changes you did not make: another
   session may be working in the same tree. Update `README.md`, `CLAUDE.md` and `docs/` in the same
   change when it makes them wrong.
3. **Verify.** Targeted tests while working, then `bin/ci --summary` before every push: the Rails and
   Python steps GitHub runs, one line per step and the output of failed steps only. For anything
   user-visible, look at it running (`bin/dev`) rather than trusting the tests.
4. **Review**, in proportion to the change. Docs-only and few-line changes need none. Anything else gets
   the `reviewer` agent (`.claude/agents/reviewer.md`, read-only) on the diff, briefed with the code and
   the goal, not with your conclusion. Changes to the data model, a migration, money arithmetic, an
   importer or anything hard to undo also get the `codex-review` skill (`bin/codex-review`, another
   vendor's model) as a second opinion; start both at once in the background. Without Codex (not
   installed, logged out, out of quota) go on with the reviewer alone and say so. Check every finding
   against the code: fix what is real, note what you reject and why, and put the outcome in the PR body
   (`docs/decisions/0003-agent-tooling.md`).
5. **Pull request.** Commit with explicit paths when the tree may hold scratch files or another agent's
   work, then `git push -u origin <branch>` (the pre-push hook refuses `main` and runs the leak check)
   and `gh pr create`. The PR body says what changed and why, how it was verified, and what the review
   found. Commit messages and the PR carry no AI attribution: no co-author trailer, no "generated with"
   footer.
6. **Wait without idling.** Auto-merge is not available on this repository. Start `bin/pr-wait <n>` as a
   background command and continue with other work; it prints one final line. On `GREEN` go on to the
   merge. On `FAILED check=<job>` read the log tail it prints, fix, push, start it again. On `CONFLICT`
   rebase on `main` and push.
7. **Merge.** `gh pr merge <n> --squash` once the `CI` check is green. Squash is the only merge method.
   Never `--admin`, never a push to `main`, never `ALLOW_PUSH_TO_MAIN`. A worktree is retired later with
   `bin/worktree-remove PATH`, which also deletes the merged branch.
8. **Report.** What shipped, the merge commit SHA (`gh pr view <n> --json mergeCommit`), anything
   deferred.
