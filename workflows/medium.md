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

1. **Map, then plan.** More than one area in scope → dispatch ONE parallel batch of `scout`s, one
   per area, each returning a compressed map with `file:line` refs; a single area skips them. Then
   a plan, 3–8 lines: the files, the approach, the checks you will run. A session under builder.md
   posts it as its start marker (§6); an interactive session states it in-turn before editing.
2. **Dispatch.** Two or more independent slices → fix the interfaces between them first, then
   dispatch them in ONE parallel batch, each to the agent matching that slice's size (tiny slice →
   `tiny`, small slice → `small`). A single slice stays in-session. Tell every subagent to run no
   suites and to leave validation to you.
3. **Integrate** the returned slices yourself, resolve the seams, and commit in scoped steps.
4. **Self-review** the whole diff (`git diff main...HEAD`) against what was asked: dead code,
   leftover scaffolding, unhandled error paths, naming, secrets, and docs or changelog if the repo
   keeps them.
5. A plan that needs a second page, or a slice that is itself medium — resize to `large`.

**Escalation.** The same check failing twice for a reason you cannot name, or a review finding you
intend to decline: hand that step to a `large` agent — a `plan` agent for a plan revision — instead
of retrying it at your own level.

## Verification

Discover the commands from the repo's `CONTRIBUTING.md`, `docs/ops/conventions.md`, `package.json`
scripts, `justfile`, `Makefile` or the CI workflow. None of those exist → say so explicitly; never
claim a check passed.

- Typecheck every package you touched; run the tests covering every slice.
- Full suite ONLY if the diff touches a shared library, a schema, routing, or code whose callers you
  cannot enumerate.
- One `reviewer` pass over the whole diff when it has logic or contract surface (a new code path, an
  auth or permission boundary, a public API, a data shape). Fix every finding or decline it with a
  reason, then re-run the same set.
- The repo has a live or browser walk → run it only if the change crosses that boundary.

## Done when

- Every slice is integrated and committed.
- Reviewer findings are fixed, or declined with a reason you can state.
- The set above is green, and you can name which checks ran and why that set covers the change.
