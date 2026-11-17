#!/bin/sh
# SessionStart hook: says so when a checkout is not set up, so the first test run does not fail on
# missing files (coding agents create fresh worktrees that have no .env), and when the git hooks in
# .githooks are off. Prints nothing when everything is in place. Never blocks.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
missing=""
[ -e .env ] || missing="$missing .env"
[ -e config/master.key ] || missing="$missing config/master.key"
[ -n "$missing" ] && echo "This checkout is missing:$missing. Run bin/worktree-setup before running tests or the app."
if [ -d .githooks ] && [ "$(git config core.hooksPath 2>/dev/null)" != .githooks ]; then
  echo "The git hooks in .githooks are off (secret scan, leak check, no pushes to main). Run bin/setup, or: git config core.hooksPath .githooks"
fi
exit 0
