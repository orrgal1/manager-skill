# manager-skill

[![ci](https://github.com/orrgal1/manager-skill/actions/workflows/ci.yml/badge.svg)](https://github.com/orrgal1/manager-skill/actions/workflows/ci.yml)

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
- **A concurrency cap** (default 3; `MGR_CAP` or `--cap N`). New requests are slotted: launched
  now, queued behind the in-flight set, or blocked by `Blocked by: #a, #b` in the issue body.
- **Self-review and auto-merge by default.** Per issue the operator can ask for manual approval;
  the builder then opens a PR and waits, and *"approve #N"* lands it.
- **Adoption.** Opened after other tabs are already working? The manager adopts them: a tab whose
  branch names an issue is bound to it; a tab with no issue pauses, writes its own issue, binds,
  and continues under the builder contract.
- **A quota guard.** A plain daemon — not an agent — tracks provider usage, dials concurrency down
  to what fits before the window resets, and re-prompts sessions whose turn died on a rate limit,
  the manager's own included.
- **Issue hygiene** on every request: dedupe, union overlapping asks, split multi-deliverable
  requests, wire dependencies.

## Requirements

- [herdr](https://herdr.dev) as the terminal: the manager runs inside a herdr pane, and herdr
  exports the pane identity `mgr` needs — `HERDR_WORKSPACE_ID` for `launch`/`adopt`,
  `HERDR_PANE_ID` for `bind` and for the guard heartbeat
- [`gh`](https://cli.github.com) authenticated; `git`; `jq` (1.6+)
- `omp` as the builder agent: tabs are started with `herdr agent start --kind omp`, and the
  guard reads `omp usage` / `omp config list`
- a `main` branch in the project: every builder worktree is created from `main`

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
| set the priority to 8 | `mgr priority 8` — this project outranks the others when quota is tight |
| cancel #12 / set the cap to 2 / adopt the other tabs / dedupe the issues | see `SKILL.md` |

## Layout

| File | Role |
|---|---|
| `SKILL.md` | The manager's instructions (frontmatter is the trigger description) |
| `builder.md` | The builder contract every launched or adopted session follows |
| `bin/mgr` | `labels` · `board` · `launch` · `adopt` · `bind` · `wait` · `prompt` · `retire` · `guard` · `priority` |
| `bin/mgr-guard` | `start` · `stop` · `status` · `tick` · `run` · `register` · `stall` · `priority` — the quota daemon |
| `install.sh` | Symlinks the checkout into `~/.claude/skills/manager` |
| `test/run.sh` | The hermetic test suite |

Both binaries print JSON on stdout and `{"error":{"code":N,"message":"…"}}` on stderr, and
exit `0` ok · `1` unexpected · `2` usage · `3` refused / invalid state · `4` not found.

## Protocol in one screen

```
operator ──▶ manager ──gh issue create──▶ GitHub issue #N
                │
                ├─ mgr guard start ──▶ mgr-guard daemon ──omp usage──▶ allowed_total, cap_effective
                │                         └──herdr agent prompt "mgr-guard: …"──▶ stalled session
                ├─ mgr launch N ──▶ worktree + herdr tab + builder + brief
                │                         │
                ├─ mgr wait N (background) │ builds · self-reviews · PR
                │                         ▼
                │              gh issue comment "manager-report: status=merged sha=… pr=…"
                ◀─────────────────────────┘
                └─ mgr retire N --close ──▶ mgr board ──▶ launch next ready issue
```

## Quota guard

Builders and the manager are all agent sessions on one provider quota. When it runs out a turn ends
on a 429 and the pane just sits there — and the manager cannot be what notices, because it is
stalled on the same quota. So `bin/mgr-guard` is bash, not an agent:

- **Trajectory.** The builder provider is `omp config list --json` (`modelRoles.value.default`,
  falling back to `anthropic`). Every tick invalidates and re-reads
  `omp usage --json --provider <p>`, appends a sample per limit and least-squares-fits a burn rate
  over the last `MGR_GUARD_SLOPE_WINDOW_S`: `projected_at_reset = used + burn × hours_to_reset`.
  A sample span shorter than `MGR_GUARD_MIN_SLOPE_SPAN_S` counts as zero burn; samples older than
  24h are pruned.
- **Dial-back.** A limit projected past 100% shrinks `allowed_total` (never below 1); an exhausted
  one sets it to 0 until the window resets. `allowed_total` is water-filled over the live managers
  by demand into a per-manager `allotment`, and `mgr board` reports
  `cap_effective = min(cap, allotment)`. `launch` refuses when no slot is free; `adopt` never
  refuses — it returns `over_cap: true`, because leaving live work unmanaged is worse. Guard
  stopped or stale → no throttle at all.
- **Priorities.** Each project (repo) has a priority — `mgr priority N`, default 5, higher wins,
  machine-wide. While quota is constrained the guard serves whole tiers top-down instead of
  sharing evenly, so a bottom tier can drop to `allotment: 0`: its builders are interrupted with
  `esc` and resumed by the guard itself once the share is back. `mgr priority 0` is how you park a
  project — it is the bottom tier, so it is the first to be squeezed and the last to be served.
- **Stall detection.** For every `issue-*`, `adopt-*` and `manager*` agent that is not working, the
  guard reads the tail of the omp session JSONL: a last assistant message that stopped on an error
  with a 429 / rate-limit / quota-exhausted body is a stall.
- **Reignition.** Once the provider is no longer exhausted it runs
  `herdr agent prompt <pane> "mgr-guard: …"`, backing off per attempt (15 min doubling to a 2h cap).
  Managers are reignited exactly like builders — that is what breaks the deadlock, and no agent is
  involved.
- **Multi-manager ledger.** `~/.local/state/mgr-guard` (`MGR_STATE_DIR`) holds `guard.pid`,
  `guard.log`, `state.json`, `samples.jsonl`, `priorities.json` and one `managers/<id>.json` per
  manager, heartbeated by `mgr board`. One daemon serves every manager on the machine.

`mgr guard start` is idempotent, `mgr guard status` prints the verdict (and always exits 0), and the
daemon exits by itself once no manager has been seen for 30 minutes.

## Configuration

Everything is environment; there is no config file. The guard's integer knobs silently fall back to
their default when the value is not a positive integer; `MGR_CAP` is stricter — a non-numeric cap is
a usage error (exit `2`).

| Variable | Default | Effect |
|---|---|---|
| `MGR_CAP` | `3` | concurrency cap when `--cap N` is not passed |
| `MGR_GUARD_BIN` | `mgr-guard` next to `bin/mgr` | the guard executable `mgr` shells out to |
| `MGR_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/mgr-guard` | the guard's ledger directory |
| `MGR_GUARD_INTERVAL` | `60` | seconds between guard ticks (`mgr-guard start --interval S` wins) |
| `MGR_GUARD_SLOPE_WINDOW_S` | `1800` | window of usage samples the burn rate is fitted over |
| `MGR_GUARD_MIN_SLOPE_SPAN_S` | `300` | minimum sample span before a slope is trusted; below it, burn is 0 |
| `MGR_GUARD_IDLE_EXIT_S` | `1800` | the daemon exits after this long with no live manager |
| `MGR_GUARD_RESUME_COOLDOWN_S` | `300` | how long a paused builder waits before the guard may resume it |
| `MGR_GUARD_NOTIFY` | `1` | `0` silences the guard's herdr toasts |
| `MGR_GUARD_NOW_MS` | unset | pins the guard's clock in ms since the epoch; for tests |

`HERDR_WORKSPACE_ID`, `HERDR_PANE_ID` and `HERDR_TAB_ID` are exported by herdr, not by you.

## Testing

```sh
test/run.sh
```

`test/run.sh` runs the three tests in sequence, prints `PASS`/`FAIL` per test with the output of
any failure, and exits non-zero if one fails. The suite is hermetic: every test puts the fake
`gh`/`herdr`/`omp` it needs on its own temporary `PATH` and points `MGR_STATE_DIR` at a temporary
directory, so it touches no network, no real repo and no real state — `bash` and `jq` are all it
needs. Each script also runs standalone (`test/guard-smoke.sh`, `test/mgr-quota-smoke.sh`,
`test/e2e-quota.sh`) and exits non-zero on failure.

## Platform

macOS and Linux. `bash` 3.2 is enough — stock macOS bash runs everything and there are no
bash-4-only constructs — and `install.sh` is POSIX `sh`. Tools are used portably: the two places
that need a timestamp or an mtime (`guard.log` lines, the age of a stale start-lock) detect GNU
versus BSD `date`/`stat` explicitly, and `sed -E` and `mktemp -d` behave the same on both.

## License

MIT
