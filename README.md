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
  (`mgr:in-flight`, `mgr:awaiting-approval`, `mgr:awaiting-plan`) and the per-issue policy
  (`mgr:manual-approve`, `mgr:plan-approve`).
- **One builder per issue**, in a [herdr](https://herdr.dev) tab named `#N <slug>`, on branch
  `issue-N-<slug>`, in worktree `<repo>-issue-N-<slug>`. The primary checkout stays clean.
- **Every issue is sized.** Intake puts exactly one `size:tiny` / `size:small` / `size:medium` /
  `size:large` label on the issue (`mgr size N <size>` changes one that is not in flight), the
  brief names the size, and `mgr launch` sends the session to `workflows/<size>.md` — the whole
  build-and-verify process at that size: what may be delegated, which checks run and which never
  do. Intake sizes from evidence, not a glance: unless the request is obviously `tiny` or the
  operator named the files, the manager dispatches one read-only `scout` before it labels — it
  does not read the repo itself — and leaves that map in the issue's `## Notes` under
  `### Intake map`, which the builder's own step 1 then narrows or skips its scouting against.
  Every session runs on `--model @builder`, the house's top rung, with `omp/packages/<house>.yml`
  overlaid, so the size picks the workflow and the agents slices go to, never the model. A builder
  that outgrows its size resizes upward itself. The builder's own context is for orchestration and
  integration — its scouts and its size's planner (`sketch` at `medium`, `plan` at `large`; `small`
  plans in-session, `tiny` does neither) do the reading and the deciding and return compressed,
  its own in-session implementation capped by the ceiling in the builder contract (builder.md
  §7) — and it can delegate the planning without resizing. A fumble trigger (builder.md §7)
  hands one step to a fresh `crux` agent on the top rung instead, with the size, workflow file
  and checks unchanged. The review pass follows the same rule: the reviewer and the rung follow
  the diff surface (builder.md §7) — `reviewer`, with `security-reviewer` beside it for auth or
  permissions, on the top rung; `sweep`, the same review contract, on the work rung. The full
  suite follows the diff surface too, gated by a per-repo `rigor` dial (`mgr config set rigor`,
  `MGR_RIGOR`; default `production`) rather than the size (builder.md §7).
  A per-repo `sizing` dial (`mgr config set sizing`, `MGR_SIZING`; `lean|balanced|careful`,
  default `balanced`) biases the size call when intake or a builder cannot decide a size
  outright — it never demotes a decided classification.
- **One model package per subscription.** `mgr setup` installs the eight agents (`tiny`, `small`,
  `medium`, `large`, `plan`, `sketch`, `crux`, `sweep`) into the omp agent directory and applies
  `omp/packages/<house>.yml`; `mgr package <house>` switches houses (`anthropic`, `openai`,
  `gemini`) later. One YAML per house maps every role to one rung of that subscription's ladder.
  Every launch also overlays a `model-fallback` policy (`mgr config set model-fallback`,
  `MGR_MODEL_FALLBACK`; `never`\|`ask`\|`auto`, default `never`) that gates the coding-plan
  fallback dialog; `mgr setup`/`mgr package` write `retry.fallbackChains` into the omp config only
  when that policy is `auto`.
- **A concurrency cap** (default 3; `mgr config set cap N`, `MGR_CAP` or `--cap N`). New requests
  are slotted: launched now, queued behind the in-flight set, or blocked by `Blocked by: #a, #b`
  in the issue body.
- **Self-review and auto-merge by default.** Per issue the operator can ask for manual approval;
  the builder then opens a PR and waits, and *"approve #N"* lands it.
- **Adoption.** A tab you did not launch is adopted only on request: it runs `mgr register [N]`
  under the `register-builder` skill, the manager gets its `register-builder:` message and
  answers with `mgr adopt` — a request naming its own issue (or a branch that names one) binds to
  it; one with no issue pauses, writes its own issue, binds, and continues under the builder
  contract. The operator can also name a pane by id directly.
- **A quota guard.** A plain daemon — not an agent — with two jobs: re-prompt sessions whose turn
  died on a provider rate limit once the quota renews, the manager's own session included, and keep
  a burn projection the manager reports to the operator. It never dials pace: the cap is the
  operator's alone.
- **One overview block.** `mgr overview` ends every turn with `quota`, `work` and `next`: `quota`
  is scoped to the calling manager's own provider — its effective house's subscription — because a
  manager on Anthropic cannot spend an OpenAI quota; `work` and `next` are scoped to the repo the
  command was run in. `--json` (and `mgr guard status`) stay machine-wide by design — every
  provider the guard polled, for other tooling to read. Read-only: nothing paces on it.
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
~/code/manager-skill/install.sh          # symlinks ~/.claude/skills/manager and ~/.claude/skills/register-builder -> the clone
~/code/manager-skill/install.sh --omp-extension   # also links extensions/mgr-status.ts into ~/.omp/agent/extensions/ (adopted and manager sessions)
~/code/manager-skill/install.sh --omp             # also runs `bin/mgr-package setup`: the eight agents (tiny, small, medium, large, plan, sketch, crux, sweep) into ~/.omp/agent/agents/ and the house's model package into its config.yml
```

Builders launched by `mgr launch` get the status-line extension automatically — `mgr` passes
`--extension <checkout>/extensions/mgr-status.ts` to omp itself — so `--omp-extension` is only
needed for sessions `mgr` did not start: adopted tabs and the manager's own.

`mgr` resolves `builder.md`, the `workflows/` directory and its own path from its real location
(symlinks followed), so the briefs work from the symlink or from `node_modules`.

## As a dependency

```sh
pnpm add github:orrgal1/manager-skill     # or: npm install github:orrgal1/manager-skill
node_modules/.bin/mgr paths               # {"root","skill_md","builder_md","workflows","omp","mgr"} — absolute
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
| I want to see the plan first | adds `mgr:plan-approve` before launching |
| what's on the board | `mgr board` as a table |
| approve #12 | tells the builder to land; retires the tab when it reports merged |
| pause the project | `mgr pause` — a launch gate: a persisted cap 0 for this repo until `mgr unpause`, so nothing new launches. The builders already running keep going to their report; nothing is retired, no tab, worktree or issue is touched |
| unpause / resume the project | `mgr unpause` (alias `mgr resume`) — the cap goes back to `--cap`/`MGR_CAP`/config/`3` and the ready issues launch |
| quota status / overview / what's coming | `mgr overview` — one block: quota (the calling manager's own provider), this repo's work and queue (see **Overview**) |
| register this session with the manager | that session runs `mgr register [N]` itself (the `register-builder` skill); the manager answers its `register-builder:` message with `mgr adopt` |
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
mgr config set rigor sprint
mgr config set sizing lean
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
| `register-builder/SKILL.md` | The instructions a session follows to ask the manager to adopt it — `mgr register [N]` from its own pane |
| `builder.md` | The builder contract every launched or adopted session follows |
| `workflows/<size>.md` | The four size workflows — `tiny` · `small` · `medium` · `large` — that `builder.md` hands build and verify off to |
| `bin/mgr` | `labels` · `board` · `overview` · `launch` · `adopt` · `bind` · `register` · `wait` · `prompt` · `retire` · `size` · `guard` · `pause` · `unpause` (`resume`) · `config` · `package` · `setup` · `house` · `paths` · `--version` — on a merged report `retire` also writes the execution record to the ledger and the issue, and returns `execution_recorded` |
| `bin/mgr-guard` | `start` · `stop` · `status` · `overview` · `tick` · `run` · `register` · `touch` · `stall` — the quota daemon |
| `bin/mgr-package` | `package` · `setup` — installs the size agents and applies a model package into the omp config; reached as `mgr package` / `mgr setup` |
| `omp/packages/<house>.yml` | One model package per subscription — `anthropic` · `openai` · `gemini`: `modelRoles`, `task.agentModelOverrides`, `retry.fallbackChains` |
| `omp/policies/model-fallback-{never,ask,auto}.yml` | Per-launch omp `--config` overlays for the coding-plan fallback dialog: `never` disables it, `ask` allows it (relayed to the operator, never answered), `auto` lets the harness switch models on its own |
| `omp/agents/<name>.md` | The eight agent files `mgr setup` installs: `tiny` · `small` · `medium` · `large` · `plan` · `sketch` · `crux` · `sweep` |
| `extensions/mgr-status.ts` | omp status-line indicator: rate-limited / guard stopped / project paused, optional burn item |
| `install.sh` | Symlinks the checkout into `~/.claude/skills/manager`; `--omp-extension` also links the status-line extension into `~/.omp/agent/extensions/`, `--omp` also runs `mgr-package setup` |
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
                ├─ session mgr register [N] ──▶ "register-builder: pane P [issue N]" ──▶ mgr adopt P [N] ──▶ (no N) mgr bind N
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
- **The projection.** Each tick polls the union of every live manager's registered provider and
  every stalled pane's provider — a machine running an Anthropic manager and an OpenAI manager
  samples both subscriptions every tick. Only when that union is empty (no manager registered, or
  none of them resolved a provider) does it fall back to the machine default from
  `omp config list --json` (`modelRoles.value.default`, falling back to `anthropic`) — the same
  value `state.builder_provider` always carries, informational once managers are registered. Every
  polled provider invalidates and re-reads `omp usage --json --provider <p>` and records, per
  limit, `used`, `resets_at`, a least-squares `burn_per_hour` over the last
  `MGR_GUARD_SLOPE_WINDOW_S`, `projected_at_reset = used + burn × hours_to_reset`, `fits`
  (`projected_at_reset ≤ 1`) and the `{t, used}` samples the fit used. Samples are matched to a
  limit by *window*, not by the raw stamp — `omp usage` reports `resets_at` with per-call
  millisecond jitter, so a sample belongs to the current window when its `resets_at` is within
  120 s of the limit's (both null matches too), and the slope is fitted over every matched sample
  instead of the two that happened to collide on the same millisecond. A sample span shorter than
  `MGR_GUARD_MIN_SLOPE_SPAN_S` counts as zero burn; samples older than 24h are pruned. The guard
  also writes one sentence per provider about the worst limit — `anthropic:5h at 20% burning 0.2/h
  → 2.56× the window by 17:00Z`, `anthropic:5h exhausted, resets at 17:00Z`, or `fits`.
- **Surfacing it.** `mgr board` resolves the calling manager's own provider — its effective house's
  subscription (`$MGR config get house`, else the session's own house) — and passes that
  provider's projection through as `quota.provider`, `quota.status`, `quota.limits[]` and
  `quota.reason`; a provider the guard has not sampled yet reads `status: null`, `limits: []`,
  exactly the existing no-reading path, never another provider's numbers. `quota.managers[]`
  carries `provider` per manager, so cross-provider attribution stays inspectable even though the
  summary itself is scoped. The board also compares the projection with the one it last returned
  for this manager (`MGR_STATE_DIR/managers/<manager_id>.last_report.json`). When some limit's
  `fits` flipped, its `projected_at_reset` moved by `0.1` or more, or it is new, the board returns
  `quota.changed: true` with `quota.delta` describing it — `anthropic:5h 1.04× → 2.56× (now over)`.
  That is change detection for the operator's benefit, nothing more: what the manager actually says
  at the end of every turn is the `mgr overview` block, which carries the same limits with their
  `exhaust_at`.
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
  cap, in-flight, `paused_by_operator`, and its effective `house`/`provider` — both `null` when
  unresolvable — for attribution, for the guard's poll set (only a `provider` matching
  `^[A-Za-z0-9._:-]+$` is ever polled; anything else is dropped, not fetched) and for the status
  line only; the guard
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
the ones that only answered a question. `quota` is scoped to **the calling manager's own
provider** — its effective house's subscription — so the burn projection it prints is the quota
this manager actually draws on, not every subscription sampled on the machine. `work` and `next`
are scoped to the repo the command was run in — the queue, the running builders and the per-issue
ETAs it lists are this repo's own, never another manager's, and those ETAs are projected against
this manager's own stall window too: a limit on a subscription it cannot spend never shifts
`work`'s or `next`'s timing and never appears in a `(after the ... reset)` mark (see **Quota
guard**). `--json` returns the full object
behind the block, and it stays **machine-wide by design**: every provider the guard polled, plus
every manager's queue, unfiltered — other tooling reads it, and `mgr guard status` is the same
daemon-wide record. `mgr board` embeds the same machine-wide object as `overview`; only the text
render above filters it. `--limit N` decides how much of this repo's own queue is listed.

```
quota    5-hour 80% used, runs out in ~30m, resets in 2h00 (14:00Z) · weekly 20% used · shared with 1 other project
work     1 of 2 builders running, 10 ready, 1 blocked · out of work in 6h45 (18:45Z) · queue clear in 7h30 (19:30Z)
next     #49 running on claude-opus-5 (launched on claude-fable-5-1), 15m left · #7 in 2h30 (after the 5-hour reset)
         #8 in 2h45 · #9 in 3h30 · #10 in 3h45 · #11 in 4h30 · #12 in 4h45 · #13 in 5h30 · #14 in 5h45 · +3 more
```

- **`quota`** — scoped to the calling manager's own provider, one entry per limit of that provider
  that has a reading, worst first: a limit that does not fit before its own reset comes first
  (earliest run-out first), then the rest by most used. Plain limit names come from the id: the
  provider prefix is dropped and the window token mapped (`5h` → `5-hour`, `week`/`weekly`/`7d` →
  `weekly`, `1d`/`day`/`24h` → `daily`, `1h` → `hourly`, `<N>h` → `<N>-hour`, `<N>d` → `<N>-day`,
  anything else kept verbatim); a further id segment is appended in parentheses, so
  `anthropic:7d:fable` reads `weekly (fable)`. The first limit gets the full sentence — percent
  used, when it runs out, when the window resets; every other limit gets a short one. Other
  managers on the **same provider**, in a different repo, show up only as `shared with N other
  project(s)` — never by name, never with their own queue; a manager on a different provider is not
  drawing on this quota and is never counted. That provider having no reading yet renders `no
  quota reading yet` — never another provider's numbers. A caller with no resolvable house or
  provider (no pane, no stored house) is not a manager on any subscription, so the line falls back
  to today's unfiltered rendering — every sampled provider's limits, sharers counted regardless of
  provider — because filtering to nothing would hide readings that do exist; its board still
  reports `quota.provider: null`.
- **`work`** — this repo only: how many builders are running out of the cap, how many issues are
  ready / blocked / awaiting approval / waiting on the plan, whether a slot is free right now — and
  if so, whether nothing is ready to fill it (`N free slot(s), nothing ready to launch`) — or when
  the last slot runs out of work, and when this repo's own queue clears. Nothing to report at all
  renders as `nothing running, nothing queued` (no `next` line follows); an unregistered repo reads
  `this repo is not registered with the guard`; outside a repo entirely it reads `not inside a
  repo, so there is no queue to show`.
- **`next`** — this repo's issues only: the in-flight ones first with the time left, then the
  queued ones with the wait. An in-flight entry reads `#N running on <model>, <time left>`, with
  ` (launched on <launch model>)` after the model — the bare id — when the harness switched the
  builder off its launch model. `(needs #7, #9)` marks one or more blockers, `(after the <window>
  reset)` marks the first issue that only lands once the exhausting quota window of this manager's
  own provider reopens — never a window on a provider it doesn't draw on — the window's plain
  name, e.g. `5-hour` or `weekly` — and `+N more` is the true remainder of this
  repo's own queue. A queue that has issues but nothing left to show at the current `--limit` reads
  `N queued, none listed at this limit` instead of being omitted. It wraps to at most one
  continuation line — the block is 2 to 4 lines total, and detail is dropped rather than run long.
  No other repo's name, issue number, title, starvation time or drain time appears anywhere in it.

Times are relative with a clock in parentheses — `in 2h (14:00Z)` — or a plain duration where that
reads better, `15m left`. Clocks are in the local zone, with a `Z` suffix when `TZ` is unset and a
weekday prefix when the day is not today. Durations are rounded to 5 minutes. A `~` anywhere means
the number rests on an estimated duration.

**Ten by default.** `next` lists every in-flight issue and then the next 10 queued; `--limit N`
changes that. The cap applies to the machine-wide list the guard builds, before it is filtered down
to this repo's own issues — so a busy sibling project can leave fewer of your own issues on the
page than the limit suggests. `+N more` always states the true remainder of this repo's own queue,
never an estimate. `--limit 50` is still what the manager runs when the operator asks to see the
whole queue. The simulation itself always covers every queued issue of every manager — only the
display is capped.

**Where the ETAs come from.** Each repo's task duration is the median of its own history:
`mgr launch`, `mgr adopt <pane> N` and `mgr bind N` record `launched_at` and `launched_size` in
`MGR_STATE_DIR/launches/<owner>__<repo>.json`, and `mgr retire N` on a *merged* report appends
the **execution record** to `MGR_STATE_DIR/throughput/<owner>__<repo>.jsonl` (the ledger is the
dataset) and posts the same record as an `execution:` comment on the issue (one human line, then
a fenced JSON block); only `duration_s` is read back by the guard's projections. Under 3 rows for
a repo it falls back to the machine-wide median over every repo, and with no history anywhere to
`MGR_DEFAULT_TASK_S` (2700 s, 45 min). Both fallbacks are flagged `estimated` and render as `~` —
durations are a heuristic, and the block says so instead of hiding it. A second `mgr retire N`
on the same landing (same `number` and `sha`) appends nothing to the ledger and posts no
additional `execution:` comment — the record is per landing, not per call.

From there, per manager: an in-flight issue is due at
`launched_at + max(median, elapsed + ¼ median)`, so a builder that has already outrun the median is
not predicted to land this second. The queue is FIFO by issue number over `cap` parallel slots; a
queued issue starts when a slot frees and every open blocker of its own has an ETA in the past, and
an issue nothing can schedule (a dependency cycle) gets no ETA. Projected work skips the **stall
window** — the `[exhaust_at, resets_at]` of the earliest-exhausting limit of that manager's own
provider, never a limit on a subscription it cannot spend — so a task that would straddle a dead
quota resumes at the reset instead of finishing through it. A manager with no resolvable provider
falls back to the machine-wide earliest-exhausting limit across every polled provider, the same
fallback the text `quota` line already makes for an unresolvable caller. Each manager's own window
rides along as `overview.backlog.managers[].stall_window` (`{from,to,limit}`, `null` when nothing
stalls it) — a provider currently held on a stripped verdict (see **Quota guard**) synthesizes one
too, `{from: now, to: recovers_at, limit: exhausted_limit}`, `limit: null` when the held verdict
never named one, which `next` then marks as `(after the quota reset)` — a real sampled limit for
that same provider always wins the tie against its own held window; `overview.burn.stall_window`
stays the machine-wide record — unchanged in shape or meaning, folding in the same held providers,
and still what `mgr guard status` and other tooling read — even though each manager's own ETAs no
longer use it directly.
The `quota` line and the `work`/`next` lines are scoped to two different providers on
purpose. `quota` resolves the caller's house **fresh at render time** — whatever `$MGR config
get house` or this session's own house says right now. `work` and `next` project against the
window of the provider on **the registration the guard last saw** for this manager
(`overview.backlog.managers[].stall_window`), because those ETAs were simulated against that
registration and the window has to follow the same subscription the simulation used, not
whatever the caller resolves to a moment later. For up to one guard tick after `mgr config set
house`, or when `mgr overview` runs under a different `MGR_HOUSE` than the last `mgr board`
registered, the two can disagree — the `quota` line can name a limit the `work`/`next` ETAs do
not yet account for. It is self-healing: the next heartbeat re-registers the new provider and
the ETAs catch up. A held provider splits the same two lines on purpose too, even with no house
change at all: `quota.limits` for it is `[]` (a hold carries no fresh reading, so `quota` reads
`no quota reading yet`), while `work`/`next` still mark the synthesized reset above — both
readings are correct for what each line promises.
`idle_slots` are free slots with nothing ready to fill them, and `starves_at` is when a manager's
queue empties while it still has slots: that is the "work for the next ~3h, then it idles" reading
behind `work`'s own `out of work in …`.

The data is the guard's: it refreshes every live manager's repo on its own tick (see **Quota
guard**), collecting quota and queue data machine-wide even for a manager that has been quiet — the
block above is only this manager's own slice of it, `work` and `next` scoped to its repo. It works
whenever `state.json` exists — `mgr overview` reads it with `mgr-guard overview`, no daemon
required. The ledger row keeps at most 50 ready and 50 blocked entries per repo (with the true
counts); the full queue lives in `MGR_STATE_DIR/backlog/<owner>__<repo>.json`, and that is what
the simulation runs over — a repo with 200 open issues gets 200 ETAs and shows ten. A guard that
predates this feature has no snapshot yet: restart it (`mgr guard stop`, `mgr guard start`) and
the next tick fills the backlog in. Nothing in the harness acts on any of it: the cap is still the
operator's only pace dial.

### Execution record

`schema` is `1`; an unreadable session leaves `session.read` `false` with every other
`session.*` field `null`.

| field | type | source | unit | nullable |
|---|---|---|---|---|
| `repo` | string | mgr (`own_repo`) | — | no |
| `number` | int | mgr | — | no |
| `launched_at` | int | launch stamp | ms epoch | **yes** (adoptee with no stamp) |
| `merged_at` | int | pr (`gh pr view --json mergedAt`), fallback comment `createdAt`, fallback now | ms epoch | no |
| `duration_s` | int | derived `max(0, round((merged_at-launched_at)/1000))` | s | **yes** (when `launched_at` null) |
| `schema` | int | constant `1` | — | no |
| `merged_at_source` | `"pr"` \| `"comment"` | mgr | — | no |
| `size` | string | `size:` label at retire (`gh issue view <N> --json labels`, jq locally, no `-q`) | — | yes |
| `launched_size` | string | launch stamp: the size the builder was taken with — the `size:` label for `launch` and `bind`; for `adopt`, the briefed size, `medium` when the issue carries no usable label | — | **yes** (no stamp, or `bind` on an issue with no usable label) |
| `launch_model` | string | launch stamp: the house package's `modelRoles.builder` at launch (e.g. `anthropic/claude-fable-5-1:high`) | — | **yes** (no stamp, or adopted) |
| `models` | string[] | short model ids used: `launch_model` (shortened) first, then every key of `session.models`, deduped | — | **yes** (neither known) |
| `pr` | string | report `pr=` | — | yes |
| `sha` | string | report `sha=` | — | yes |
| `report.review` | string | report `review=` (`reviewer`\|`sweep`\|`none`) | — | yes |
| `report.review_verdict` | string | report `review_verdict=` | — | yes |
| `report.checks` | string[] | report `checks=` comma list split | — | yes (absent → null) |
| `report.escalations` | int | report `escalations=` via `tonumber?` | count | yes |
| `report.delegated_planning` | string | report `delegated_planning=`, closed set `sketch`\|`plan`\|`none` | — | yes |
| `report.pre_existing_red` | int | report `pre_existing_red=` via `tonumber?` | count | yes |
| `report.final_size` | string | report `final_size=` | — | yes |
| `report.plan_rounds` | int | report `plan_rounds=` via `tonumber?` | count | yes |
| `report_warnings` | string[] | one entry per report value outside its documented set, e.g. `delegated_planning=medium not a planner role` | — | **yes** (null when the report is clean) |
| `session.read` | bool | session file readable | — | no |
| `session.turns` | int | count of `.type=="message" and .message.role=="assistant"` | count | yes |
| `session.tokens.input/output/cache_read/cache_write` | int | sums of `.message.usage.{input,output,cacheRead,cacheWrite}` (`// 0` per message) | tokens | yes |
| `session.tokens.total` | int | sum of `.message.usage.totalTokens`, per-message fallback `input+output` | tokens | yes |
| `session.cost_usd` | number | sum of `.message.usage.cost.total`, rounded to 6 decimals; **null when no message carries one** | USD | yes |
| `session.active_ms` | int | sum of `.message.duration`; null when none | ms | yes |
| `session.models` | object{string:int} | histogram of `.message.model` (assistant messages) | count | yes |
| `session.model_changes` | int | count of `.type=="model_change"` | count | yes |
| `session.resizes` | int | count of `.type=="title_change" and .trigger=="replan"` | count | yes |
| `session.stop_reasons` | object{string:int} | histogram of `.message.stopReason` | count | yes |
| `session.rate_limit_hits` | int | count of `stopReason=="error"` with `errorStatus==429` or an `errorMessage` matching the guard's `RATE_RE` (shared via `bin/mgr-lib.sh`) | count | yes |
| `session.subagents.count` | int | number of `session_init` records under `<stem>/` | count | yes |
| `session.subagents.agents` | object | histogram of `session_init.agent` | count | yes |
| `session.subagents.roles` | object | histogram of `session_init.modelRole` | count | yes |
| `session.subagents.models` | object | histogram of `session_init.resolvedModel` | count | yes |

Report values are recorded, never coerced. Where a key has a documented value set — today
`report.delegated_planning` — a value outside it is written to the ledger exactly as the builder
reported it and flagged: an entry lands in `report_warnings` and the same text is appended to the
`execution:` comment line, where a human reads it. The manager never rewrites the value, and a
flagged row is still a row: nothing about retiring changes.

`session` comes from the builder's own omp session JSONL, resolved through herdr's
`agent_session`, plus `<stem>/<Agent>.jsonl` subagent transcripts.

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
extra brief file, the cap, the rigor, the sizing bias, the model-fallback policy — lives in the
repo's `.git/config` under
`mgr.*` (`mgr config`), and the `MGR_*` variables below override it. The guard's integer knobs
silently fall back to their default when the value is not a positive integer; `MGR_CAP` is
stricter — a non-numeric cap is a usage error (exit `2`).

`rigor` is the verification dial every builder is briefed with (`mgr config set rigor`,
`MGR_RIGOR`); the contract is `builder.md §7`.

| `rigor` | full suite | focused change | red the diff did not cause | review pass |
|---|---|---|---|---|
| `production` (default) | on any shared-surface touch, and always at `large` | its tests and its integration/e2e subset | blocks landing | the surface picks the reviewer; `large` always gets a pass |
| `sprint` | only when the diff's callers cannot be enumerated | same | recorded as an issue comment naming the failing test; does not block | data-shape, API, schema and routing diffs review on the work rung (`sweep`); auth and permissions keep the top rung; no floor at `large` |

A failure the diff caused blocks in both modes. `tiny` and `small` never run the full suite in
either.

`sizing` is the classification dial intake and every builder's scope test are briefed with
(`mgr config set sizing`, `MGR_SIZING`); the rule is `SKILL.md §3(b)`.

| `sizing` | tie-break |
|---|---|
| `lean` | an unsure call resolves down |
| `balanced` (default) | an unsure call resolves up |
| `careful` | an unsure call resolves up, and the higher rung is taken whenever it is merely plausible |

`model-fallback` is the coding-plan fallback policy every builder launch overlays (`mgr config
set model-fallback`, `MGR_MODEL_FALLBACK`); the rule is `SKILL.md §6`.

| `model-fallback` | omp overlay | dialog |
|---|---|---|
| `never` (default) | `retry.modelFallback: false`, `usageAwareFallback: false` | can't appear — and no fallback on transient provider failures either (429s, outages); the guard reignites the pane instead |
| `ask` | `retry.modelFallback: true`, `usageAwareFallback: true`, `usageReservePolicy: confirm` | appears; relayed to the operator, never answered |
| `auto` | same, `usageReservePolicy: auto` | the harness switches on its own; `mgr setup`/`mgr package` also write `retry.fallbackChains` |

| Variable | Default | Effect |
|---|---|---|
| `MGR_CAP` | `3` | concurrency cap when `--cap N` is not passed; overrides `mgr.cap` |
| `MGR_OMP_ARGS` | unset | whitespace-separated extra omp argv; replaces `mgr.omp-arg` |
| `MGR_ENV` | unset | whitespace-separated `KEY=VALUE` for builder tabs; replaces `mgr.env` |
| `MGR_BRIEF_EXTRA` | unset | path to a markdown file appended to every brief; overrides `mgr.brief-extra` |
| `MGR_RIGOR` | `production` | verification rigor for builders, `sprint`\|`production`; overrides `mgr.rigor` |
| `MGR_SIZING` | `balanced` | issue-size classification bias for builders, `lean`\|`balanced`\|`careful`; overrides `mgr.sizing` |
| `MGR_MODEL_FALLBACK` | `never` | coding-plan model-fallback policy for builder launches, `never`\|`ask`\|`auto`; overrides `mgr.model-fallback` |
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
