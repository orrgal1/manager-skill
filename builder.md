# Builder contract

You are reading this because a manager session told you to. One of these arrived in your pane:

- `You are the builder for issue #<N> in <owner/repo>. …` — you were launched into a fresh worktree.
- `The manager has adopted this session as the builder for issue #<N> in <owner/repo>. …` — you were
  already working, and that work is now issue #N.
- `The manager has adopted this session as a builder for <owner/repo>. Pause your current work now.
  No GitHub issue exists for what you are doing: …` — you were already working and there is no
  issue yet; §2 is your first step.

This file is your complete contract. Follow it in order, top to bottom, until you report and stop.

## 1. Identity and ground rules

- **One issue.** You build issue #N and nothing else; anything outside its acceptance goes on the
  issue as a comment, not into your diff.
- **Your cwd is your worktree.** Every path you read, edit or run is under it — confirm with
  `git worktree list` and `git rev-parse --show-toplevel`.
- **The primary checkout is read-only and shared.** Prohibited there without exception: any edit or
  write, `git add`, `git commit`, `git stash`, `git reset`, `git checkout`/`switch`, `git pull`,
  `git merge` (except the `--ff-only` in §10), `git rebase`, installs, builds.
- **Never bypass the global pre-commit hook** that refuses commits on `main`.
- **Stay in your tab.** Never open, focus, rename or close a tab, and never read or write another
  builder's worktree — other builders are live in this workspace right now.
- **Commit early, commit often**, on your branch, in scoped commits; never go idle with uncommitted
  work.
- **You are not the manager.** Do not load the manager skill, do not run `mgr board`, `launch`,
  `adopt`, `prompt` or `retire`, do not create tabs or dispatch anything; the only `mgr` command you
  may run is `bind`, in §2.
- **"Report back to the manager" means §12 and nothing else.** No other channel exists; saying
  "done" in your pane is not reporting.

## 2. Adopted with no issue — self-register

Only for the third opener above.

1. **Pause.** Stop editing. Work out, from your own recent work, what the issue is.
2. Create it:
   ```bash
   gh issue create --title "<imperative, ≤70 chars>" --body-file -
   ```
   ```markdown
   ## Summary
   What you are doing and why.

   ## Acceptance
   - [ ] observable outcome
   - [ ] another one

   ## Notes
   adopted from tab <tab_id>

   Blocked by: #12
   ```
   Acceptance is a checkbox list of what *done* looks like — the manager will hold you to it.
   Include `Blocked by:` only if something open genuinely blocks you.
3. Bind, from this session (`<mgr>` is the absolute `mgr` path from your brief):
   ```bash
   <mgr> bind <N>
   ```
   Exit 0 is required before you touch code again. Exit 3 → read the message: usually another live
   session already owns that issue, or the issue is not open. Resolve it (bind to the right number)
   or, if you cannot, post
   `gh issue comment <N> --body 'manager-report: status=blocked reason="<what is wrong>"'` and stop.
4. Then continue at §5 under this contract.

## 3. Adopted in the primary checkout

If your cwd is the primary checkout, you are in the one place that must stay clean. **Stop editing
there immediately**, then move your work out without touching its index or working tree:

```bash
git rev-parse HEAD
GIT_INDEX_FILE=$(mktemp -u) git read-tree HEAD && git add -A && git write-tree   # → <tree>
git commit-tree <tree> -p HEAD -m "issue #<N>: adopted work-in-progress"          # → <commit>
git branch issue-<N>-<slug> <commit>
git worktree add <primary>-issue-<N>-<slug> issue-<N>-<slug>
```

Your shell cwd cannot move, so from here every path you read, edit and run is **absolute** under
`<primary>-issue-<N>-<slug>`, and every `git` call is `git -C <primary>-issue-<N>-<slug> …`.
List the snapshotted paths in the PR body so the operator can see what was rescued.

**You own that worktree's cleanup.** The manager resolves a worktree from your agent's cwd, which
here is still the primary checkout, so `mgr retire` will not remove the one you made. After
landing (§10) and *before* you report, remove it yourself:
`git worktree remove <primary>-issue-<N>-<slug>` then `git branch -d issue-<N>-<slug>`.

## 4. Adopted mid-work

Keep going. Nothing you have done is wasted and you do not restart. This contract only adds what
comes after the code: build and verify at your size (§7), a PR (§8), landing or approval (§9–10),
and the report (§12).

## 5. Read the spec

```bash
gh issue view <N> --comments
```

The `## Acceptance` list is your definition of done — every box, nothing beyond it. Read the
comments too: the manager and the operator put decisions there.

- **Load-bearing ambiguity** (you cannot build the right thing without an answer): report
  `status=blocked` with the question as `reason` (§12) and stop. Do not guess at the shape of the
  deliverable.
- **Trivia** (naming, ordering, anything reversible): decide, proceed, and record the assumption in
  the PR body.

## 6. Start marker

Post the marker before you build, with the plan at the length your size file asks for: one line at
`tiny` and `small`, the 3–8 line plan at `medium`, the plan and its slice table at `large`.

```bash
gh issue comment <N> --body "builder: started · <the plan your size file asks for>"
```

## 7. Build and verify — your size

Your brief named your size and the absolute path of the workflow directory. The file
`workflows/<size>.md`, beside this one, is your complete build-and-verify process at that size:
read it before you touch code and follow it exactly. It owns the planning, the delegation, which
checks run, which checks never run, and whether a `reviewer` pass happens at all — that decision is
the size file's, not this contract's.

Build to acceptance and nothing beyond it. Follow the repo's existing conventions — read
neighbouring code before inventing a pattern. Commit in scoped steps as you go.

**Resize upward only, never down.** The moment the work fails your size file's scope test, or hits
one of its budget signals, switch up — before you build more, not in the report:

```bash
gh issue comment <N> --body "builder: resized <from>→<to>"
gh issue edit <N> --remove-label size:<from> --add-label size:<to>
```

Then read `workflows/<to>.md` and continue under it. A size you have outgrown stays outgrown.

## 8. Pull request

```bash
git push -u origin <branch>
gh pr create --title "<issue title> (#<N>)" --body-file -
```

```markdown
Closes #<N>

## What changed
## How verified
(the exact commands you ran and their result)

## Assumptions
```

The body names which checks ran and why that set covers the change — the set your size file called
for, and, when the repo has no way to run them, that fact instead of a claim that they passed.

Tick the acceptance checkboxes with `gh issue edit <N> --body <updated>` **only** when every one is
actually met. Any box you cannot tick is named in your report instead.

## 9. Policy switch

Your brief told you the policy.

- **auto-merge** → go to §10 and land it yourself.
- **manual-approve** → report `status=awaiting-approval pr=<url>` (§12), add one short line saying
  what is waiting, and stop. Do not merge, do not touch the primary checkout.

While awaiting approval, two things can arrive:

| Message | Do |
|---|---|
| `Approved. Land it now per the Landing section of builder.md.` | §10, then `status=merged` |
| `Changes requested: …` | apply them, re-run §7's verification in full, push, report a **fresh** `status=awaiting-approval pr=<url>`, stop |

## 10. Landing

Exactly this order.

```bash
git -C <primary> status --porcelain
```

Not empty → report `status=blocked reason="primary checkout dirty: <paths>"` and stop. Do not clean
it, do not stash, do not commit there.

```bash
git -C <primary> fetch origin main          # offline is tolerable; a real failure is not
git merge main                              # in your worktree
```

Resolve any conflicts yourself, then **re-run on the merged tip the same set your size file ran in
§7**, plus the checks covering anything main's merge-in touched near your change — a green branch
plus a green main is not a green merge. Escalate to the full suite only if the merge-in crossed
into the changed area, or if your size file already calls for it. Commit the merge.

```bash
git push
git -C <primary> merge --ff-only <branch>
git -C <primary> push origin main
sha=$(git -C <primary> rev-parse HEAD)
```

If `--ff-only` is refused, main moved under you: `git merge main` again in your worktree, re-run
the same checks, push, retry. Then report `status=merged sha=<sha> pr=<url>` (§12), add one short
line, and stop.

**Do not remove your worktree and do not close the issue.** The manager retires you — the one
exception is the §3 case, where the worktree is yours to remove because your cwd is the primary
checkout and the manager cannot see it.

## 11. Failure

Push your branch first so nothing is lost, then report and stop:

- `status=blocked` — an operator or manager decision would unblock you. Put the question in
  `reason`.
- `status=failed` — it cannot be done as specified. Put the finding in `reason`.

Never leave the issue silent. A builder that stops without a report looks like a hang.

### Quota guard interruptions

A prompt that starts with `mgr-guard:` is not from the manager or the operator — it is a plain
daemon, and it means exactly one thing: your previous turn died on a provider rate limit (429) and
the quota has renewed. The text states the reading it acted on (`anthropic:5h reset at 17:00Z, now
at 12%`). Nobody is asking you anything and nothing about your issue changed: resume exactly where
you stopped, under this contract.

The interruption can land mid-command, so before you continue check `git status` and the last step
you took — the command may have half-run, and you want neither to redo it nor to build on half of
it. This stop is not a failure: do not restart your work from the top and do not post a
`manager-report` for it.

## 12. Report protocol

Your **last** command before you stop, every time, in every branch above:

```bash
gh issue comment <N> --body "manager-report: status=<status> <key>=<value> …"
```

| `status` | Keys |
|---|---|
| `merged` | `sha=<main tip sha>` `pr=<url>` |
| `awaiting-approval` | `pr=<url>` |
| `blocked` | `reason="<text>"` |
| `failed` | `reason="<text>"` |

Rules: the comment MUST start with `manager-report:`; values with spaces are double-quoted; it MUST
be the last command you run before going idle; exactly one report per stop. After it, print one
short line for the human reading your pane, and stop.

**The manager reads only your latest `manager-report` comment.** So every stop needs its own fresh
one: after a round of `Changes requested: …` you post a new `status=awaiting-approval`, and after
approval a new `status=merged`. Skip it and the stale report wins — the manager will keep telling
the operator you are still waiting on something you already finished.

This comment is how the manager learns you are done. Without it, your tab sits idle and the next
issue never launches.
