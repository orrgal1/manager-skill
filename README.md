# manager-skill

A machine-wide agent skill that turns one coding-agent session into the **manager** of a
project: it writes the operator's requests up as GitHub issues, decides what can run now,
launches each issue as its own builder session in its own terminal tab and git worktree,
has the builder self-review and land its work, and cycles to the next issue.

Works from any repo with a GitHub remote. Open a tab in the project, say
*"act as the manager"*, and operate from there.

## What you get

- **The board is GitHub issues.** No local state. Labels carry the lifecycle
  (`mgr:in-flight`, `mgr:awaiting-approval`) and the per-issue policy (`mgr:manual-approve`).
- **One builder per issue**, in a [herdr](https://herdr.dev) tab named `#N <slug>`, on branch
  `issue-N-<slug>`, in worktree `<repo>-issue-N-<slug>`. The primary checkout stays clean.
- **A concurrency cap** (default 3). New requests are slotted: launched now, queued behind the
  in-flight set, or blocked by `Blocked by: #a, #b` in the issue body.
- **Self-review and auto-merge by default.** Per issue the operator can ask for manual approval;
  the builder then opens a PR and waits, and *"approve #N"* lands it.
- **Adoption.** Opened after other tabs are already working? The manager adopts them: a tab whose
  branch names an issue is bound to it; a tab with no issue pauses, writes its own issue, binds,
  and continues under the builder contract.
- **Issue hygiene** on every request: dedupe, union overlapping asks, split multi-deliverable
  requests, wire dependencies.

## Requirements

- [herdr](https://herdr.dev) as the terminal (the manager runs inside a herdr pane; `HERDR_ENV=1`)
- [`gh`](https://cli.github.com) authenticated; `git`; `jq`
- An agent CLI herdr can start as a builder (`omp` by default, see `bin/mgr`)

## Install

```sh
git clone https://github.com/orrgal1/manager-skill ~/code/manager-skill
~/code/manager-skill/install.sh          # symlinks ~/.claude/skills/manager -> the clone
```

The briefs handed to builders reference `~/.claude/skills/manager/…` by absolute path, so
keep the symlink there (or pass a different target to `install.sh` and adjust `SKILL.md`).

## Use

In a project, in a herdr tab: *"act as the manager"*. Then talk to it:

| You say | It does |
|---|---|
| add dark mode to settings | hygiene check → `gh issue create` → `mgr board` → launch or queue |
| I want to approve that one myself | adds `mgr:manual-approve` before launching |
| what's on the board | `mgr board` as a table |
| approve #12 | tells the builder to land; retires the tab when it reports merged |
| cancel #12 / set the cap to 2 / adopt the other tabs / dedupe the issues | see `SKILL.md` |

## Layout

| File | Role |
|---|---|
| `SKILL.md` | The manager's instructions (frontmatter is the trigger description) |
| `builder.md` | The builder contract every launched or adopted session follows |
| `bin/mgr` | `labels` · `board` · `launch` · `adopt` · `bind` · `wait` · `prompt` · `retire` — JSON out, exit codes `0/1/2/3/4` |
| `install.sh` | Symlinks the checkout into `~/.claude/skills/manager` |

## Protocol in one screen

```
operator ──▶ manager ──gh issue create──▶ GitHub issue #N
                │
                ├─ mgr launch N ──▶ worktree + herdr tab + builder + brief
                │                         │
                ├─ mgr wait N (background) │ builds · self-reviews · PR
                │                         ▼
                │              gh issue comment "manager-report: status=merged sha=… pr=…"
                ◀─────────────────────────┘
                └─ mgr retire N --close ──▶ mgr board ──▶ launch next ready issue
```

## License

MIT
