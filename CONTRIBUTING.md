# Contributing

## Setup

```sh
git clone https://github.com/orrgal1/manager-skill
cd manager-skill
./install.sh                 # symlinks ~/.claude/skills/manager -> this checkout
```

The skill itself needs `bash` (3.2+), `git`, `gh` (authenticated), `jq`, [herdr](https://herdr.dev)
and `omp` at runtime. Working on the scripts needs far less: `bash`, `jq` and `shellcheck`.

## Tests

```sh
test/run.sh
```

That is the whole suite and the only thing you need to run. It is hermetic — each test stands up the
fake `gh`/`herdr`/`omp` it needs on a temporary `PATH` and points `MGR_STATE_DIR` at a temporary
directory — so it needs no network, no GitHub token and no herdr. Individual scripts
(`test/guard-smoke.sh`, `test/mgr-quota-smoke.sh`, `test/e2e-quota.sh`) run standalone and exit
non-zero on failure. A new test is a script in `test/` plus its name in the `tests=` list in
`test/run.sh`.

CI (`.github/workflows/ci.yml`) runs on every push to `main` and every pull request: one job
lints with `shellcheck` (0.11.0), another runs `test/run.sh` on both `ubuntu-latest` and
`macos-latest`. Before opening the PR, run the suite and the same lint command CI uses:

```sh
test/run.sh
shellcheck -S warning bin/mgr bin/mgr-guard install.sh test/*.sh
```

## Pull requests

- One issue per PR. Open the issue first if there isn't one, and say which it closes.
- Behaviour changes come with a test, written the way the existing ones are: fakes on a temp
  `PATH`, no network, non-zero exit on failure.
- Keep the scripts `bash` 3.2 compatible — no associative arrays, no `mapfile`/`readarray`, no
  `${var,,}`, no `wait -n`. Keep tool use portable across GNU and BSD (`date`, `sed`, `stat`).
- `bin/mgr` and `bin/mgr-guard` are contracts, not just scripts: stdout stays JSON, errors stay
  `{"error":{"code":N,"message":"…"}}` on stderr, and the exit codes keep their meaning
  (`1` unexpected · `2` usage · `3` refused · `4` not found). Changing a board field or an exit
  code means updating `SKILL.md` in the same PR.
- Bump `version` in `package.json` (semver) when a change should reach consumers who install with
  `pnpm add github:orrgal1/manager-skill` — there is no other release step.
- No new runtime dependencies without a reason in the issue.

## Where the design lives

- `SKILL.md` is the manager's contract: what the session may do, how it reads `mgr board`, how it
  handles each operator request. Its frontmatter `description` is what makes the skill trigger, so
  edit it deliberately.
- `builder.md` is the builder's contract: worktree discipline, self-review, landing, and the
  `manager-report:` comment format the manager parses.
- `README.md` is the outside view. If you change a flag, an env var or a default, it changes there
  too.
