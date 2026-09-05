You were sized `small`. If the scope test below fails, resize up (see builder.md §7) and switch files.
Resize only upward, never down. This file is the whole build-and-verify process at your size.

## Scope test

- [ ] ≤ 3 files.
- [ ] One concern.
- [ ] An existing pattern in this repo covers it.
- [ ] The callers are known.
- [ ] Judgement is local — a bug with a known cause, a flag, an extra field on an existing path.

Any box fails → resize to `medium`.

Your brief named your sizing bias — `lean`, `balanced` or `careful` (builder.md §7). It decides
which way a box you cannot call goes: under `lean` it resolves in your favour and you stay here,
under `balanced` it fails and you resize up, and under `careful` so does a box you could pass but
whose next size up is merely plausible. It never rescues a box that is plainly false — a clear-cut
failure resizes at every setting.

## Steps

1. Map first. Dispatch one `scout` for the map — where the change goes, with `file:line` refs — and
   implement from it; skip it only when the issue Notes already name the exact files and lines, or an
   `### Intake map` in the Notes does. That map is evidence, not a contract: where it disagrees with
   the code the code wins, and you say so on the issue. A disagreement that changes the shape of the
   work is a planning trigger, not a detail. Covering only part of the change, it narrows your scout
   to the rest rather than retiring it. No planner by default at this size: a planning trigger
   (builder.md §7) is the only way you get one, and it is `sketch`.
2. Implement in-session, within the ceiling (builder.md §7) — crossing it fans the remainder out,
   and nothing else does.
3. Add or update the covering test only if an observable contract changed. No tests for plumbing.
4. Self-review your own diff (`git diff main...HEAD`, or this repo's equivalent) as if someone else
   wrote it: dead code, leftover scaffolding, unhandled error paths, naming, and anything secret
   that must not be committed.
5. Commit in scoped steps as you go.
6. A fourth file, a schema, or a shared library — resize to `medium`. A planning trigger
   (builder.md §7) is not a resize: dispatch `sketch`, then continue under this file.
   A fumble trigger (builder.md §7) is not a resize either: escalate that step to a fresh `crux`
   agent, then continue under this file.

## Verification

Discover the commands from the repo's `CONTRIBUTING.md`, `docs/ops/conventions.md`, `package.json`
scripts, `justfile`, `Makefile` or the CI workflow. None of those exist → say so explicitly; never
claim a check passed.

- Typecheck the packages you touched.
- Run the test files that cover the changed code, and the touched surface's
  integration or e2e subset (builder.md §7).
- Review: the reviewer and the rung follow the diff surface and your rigor (builder.md §7) —
  `reviewer` on the top rung, with `security-reviewer` beside it for auth or permissions; `sweep`
  on the work rung; or no pass at all. Your size does not decide it: a three-file diff that
  touches auth gets the top rung.
- Never at this size: the full suite.

Fix everything you or the reviewer found, re-run the same set, commit.

## Done when

- The change matches what was asked, and nothing beyond it is in the diff.
- Self-review done and its findings fixed.
- Typecheck and the covering tests are green, and you can name which ones ran and why that set
  covers the change.
- Everything is committed.
