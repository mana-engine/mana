---
description: Remove stale git worktrees under .claude/worktrees/ whose lane PR is merged or whose branch is gone, to keep the workspace lean. Lists candidates first (dry-run by default); never removes a worktree with uncommitted changes or a still-running lane/review agent. Run at an orchestrator restart or after merging a wave.
argument-hint: (none, dry-run) | --apply
---

Prune stale agent worktrees under `.claude/worktrees/`. They accumulate fast (one per
`isolation: "worktree"` lane/review agent) and bloat the workspace. See LOOP.md
"Workspace hygiene."

**Default is a dry-run** — list candidates and stop. Only remove when invoked with
`--apply` (or after the user confirms the listed candidates).

## Steps

1. `git fetch origin main` so merge checks are against the current trunk.
2. Enumerate worktrees: `git worktree list --porcelain`. Skip the main checkout (the repo
   root) — only consider paths under `.claude/worktrees/`.
3. For each candidate worktree, classify it. A worktree is **safe to remove** only if ALL:
   - **Clean:** `git -C <path> status --porcelain` is empty (no uncommitted work — never
     discard changes).
   - **Landed or dead:** its HEAD/branch is an ancestor of `origin/main`
     (`git merge-base --is-ancestor <sha> origin/main`) OR its lane branch no longer exists
     on `origin` (the PR was merged with `--delete-branch`) OR the worktree is empty/unchanged.
   - **Not in use:** no lane/review agent is still running against it. You cannot always tell
     from git alone — if there is any doubt (a very recent worktree, an open PR on its
     branch), **leave it**. When in doubt, don't remove.
4. Print the candidate list: path, branch, why it's safe (merged / branch-gone / empty), and
   the count. If dry-run (no `--apply`), stop here and report.
5. On `--apply` (or confirmation), for each safe candidate:
   - `git worktree remove <path>` (add `--force` only if it's clean but git is cautious about
     a lock; never `--force` to discard real changes).
   - `git branch -D <its-branch>` if the branch is fully merged/abandoned.
6. Finish with `git worktree prune` (clears bookkeeping for already-gone dirs) and report how
   many were removed and how many remain (`git worktree list | wc -l`).

## Guardrails
- **Never** remove a worktree with uncommitted changes or one whose agent may still be
  mid-flight — that orphans in-progress work. Durable work is on GitHub (PRs); ephemeral
  worktree state is not.
- This is destructive of local worktrees only (not of any merged code). Prefer the dry-run
  first; apply once the list looks right.
