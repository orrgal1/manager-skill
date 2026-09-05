You were sized `large`. If the scope test below fails, resize up (see builder.md §7) and switch files.
This is the largest size — there is nothing above it. This file is the whole process at your size.

## Scope test

- [ ] Cross-cutting, or a new subsystem.
- [ ] It touches a schema, a shared library or routing.
- [ ] The callers are not enumerable.
- [ ] It needs a plan before any file is opened.
- [ ] The judgement is architectural — a feature spanning packages, a migration, a new pipeline.

Any of these true → this is your file. Do not resize down: work already sized large stays large.

## Steps

1. **Map, then plan** — more than one area in scope → dispatch ONE parallel batch of `scout`s, one
   per area, each returning a compressed map with `file:line` refs; a single area skips them. Hand
   the issue, its acceptance list and those maps to the `plan` agent — the deep planner: it returns
   the approach, the risks, the cross-slice contracts (interfaces, schemas, file ownership) and the
   verification plan. You own what comes back and amend what is wrong in it. You do not read source
   yourself before the plan returns: the scouts and the planner read; you read code when you
   integrate. Load-bearing ambiguity — you cannot build the right thing without an answer — stops
   the work and asks rather than guesses (a session under builder.md reports blocked, §11). Post or
   state the plan before you touch code; a session under builder.md posts it as its start marker
   (§6).
2. **Break up** — the same `plan` call returns the slice table: slice, size, depends-on, agent. A
   slice that is itself large is split further; never dispatch one whole. Amend the table where it
   is wrong, then post or state it.
3. **Execute** — independent slices in ONE parallel batch to the size-matched agent (`tiny`,
   `small`, `medium`); dependent waves in dependency order, one wave at a time. Subagents run no
   suites. You integrate after each wave and commit; anything you would type yourself rather than
   dispatch falls under the ceiling (builder.md §7).
4. **Integrate** — typecheck everything touched; run the covering tests for every slice and the
   touched surface's integration or e2e subset (builder.md §7).
5. **Review** — one review pass over the whole diff against acceptance, design and risk; the
   reviewer and the rung follow the diff surface and your rigor (builder.md §7) — `reviewer` on the
   with `security-reviewer` beside it for auth or permissions, else `sweep`. Under `production` a
   pass always runs at this size, even for a docs-only diff; under `sprint` the surface alone
   decides (builder.md §7). Summarise the findings where the work is tracked.
6. **Fix round** — at least one whenever a pass ran. Every finding is fixed or explicitly declined
   with a reason, and the list travels with the change. Fix slices are sized and dispatched like
   step 3.
7. **Full suite** — under `production`, always at this size; under `sprint`, only when the diff
   surface calls for it (builder.md §7) — plus the repo's live or browser walk if it has one and
   the change crosses that boundary.
8. **Fix failures.** Re-review only if the fixes touched logic outside the diff already reviewed.
9. **Done** — review clean when a pass ran, the set green.

**Escalation.** A fumble trigger (builder.md §7), or a review finding you intend to decline: hand
that step to a fresh `crux` agent — the top rung — and never retry it at your own level. A planning
trigger mid-build (builder.md §7) sends the work back to `plan` for a revision; you stay under this
file.

## Verification

Discover the commands from the repo's `CONTRIBUTING.md`, `docs/ops/conventions.md`, `package.json`
scripts, `justfile`, `Makefile` or the CI workflow. None of those exist → say so explicitly; never
claim a check passed.

- Always: typecheck every touched package, and for every slice its covering tests plus the touched
  surface's integration or e2e subset (builder.md §7).
- The full suite under `production`; under `sprint` only when the diff surface calls for it
  (builder.md §7).
- One review pass plus one fix round — under `production` always; under `sprint` when the diff
  surface calls for one — and either way the surface and your rigor pick the reviewer and the rung
  §7).
- The live or browser walk when the change crosses that boundary.
- Never a subagent running the suite; never a slice dispatched before its interface is fixed.

## Done when

- Every slice landed and committed, the plan's acceptance met box for box.
- Review clean when a pass ran: every finding fixed or declined with a reason.
- The set green, and the walk green if it was in scope.
- You can name the checks that ran and why that set covers the change.
