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
```

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
| quota status | `mgr board` and one burn line, e.g. `burn: anthropic:5h 20% → 2.56× by 17:00Z (was 1.04×)` |
| cancel #12 / set the cap to 2 / adopt the other tabs / dedupe the issues | see `SKILL.md` |

## Headless use

External tooling can drive `mgr` outside a pane: export `HERDR_WORKSPACE_ID` and run from a cwd
inside the repo. Every command except `bind` works that way — `HERDR_PANE_ID` only matters for
`bind`, for `board.self` and for the guard heartbeat.

```sh
HERDR_WORKSPACE_ID=<ws> mgr board

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
| `bin/mgr` | `labels` · `board` · `launch` · `adopt` · `bind` · `wait` · `prompt` · `retire` · `guard` · `pause` · `unpause` (`resume`) · `config` · `paths` · `--version` |
| `bin/mgr-guard` | `start` · `stop` · `status` · `tick` · `run` · `register` · `touch` · `stall` — the quota daemon |
| `install.sh` | Symlinks the checkout into `~/.claude/skills/manager` |
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
  limit — `anthropic:5h at 20% burning 0.2/h → 2.56× the window by 17:00Z`, or `fits`.
- **Surfacing it.** `mgr board` passes the projection through as `quota.limits[]` and
  `quota.reason`, and compares it with the projection it last returned for this manager
  (`MGR_STATE_DIR/managers/<manager_id>.last_report.json`). When some limit's `fits` flipped, its
  `projected_at_reset` moved by `0.1` or more, or it is new, the board returns `quota.changed: true`
  with `quota.delta` describing it — `anthropic:5h 1.04× → 2.56× (now over)`. The manager then ends
  that turn with one line, `burn: anthropic:5h 20% → 2.56× by 17:00Z (was 1.04×)`, and otherwise
  says nothing about quota.
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
  cap and in-flight, for attribution only; every other subcommand stamps `seen_at`) — and the
  `managers/<id>.last_report.json` the board writes for change detection. One daemon serves every
  manager on the machine.

`mgr guard start` is idempotent, `mgr guard status` prints the whole state (and always exits 0), and
the daemon exits by itself only after 30 minutes with no live manager pane and no stalled pane. A
manager is live while its herdr pane exists (`herdr agent list`); heartbeat age is informational, so
`guard status` reports both `managers[].pane_alive` and `managers[].seen_at` — that is what keeps a
429-stalled manager, which runs no commands at all, from being written off. When the daemon does
exit it records why, and `mgr guard status` and `mgr board` report it as
`last_exit_at` / `last_exit_reason`.

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
| `MGR_GUARD_NOTIFY` | `1` | `0` silences the guard's herdr toasts (a reignite is the only one) |
| `MGR_GUARD_NOW_MS` | unset | pins the guard's clock in ms since the epoch; for tests |

`HERDR_WORKSPACE_ID`, `HERDR_PANE_ID` and `HERDR_TAB_ID` are exported by herdr, not by you —
except in headless use, where the caller sets `HERDR_WORKSPACE_ID` itself.

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
