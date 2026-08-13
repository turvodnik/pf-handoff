# Closing a work branch — procedure

Agent reference. Runs ONLY in session-close mode (step 6 of SKILL.md), when the session worked outside the main branch. At a checkpoint the branch is still alive — do not touch it.

Why: a task branch is temporary scaffolding, not storage. Left unclosed it turns into litter, and the work in it stays invisible to main. After the merge the commits live in main and the "why" lives in the journal (§10), so a merged branch has nothing left to keep.

The procedure is plain git — works in any environment (Claude Code, Codex, Gemini, a regular terminal). Orca is an optional layer, see step 4.

## When not to apply

Skip and do nothing if any of these holds:

- the session worked in the main branch (`main`, `master`, `dev`) — nothing to close;
- the branch is a release or long-lived one (`dev`, `release/*`) — it is not a "task";
- you did not create the branch and the human never asked about it.

## Safety invariants

Any violation — stop and report to the human, no actions:

1. **Uncommitted changes** in the branch working copy (`git status --porcelain` non-empty) — merge nothing, delete nothing. First a commit or an explicit human decision.
2. **`--ff-only` only.** Merge failed — history diverged; that is the human's decision (carry over via `cherry-pick`, rewrite, or discard), not a reason to merge somehow.
3. **`git branch -d` only,** never `-D`. A `-d` refusal is the signal "there are commits not in main", not an obstacle. `-D` is allowed only after the human explicitly confirmed the loss.
4. **`git worktree remove` without `--force`.** A refusal means uncommitted changes — see invariant 1.
5. **Never** delete `main`/`master`/`dev` or the branch the primary working copy currently sits on.
6. The branch never existed on `origin` — skip the `push --delete` step; do not create it just to delete it.

## Steps

Substitute your values: `<branch>`, `<main>` (the repository's main branch), `<worktree-path>`.

**1. Check.** Make sure there is something to close and it is safe:

```bash
git status --porcelain                 # empty — otherwise stop (invariant 1)
git log --oneline <main>..<branch>     # what goes into main; empty — branch is empty, go to step 4
git log --oneline <branch>..<main>     # non-empty — main moved ahead, ff may fail
```

**2. Merge** (skip if the branch is empty). Run from the PRIMARY working copy of the repository, not from the branch worktree: a worktree cannot switch to `<main>` — it is held by the primary copy and `checkout` fails with "already checked out":

```bash
git checkout <main>
git merge --ff-only <branch>           # failed — stop, report to the human (invariant 2)
git push origin <main>                 # only if the repository has an origin
```

**3. Report if ff failed.** Do not fix it yourself. Three lines to the human: how many commits are on the branch, what they touch, four options (carry over via `cherry-pick` / rewrite manually in main / archive as a tag / discard). Then follow their decision; do not delete the branch until they answer.

Before reporting, run `git cherry main <branch>`: a `-` marks a commit whose equivalent is already in main (typical after a squash-merged PR — the branch only looks unmerged), `+` marks one that is genuinely missing. All `-` — the branch is spent, no human decision needed.

Archiving as a tag is the right answer when the work is real but no longer applicable (the architecture around it was rewritten): the commits are kept forever, the branch list stays quiet.

```bash
git tag -a archive/<branch> <branch> -m "<what it was, why it was not merged, how to restore>"
git push origin archive/<branch>          # if the repository has an origin
# restore later: git checkout -b restore archive/<branch>
```

**4. Remove the worktree** (if the branch lived in a separate working copy):

```bash
# Three states, not two — a single `A && B || C` chain would also fall back
# to git when Orca IS present, the worktree IS managed, but `orca rm` itself
# fails for a real (possibly transient) reason: git would then delete the
# worktree while its Orca card survives, pointing at nothing.
if ! command -v orca >/dev/null 2>&1; then
  git worktree remove "<worktree-path>"               # state 1: no Orca on this machine
elif ! ORCA_LIST=$(orca worktree list 2>/dev/null); then
  # state 2a: Orca is here but the lookup itself failed — ownership unknown.
  # Never guess: a failed `list` used to read as "unmanaged" (the pipeline
  # returned grep's status, not Orca's) and git would delete a managed
  # worktree behind Orca's back.
  echo "orca worktree list failed — cannot tell whether this worktree is Orca-managed. Stop: diagnose Orca (daemon/logs), then retry or ask the human." >&2
  exit 1
elif ! printf '%s\n' "$ORCA_LIST" | grep -qF "<worktree-path>"; then
  git worktree remove "<worktree-path>"               # state 2b: Orca present, this worktree is unmanaged
else
  # state 3: Orca manages this worktree — remove it THROUGH Orca so the card
  # disappears too. Failure here is not a cue to fall back to git — stop.
  orca worktree rm --worktree "path:<worktree-path>" || {
    echo "orca worktree rm failed for an Orca-managed worktree — stop, do not fall back to git worktree remove (it would delete the worktree while the Orca card survives, pointing at nothing). Diagnose the Orca failure first (orca worktree list, Orca daemon/logs), then retry or ask the human." >&2
    exit 1
  }
fi
```

Three states, three different outcomes: no `orca` in PATH (state 1) or the
worktree is not Orca-managed (state 2) — plain `git worktree remove` handles
both, same as before. Orca manages the worktree but its own removal command
fails (state 3) — stop and diagnose; do not add `--force` (invariant 4) and
do not fall back to git, or the card orphans silently.

**5. Delete the branch:**

```bash
git branch -d <branch>                       # refusal — stop (invariant 3)
git push origin --delete <branch>            # only if the branch existed on origin
git remote prune origin                      # drop stale remote-tracking refs
```

`orca worktree rm` in step 4 may delete the branch itself — then `branch -d` says "not found"; that is normal, not an error.

**6. Record.** One journal line (§10): which branch was closed, what was merged, what was decided about any divergence. Nothing goes into the HANDOFF on close: the branch no longer exists.

## Final check

```bash
git branch -a && git worktree list
```

Only the main branch remains (plus `dev`/`release/*` if the repository is release-based) and a single working copy. Anything beyond that — name it to the human and explain why you did not touch it.
