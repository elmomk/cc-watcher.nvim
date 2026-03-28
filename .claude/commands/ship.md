Review, commit, tag, and push all uncommitted changes.

## Steps

1. Run `git status` and `git diff --stat` to see what changed.
2. Review the changes briefly for obvious issues (syntax errors, debug code left in).
3. Write a concise commit message following the repo's style (imperative mood, short first line, optional body with details).
4. Commit the changes (stage specific files, not `git add -A`).
5. Check existing tags with `git tag --sort=-creatordate | head -3` and create the next appropriate semver tag (patch for fixes, minor for features).
6. Push commits and tags to origin. If push fails due to divergence, `git pull --rebase` first, resolve conflicts if needed, then push.
7. Report the commit hash, tag, and push status.
