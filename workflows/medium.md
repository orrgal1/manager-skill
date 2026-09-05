You were sized `medium`. If the scope test below fails, resize up (see builder.md §7) and switch files.
Resize only upward, never down. This file is the whole build-and-verify process at your size.

## Scope test

- [ ] Several files or packages, one feature or one bug.
- [ ] It may add a contract or a test.
- [ ] The callers are enumerable.
- [ ] Design is judgement within an existing pattern — an endpoint plus its UI, a refactor inside one
      package, a new CLI subcommand.

Any box fails → resize to `large`.

## Steps

1. **Map, then plan** — more than one area in scope → dispatch ONE parallel batch of `scout`s, one
   per area, each returning a compressed map with `file:line` refs; a single area skips them. Hand
   the issue, its acceptance list and those maps to the `sketch` agent — the light planner: it
   returns the approach, the slices, the cross-slice contracts and the verification plan. You own
   what comes back and amend what is wrong in it. You do not read source yourself before the plan
   returns: the scouts and the planner read; you read code when you integrate. Load-bearing
   ambiguity — you cannot build the right thing without an answer — stops the work and asks rather
   than guesses (a session under builder.md reports blocked, §11). Post or state the plan before you
   touch code; a session under builder.md posts it as its start marker (§6). **Escape hatch** — skip
   `sketch` only when all three hold: one area (no scouts were needed), one slice (step 2 will
   dispatch nothing), and the Notes already name the files. Then state a 3–8 line plan in-session:
   the files, the approach, the checks you will run. Anything more goes to `sketch`.
2. **Dispatch.** Two or more independent slices → fix the interfaces between them first, then
   dispatch them in ONE parallel batch, each to the agent matching that slice's size (tiny slice →
   `tiny`, small slice → `small`). A single slice stays in-session, within the ceiling
   (builder.md §7). Tell every subagent to run no suites and to leave validation to you.
3. **Integrate** the returned slices yourself, resolve the seams, and commit in scoped steps.
4. **Self-review** the whole diff (`git diff main...HEAD`) against what was asked: dead code,
   leftover scaffolding, unhandled error paths, naming, secrets, and docs or changelog if the repo
   keeps them.
5. A plan that needs a second page, or a slice that is itself medium — resize to `large`. A
   planning trigger mid-build (builder.md §7) is not a resize: stop, dispatch `sketch`, continue
   under this file.

**Escalation.** A fumble trigger (builder.md §7), or a review finding you intend to decline: hand
that step to a fresh `crux` agent — the top rung — and never retry it at your own level.

## Verification

Discover the commands from the repo's `CONTRIBUTING.md`, `docs/ops/conventions.md`, `package.json`
scripts, `justfile`, `Makefile` or the CI workflow. None of those exist → say so explicitly; never
claim a check passed.

- Typecheck every package you touched; run the tests covering every slice.
- Full suite ONLY if the diff touches a shared library, a schema, routing, or code whose callers you
  cannot enumerate.
- One review pass over the whole diff; the reviewer and the rung follow the diff surface
  (builder.md §7) — `reviewer` on the top rung, with `security-reviewer` beside it for auth or
  permissions; `sweep` on the work rung; or no pass at all. Fix every finding or decline it with a
  reason, then re-run the same set.
- The repo has a live or browser walk → run it only if the change crosses that boundary.

## Done when

- Every slice is integrated and committed.
- Review findings are fixed, or declined with a reason you can state.
- The set above is green, and you can name which checks ran and why that set covers the change.
