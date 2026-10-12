# Work branch: closing records, integration is separate

Agent reference. Closing a session (SKILL.md step 6) saves state — it never merges, pushes or deletes. Integrating the branch into main is a separate explicit action with its own preconditions. Why: a close that publishes turns "save my state" into "ship unreviewed work" (audit 02.10, A2).

Plain git — works in any environment (Claude Code, Codex, Gemini, a terminal). `<branch>`, `<main>`, `<worktree-path>`, `<sha>` — substitute yours.

## On session close (step 6)

Skip if the session worked in the main branch (`main`, `master`, `dev`) or on a release/long-lived branch (`dev`, `release/*`).

1. `git status --porcelain` in the branch working copy is non-empty — stop, report to the human (commit first or their explicit decision).
2. Into the HANDOFF «Состояние»: the branch, the worktree path, `git rev-parse HEAD`, the commit count of `git log --oneline <main>..<branch>`, and «не слито, ждёт приёмки». One journal line (§10).
3. Nothing else: no checkout, merge, push, branch or worktree removal.

## Integration — a separate explicit action

Runs only when the human asks for it (or an orchestrator holding their explicit grant for this repository) — never as part of closing. All preconditions, otherwise stop and report:

- **Named acceptance of this SHA:** the packet is `done` from a reviewer (pf-reviewer or the human), the verdict names `<sha>`, and the branch HEAD still equals it — a commit after acceptance is unreviewed.
- **Push right:** granted for this repository; only the project's private remote. A public distribution — never without the §6 gate.
- Both the branch worktree and the primary copy are clean (`git status --porcelain` empty).

From the PRIMARY working copy (a worktree cannot check out `<main>`, it is held there):

```bash
git checkout <main>
git merge --ff-only <sha>              # failed — stop, see below
git push origin <main>                 # only with the push right above
```

**ff failed** — history diverged; do not fix it yourself. `git cherry <main> <branch>`: all `-` — the work is already in main (squash merge), the branch is spent; any `+` — report to the human: how many commits, what they touch, options: `cherry-pick` / rewrite in main / archive as a tag (`git tag -a archive/<branch> <branch> -m "<what, why not merged>"`) / discard. Delete nothing until they answer.

**Cleanup** — only after the merge, or for a spent branch:

```bash
git worktree remove "<worktree-path>"  # never --force: a refusal means uncommitted changes
git branch -d <branch>                 # never -D unless the human confirmed the loss
git push origin --delete <branch>      # only if the branch existed on origin
git remote prune origin
```

Orca-managed worktree (listed by `orca worktree list`) — remove it with `orca worktree rm --worktree "path:<worktree-path>"` so the card goes too; if `orca worktree list` or `orca worktree rm` fails — stop and diagnose Orca, never fall back to `git worktree remove` (the card would point at nothing). After `orca worktree rm`, `branch -d` saying "not found" is normal.

Never delete `main`/`master`/`dev` or the branch the primary copy sits on. Journal line (§10): which SHA was merged, what was decided about any divergence.

## Final check

`git branch -a && git worktree list` — only the main branch (plus `dev`/`release/*`) and the working copies of live sessions remain; anything else — name it to the human and say why you left it.
