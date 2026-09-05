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
- **A concurrency cap** (default 3; `mgr config set cap N`, `MGR_CAP` or `--cap N`). New requests
  are slotted: launched now, queued behind the in-flight set, or blocked by `Blocked by: #a, #b`
  in the issue body.
- **Self-review and auto-merge by default.** Per issue the operator can ask for manual approval;
  the builder then opens a PR and waits, and *"approve #N"* lands it.
- **Adoption.** Opened after other tabs are already working? The manager adopts them: a tab whose
  branch names an issue is bound to it; a tab with no issue pauses, writes its own issue, binds,
  and continues under the builder contract.
- **A quota guard.** A plain daemon — not an agent — with two jobs: re-prompt sessions whose turn
  died on a provider rate limit once the quota renews, the manager's own session included, and keep
  a burn projection the manager reports to the operator. It never dials pace: the cap is the
  operator's alone.
- **One overview block.** `mgr overview` is machine-wide — every manager, every builder, which is
  the whole subscription: the burn and where it lands at reset, the backlog per repo, and an ETA per
  issue in flight and queued. The manager ends every turn with it. Read-only: nothing paces on it.
- **Issue hygiene** on every request: dedupe, union overlapping asks, split multi-deliverable
  requests, wire dependencies.
- **Harness config per repo.** `mgr config` stores extra omp CLI args, environment variables for
  builder tabs, an extra brief file and the cap in the repo's `.git/config` (`mgr.*`), so every
  worktree and every `mgr` call sees them without relying on the manager's memory or process env.

## Requirements

- [herdr](https://herdr.dev) as the terminal: the manager runs inside a herdr pane, and herdr
  exports the pane identity `mgr` needs — `HERDR_WORKSPACE_ID` for every command,
  `HERDR_PANE_ID` for `bind` and for the guard heartbeat
- [`gh`](https://cli.github.com) authenticated; `git`; `jq` (1.6+)
- `omp` as the builder agent: tabs are started with `herdr agent start --kind omp`, and the
  guard reads `omp usage` / `omp config list`
- a `main` branch in the project: every builder worktree is created from `main`

## Install

```sh
git clone https://github.com/orrgal1/manager-skill ~/code/manager-skill
~/code/manager-skill/install.sh          # symlinks ~/.claude/skills/manager -> the clone
~/code/manager-skill/install.sh --omp-extension   # also links extensions/mgr-status.ts into ~/.omp/agent/extensions/ (adopted and manager sessions)
```

Builders launched by `mgr launch` get the status-line extension automatically — `mgr` passes
`--extension <checkout>/extensions/mgr-status.ts` to omp itself — so `--omp-extension` is only
needed for sessions `mgr` did not start: adopted tabs and the manager's own.

`mgr` resolves `builder.md` and its own path from its real location (symlinks followed), so the
briefs work from the symlink or from `node_modules`.

## As a dependency

```sh
pnpm add github:orrgal1/manager-skill     # or: npm install github:orrgal1/manager-skill
node_modules/.bin/mgr paths               # {"root","skill_md","builder_md","mgr"} — absolute
node_modules/.bin/mgr --version           # {"version":"…"}
```

The runtime dependencies are unchanged: `bash`, `git`, `gh`, `jq` and [herdr](https://herdr.dev)
still have to be on `PATH`. To start a manager from a consumer repo, prompt a session with
*"Read `<skill_md>` and act as the manager"*.

## Use

In a project, in a herdr tab: *"act as the manager"*. Then talk to it:

| You say | It does |
|---|---|
| add dark mode to settings | hygiene check → `gh issue create` → `mgr board` → launch or queue |
| I want to approve that one myself | adds `mgr:manual-approve` before launching |
| what's on the board | `mgr board` as a table |
| approve #12 | tells the builder to land; retires the tab when it reports merged |
| pause the project | `mgr pause` — a launch gate: a persisted cap 0 for this repo until `mgr unpause`, so nothing new launches. The builders already running keep going to their report; nothing is retired, no tab, worktree or issue is touched |
| unpause / resume the project | `mgr unpause` (alias `mgr resume`) — the cap goes back to `--cap`/`MGR_CAP`/config/`3` and the ready issues launch |
| quota status / overview / what's coming | `mgr overview` — one block: burn, backlog, per-issue ETAs (see **Overview**) |
| cancel #12 / set the cap to 2 / adopt the other tabs / dedupe the issues | see `SKILL.md` |

## Headless use

External tooling can drive `mgr` outside a pane: export `HERDR_WORKSPACE_ID` and run from a cwd
inside the repo. Every command except `bind` works that way — `HERDR_PANE_ID` only matters for
`bind`, for `board.self` and for the guard heartbeat.

```sh
HERDR_WORKSPACE_ID=<ws> mgr board
HERDR_WORKSPACE_ID=<ws> mgr overview --json

mgr config add omp-arg --extension
mgr config add omp-arg /abs/ext.ts
mgr config add env LINK=ws://127.0.0.1:1234/link
mgr config set brief-extra /abs/directive.md
mgr config list
```

Precedence: CLI flag > `MGR_*` env > git config (`mgr config`) > built-in default.

`board.manager` is how you find the manager tab — the live agent whose tab label is `manager` —
or `null` when there is none. `omp-arg` and `env` apply to newly launched builders only;
`brief-extra` also reaches adopted sessions.

## Layout

| File | Role |
|---|---|
| `SKILL.md` | The manager's instructions (frontmatter is the trigger description) |
| `builder.md` | The builder contract every launched or adopted session follows |
| `bin/mgr` | `labels` · `board` · `overview` · `launch` · `adopt` · `bind` · `wait` · `prompt` · `retire` · `guard` · `pause` · `unpause` (`resume`) · `config` · `paths` · `--version` |
| `bin/mgr-guard` | `start` · `stop` · `status` · `overview` · `tick` · `run` · `register` · `touch` · `stall` — the quota daemon |
| `extensions/mgr-status.ts` | omp status-line indicator: rate-limited / guard stopped / project paused, optional burn item |
| `install.sh` | Symlinks the checkout into `~/.claude/skills/manager`; `--omp-extension` also links the status-line extension into `~/.omp/agent/extensions/` |
| `package.json` | npm/pnpm manifest; `bin.mgr` → `bin/mgr` |
| `test/run.sh` | The hermetic test suite |

Both binaries print JSON on stdout and `{"error":{"code":N,"message":"…"}}` on stderr, and
exit `0` ok · `1` unexpected · `2` usage · `3` refused / invalid state · `4` not found.

## Protocol in one screen

```
operator ──▶ manager ──gh issue create──▶ GitHub issue #N
                │
                ├─ mgr guard start ──▶ mgr-guard daemon ──omp usage──▶ burn projection
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
stalled on the same quota. So `bin/mgr-guard` is bash, not an agent, and it has exactly two
purposes: **reignite what the quota stopped**, and **keep a burn projection** the manager shows the
operator. Nothing acts on the projection.

- **Stall detection.** For every `issue-*`, `adopt-*` and `manager*` agent that is not working, the
  guard reads the tail of the omp session JSONL: a last assistant message that stopped on an error
  with a 429 / rate-limit / quota-exhausted body is a stall. The entry keeps the pane, the
  workspace, the provider, the error, `since`, the `recovers_at` of the limit that caused it, the
  manager it belongs to, and the reignite attempts so far.
- **Reignition.** A stalled pane is re-prompted only when the quota is *observably* back: this
  tick's usage fetch succeeded and the provider reads `ok` or `warning`, or the `recovers_at` of the
  limit that caused the 429 has passed. Never on `unknown`, and never on `exhausted` with the reset
  still ahead. When a usage fetch fails the guard holds the last verdict — a provider known
  exhausted until 17:00Z stays exhausted until 17:00Z instead of looking recovered because
  `omp usage` was unreachable. Each pane backs off on its own (15 min, doubling to a 2 h cap), and
  the prompt states the reading it acted on: `mgr-guard: anthropic:5h reset at
  2026-09-05T17:00:00Z, now at 12%. Your previous turn stopped on a provider rate limit (429). …`,
  or, on the `recovers_at` path with no fresh reading, that the reset time has passed and no reading
  is available. It never claims a quota is back over a 100% reading. Managers are reignited exactly
  like builders — that is what breaks the deadlock, and no agent is involved. A reignite is also the
  guard's only desktop toast (`MGR_GUARD_NOTIFY`).
- **The projection.** The builder provider comes from `omp config list --json`
  (`modelRoles.value.default`, falling back to `anthropic`). Every tick invalidates and re-reads
  `omp usage --json --provider <p>` and records, per limit, `used`, `resets_at`, a least-squares
  `burn_per_hour` over the last `MGR_GUARD_SLOPE_WINDOW_S`,
  `projected_at_reset = used + burn × hours_to_reset`, `fits` (`projected_at_reset ≤ 1`) and the
  `{t, used}` samples the fit used. Samples are matched to a limit by *window*, not by the raw
  stamp — `omp usage` reports `resets_at` with per-call millisecond jitter, so a sample belongs to
  the current window when its `resets_at` is within 120 s of the limit's (both null matches too),
  and the slope is fitted over every matched sample instead of the two that happened to collide on
  the same millisecond. A sample span shorter than `MGR_GUARD_MIN_SLOPE_SPAN_S` counts as zero burn;
  samples older than 24h are pruned. The guard also writes one sentence per provider about the worst
  limit — `anthropic:5h at 20% burning 0.2/h → 2.56× the window by 17:00Z`, `anthropic:5h
  exhausted, resets at 17:00Z`, or `fits`.
- **Surfacing it.** `mgr board` passes the projection through as `quota.limits[]` and
  `quota.reason`, and compares it with the projection it last returned for this manager
  (`MGR_STATE_DIR/managers/<manager_id>.last_report.json`). When some limit's `fits` flipped, its
  `projected_at_reset` moved by `0.1` or more, or it is new, the board returns `quota.changed: true`
  with `quota.delta` describing it — `anthropic:5h 1.04× → 2.56× (now over)`. That is change
  detection for the operator's benefit, nothing more: what the manager actually says at the end of
  every turn is the `mgr overview` block, which carries the same limits with their `exhaust_at`.
- **Backlog for the overview.** Every `MGR_GUARD_BACKLOG_INTERVAL_S` (default 120 s) the guard also
  refreshes each live manager's repo itself (`gh issue list`, the same ready/blocked/in-flight rules
  `mgr board` uses) into `managers[].backlog` with `backlog_at`, and recomputes that repo's
  `throughput` from `MGR_STATE_DIR/throughput/`, so the overview is fresh machine-wide even for a
  manager that has not run a command in a while — see **Overview**.
- **What it never does.** It computes no ceiling on how many builders may run: no `allowed_total`,
  no priority ranking, no water-filling, no per-manager allotment, no second cap. It never pauses,
  holds or interrupts a running builder — the only keystrokes it ever sends are a reignite prompt to
  a pane that already stopped. `cap` is the operator's only pace dial and `mgr` enforces it alone
  (`slots_free = cap − (in_flight + adopting)`). `mgr pause` is a launch gate owned by `mgr`, not by
  the guard: a persisted cap 0 in the primary checkout's `.git/config` (`mgr.paused`), so `launch`
  refuses and `board` reports `paused_by_operator` while the builders already running keep going.
  The guard knows nothing about it.
- **Multi-manager ledger.** `~/.local/state/mgr-guard` (`MGR_STATE_DIR`) holds `guard.pid`,
  `guard.log`, `state.json`, `samples.jsonl`, `exit.json`, one `managers/<id>.json` per manager —
  heartbeated by every `mgr` call (`mgr board` writes the full registration: manager id, repo, pane,
  cap, in-flight and `paused_by_operator`, for attribution and for the status line only — the guard
  never reads the pause; every other subcommand stamps `seen_at`) — and the
  `managers/<id>.last_report.json` the board writes for change detection. One daemon serves every
  manager on the machine.

`mgr guard start` is idempotent, `mgr guard status` prints the whole state (and always exits 0), and
the daemon exits by itself only after 30 minutes with no live manager pane and no stalled pane. A
manager is live while its herdr pane exists (`herdr agent list`); heartbeat age is informational, so
`guard status` reports both `managers[].pane_alive` and `managers[].seen_at` — that is what keeps a
429-stalled manager, which runs no commands at all, from being written off. When the daemon does
exit it records why, and `mgr guard status` and `mgr board` report it as
`last_exit_at` / `last_exit_reason`.

## Overview

`mgr overview` is the one block the manager prints at the end of every turn — every turn, including
the ones that only answered a question. It is **machine-wide** by design: every manager registered
with the guard and every builder they have running, because the quota is one subscription and not
one project. `--json` returns the object behind the block, `mgr board` embeds the same object as
`overview`, and `--limit N` decides how much of the queue is listed.

```
burn     anthropic:5h 80% @0.46/h → 2.2× by 17:00 (exhausts ~15:10, stalls 1h50) · week 20% @0.02/h → 12.6× by Sat 09:00
backlog  open 31 · ready 14 · blocked 3 · in flight 2/4 slots · idle 2 (shape) — shape starves NOW, manager-skill in ~3h10
next     #23 in flight → 15:05 · #24 → 15:40 · #25 ⊘#23 → 16:30 · #26 → 18:20 (after 5h reset) · #27 → 19:05
beyond   +17 queued (3 blocked), last ~Sat 09:40 · ~1h05/task (n=12)
drains   manager-skill Sat 09:40 · shape — · livinglore 16:10
```

- **`burn`** — one entry per provider limit: how much of the window is used, the measured burn rate,
  where that lands at reset (`2.2×` is 2.2 windows' worth) and when the window resets. A limit that
  does not fit also says when it runs out and how long the stall to the reset is. The first limit of
  a provider prints its full id, the rest only the window (`week`). No reading at all: `no reading`.
- **`backlog`** — the true totals across every live manager: open issues, `ready` (launchable now),
  `blocked`, in flight over the sum of the caps, and idle slots with the repos holding them. After
  the dash, per manager, when it runs out of queue: `starves NOW` or `in ~3h10`.
- **`next`** — every in-flight issue first, then the queued ones by ETA. `⊘#23` means it waits on
  #23; an issue in another repo is prefixed with that repo (`shape#12`); `(after 5h reset)` marks
  the first issue that only finishes after the quota window reopens. It wraps to at most three
  lines, and a trailing `· …` means more items than fit.
- **`beyond`** — the queue that is not listed: how many, how many of those are blocked, the ETA of
  the last one, and the per-task median and sample count of the repo holding most of them. The line
  is omitted when nothing is hidden.
- **`drains`** — per manager, when its queue empties; `—` when it does not (empty queue, or nothing
  schedulable).

Times are in the local zone, with a `Z` suffix when `TZ` is unset and a weekday prefix when the day
is not today. Durations are rounded to 5 minutes. A `~` anywhere means the number rests on an
estimated duration.

**Ten by default.** `next` lists every in-flight issue and then the next 10 queued; `--limit N`
changes that (`--limit 50` for the whole queue, which is what the manager runs when the operator
asks to see all of it). The simulation itself always covers every queued issue of every manager —
only the display is capped, and `beyond` carries the size and shape of what it left out.

**Where the ETAs come from.** Each repo's task duration is the median of its own history:
`mgr launch`, `mgr adopt <pane> N` and `mgr bind N` record `launched_at` in
`MGR_STATE_DIR/launches/<owner>__<repo>.json`, and `mgr retire N` on a *merged* report appends
`{repo, number, launched_at, merged_at, duration_s}` to
`MGR_STATE_DIR/throughput/<owner>__<repo>.jsonl`. Under 3 rows for a repo it falls back to the
machine-wide median over every repo, and with no history anywhere to `MGR_DEFAULT_TASK_S` (2700 s,
45 min). Both fallbacks are flagged `estimated` and render as `~` — durations are a heuristic, and
the block says so instead of hiding it.

From there, per manager: an in-flight issue is due at
`launched_at + max(median, elapsed + ¼ median)`, so a builder that has already outrun the median is
not predicted to land this second. The queue is FIFO by issue number over `cap` parallel slots; a
queued issue starts when a slot frees and every open blocker of its own has an ETA in the past, and
an issue nothing can schedule (a dependency cycle) gets no ETA. Projected work skips the **stall
window** — the `[exhaust_at, resets_at]` of the earliest-exhausting limit in the burn projection —
so a task that would straddle a dead quota resumes at the reset instead of finishing through it.
`idle_slots` are free slots with nothing ready to fill them, and `starves_at` is when a manager's
queue empties while it still has slots: that is the "work for the next ~3h, then it idles" reading.

The data is the guard's: it refreshes every live manager's repo on its own tick (see **Quota
guard**), so the block is machine-wide and fresh even for a manager that has been quiet, and it
works whenever `state.json` exists — `mgr overview` reads it with `mgr-guard overview`, no daemon
required. The ledger row keeps at most 50 ready and 50 blocked entries per repo (with the true
counts); the full queue lives in `MGR_STATE_DIR/backlog/<owner>__<repo>.json`, and that is what
the simulation runs over — a repo with 200 open issues gets 200 ETAs and shows ten. A guard that
predates this feature has no snapshot yet: restart it (`mgr guard stop`, `mgr guard start`) and
the next tick fills the backlog in. Nothing in the harness acts on any of it: the cap is still the
operator's only pace dial.

## Status line

Every builder tab carries a one-line omp status indicator, so the operator can see a quota hold
from the tab itself instead of asking the manager (which may be stalled on the same quota):

- **Rate-limited.** `⏳ rate-limited on anthropic:5h, guard reignites after 17:00Z` — the limit
  that stopped this pane and the UTC time the guard expects the quota back. With no reset time
  known yet it reads `⏳ rate-limited on anthropic:5h, guard reignites when the quota renews`.
- **Guard stopped.** When the ledger says the daemon is stopped or stale, the stall line gains
  ` (guard stopped — run mgr guard start)`: nothing is going to reignite the pane until it is back.
- **Project paused.** `⏸ project paused (mgr unpause to resume launches)` — the operator's pause,
  from this manager's registration. A stall outranks it.
- **Burn**, opt-in with `MGR_STATUS_BURN=1`: `🔥 anthropic:5h 20% 0.2/h → 2.56× by 17:00Z`, the
  worst limit projected past its window.

How it works: the extension polls `state.json` every `MGR_STATUS_INTERVAL_S` seconds (default 5)
on omp's managed timer, stats the file first and re-parses only when the mtime moved, and tolerates
a missing or half-written ledger by keeping the last good reading. It finds itself by
`HERDR_PANE_ID` in `stalled[]` and its manager by `HERDR_WORKSPACE_ID` in `managers`. There is no
new guard channel and no new file: it reads what the guard already writes. It is UI only — nothing
it shows ever reaches the reignite prompt or the brief.

In a headless, print or subagent session, or with no `HERDR_PANE_ID`, it is a no-op and starts no
timer at all. Every `mgr launch` passes `--extension <checkout>/extensions/mgr-status.ts`;
`install.sh --omp-extension` links it into `~/.omp/agent/extensions/` for adopted and manager
sessions. A session that gets it both ways loads it twice and activates it once.

## Configuration

The guard is all environment. The per-repo harness config — extra omp args, builder-tab env, an
extra brief file, the cap — lives in the repo's `.git/config` under `mgr.*` (`mgr config`), and the
`MGR_*` variables below override it. The guard's integer knobs silently fall back to their default
when the value is not a positive integer; `MGR_CAP` is stricter — a non-numeric cap is a usage
error (exit `2`).

| Variable | Default | Effect |
|---|---|---|
| `MGR_CAP` | `3` | concurrency cap when `--cap N` is not passed; overrides `mgr.cap` |
| `MGR_OMP_ARGS` | unset | whitespace-separated extra omp argv; replaces `mgr.omp-arg` |
| `MGR_ENV` | unset | whitespace-separated `KEY=VALUE` for builder tabs; replaces `mgr.env` |
| `MGR_BRIEF_EXTRA` | unset | path to a markdown file appended to every brief; overrides `mgr.brief-extra` |
| `MGR_GUARD_BIN` | `mgr-guard` next to `bin/mgr` | the guard executable `mgr` shells out to |
| `MGR_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/mgr-guard` | the guard's ledger directory |
| `MGR_GUARD_INTERVAL` | `60` | seconds between guard ticks (`mgr-guard start --interval S` wins) |
| `MGR_GUARD_SLOPE_WINDOW_S` | `1800` | window of usage samples the burn rate is fitted over |
| `MGR_GUARD_MIN_SLOPE_SPAN_S` | `300` | minimum sample span before a slope is trusted; below it, burn is 0 |
| `MGR_GUARD_IDLE_EXIT_S` | `1800` | the daemon exits after this long with no live manager pane and no stalled pane |
| `MGR_GUARD_BACKLOG_INTERVAL_S` | `120` | seconds between the guard's per-repo `gh issue list` refreshes for the overview |
| `MGR_DEFAULT_TASK_S` | `2700` | task duration assumed for the overview when there is no throughput history at all |
| `MGR_GUARD_NOTIFY` | `1` | `0` silences the guard's herdr toasts (a reignite is the only one) |
| `MGR_GUARD_NOW_MS` | unset | pins the guard's clock in ms since the epoch; for tests |
| `MGR_STATUS_INTERVAL_S` | `5` | seconds between status-line polls of the guard's ledger |
| `MGR_STATUS_BURN` | unset | `1` shows the burn item in the status line |

`HERDR_WORKSPACE_ID`, `HERDR_PANE_ID` and `HERDR_TAB_ID` are exported by herdr, not by you —
except in headless use, where the caller sets `HERDR_WORKSPACE_ID` itself.

## Testing

```sh
test/run.sh
```

`test/run.sh` runs the five tests in sequence, prints `PASS`/`FAIL` per test with the output of
any failure, and exits non-zero if one fails. The suite is hermetic: every test puts the fake
`gh`/`herdr`/`omp` it needs on its own temporary `PATH` and points `MGR_STATE_DIR` at a temporary
directory, so it touches no network, no real repo and no real state — `bash` and `jq` are all it
needs. Each script also runs standalone (`test/guard-smoke.sh`, `test/mgr-quota-smoke.sh`,
`test/mgr-config-smoke.sh`, `test/e2e-quota.sh`, `test/mgr-status-unit.sh`) and exits non-zero on
failure. `test/mgr-status-unit.sh` is the one exception to the `bash`+`jq` rule: it is a `bun` unit
test of the status-text mapping (`bun` is what omp itself runs on).

The overview is covered across two of them: the projection fixtures — stall window from the burn,
FIFO with a cap and a blocker, ETAs skipping a stall window, starvation, the throughput fallback
chain, a 40-issue queue — in `test/guard-smoke.sh`, and `mgr overview --json`, the rendered block,
`--limit`, `mgr retire`'s throughput row and `board.overview` in `test/mgr-quota-smoke.sh`.

## Platform

macOS and Linux. `bash` 3.2 is enough — stock macOS bash runs everything and there are no
bash-4-only constructs — and `install.sh` is POSIX `sh`. Tools are used portably: the two places
that need a timestamp or an mtime (`guard.log` lines, the age of a stale start-lock) detect GNU
versus BSD `date`/`stat` explicitly, and `sed -E` and `mktemp -d` behave the same on both.

## License

MIT
