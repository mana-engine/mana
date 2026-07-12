---
name: review-pr
description: Review a mana pull request with the dedicated pr-reviewer subagent. Independently re-runs the gate and checks the diff against CLAUDE.md, the relevant ADRs, the linked issue, and determinism, then posts a verdict. Use when a PR needs reviewing — especially the lane-agent PRs. Pass the PR number (e.g. "/review-pr 12").
---

# Review a mana PR

Review the pull request given in `$ARGUMENTS` (a PR number) with the dedicated **`pr-reviewer`** subagent, then post the verdict. `gh` is at `"/c/Program Files/GitHub CLI/gh.exe"` and is authenticated; git pushes go over Windows OpenSSH (already configured in the repo).

## Steps

1. **Gather context** (do not review the code yourself — that's the subagent's job):
   - `"/c/Program Files/GitHub CLI/gh.exe" pr view <n> --json number,title,headRefName,body,url,files`
   - Note the linked issue from the PR body (`Closes #N` / `Part of #N`).
   - Skim `"/c/Program Files/GitHub CLI/gh.exe" pr diff <n>` just to size the change.

2. **Dispatch the reviewer.** Launch the **`pr-reviewer`** agent with `isolation: "worktree"` (so it reviews on an isolated checkout and can run the gate without disturbing anything). Give it, in the prompt: the PR number, its head branch, the linked issue number, and a one-sentence summary of the intended change. Instruct it to run its full rubric — check out the PR branch, independently run `mise run check` (plus any `-Denable-*` build the diff touches), review against `CLAUDE.md` + the relevant ADR(s) + the issue's acceptance criteria — and return its structured verdict. It must not modify code or merge.

3. **Post the review.** Write the agent's verdict + findings to a temp file (preserve formatting), then post to the PR:
   - blockers present (or gate red) → `gh pr review <n> --request-changes --body-file <file>`
   - otherwise → `gh pr review <n> --comment --body-file <file>`
   Leave the formal approve/merge decision to a human — post a comment/request-changes, never `--approve` automatically.

4. **Report** the verdict and PR URL back concisely. Do not merge.

## Rules of thumb

- **Never trust the PR's own "tests pass" claim** — the point of this skill is that the reviewer re-runs the gate.
- A red `mise run check`, a module-boundary violation, or a weakened/skipped/deleted test is a **blocker**.
- GPU/window behavior that can't be verified headlessly should be flagged as unverified, not approved.
- One PR per invocation; to review several, invoke once per PR (reviews can run in parallel).
