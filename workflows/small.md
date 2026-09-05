You were sized `small`. If the scope test below fails, resize up (see builder.md §7) and switch files.
Resize only upward, never down. This file is the whole build-and-verify process at your size.

## Scope test

- [ ] ≤ 3 files.
- [ ] One concern.
- [ ] An existing pattern in this repo covers it.
- [ ] The callers are known.
- [ ] Judgement is local — a bug with a known cause, a flag, an extra field on an existing path.

Any box fails → resize to `medium`.

## Steps

1. Read the neighbouring code before you write anything. One `scout` only if you do not know where
   the change goes; otherwise no subagents.
2. Implement in-session. No fan-out.
3. Add or update the covering test only if an observable contract changed. No tests for plumbing.
4. Self-review your own diff (`git diff main...HEAD`, or this repo's equivalent) as if someone else
   wrote it: dead code, leftover scaffolding, unhandled error paths, naming, and anything secret
   that must not be committed.
5. Commit in scoped steps as you go.
6. A fourth file, a schema, or a shared library — resize to `medium`.

## Verification

Discover the commands from the repo's `CONTRIBUTING.md`, `docs/ops/conventions.md`, `package.json`
scripts, `justfile`, `Makefile` or the CI workflow. None of those exist → say so explicitly; never
claim a check passed.

- Typecheck the packages you touched.
- Run the test files that cover the changed code.
- `reviewer`: only when the diff touches auth, permissions, a data shape or a public API. A copy,
  constant, styling or doc change does not get one.
- Never at this size: the full suite.

Fix everything you or the reviewer found, re-run the same set, commit.

## Done when

- The change matches what was asked, and nothing beyond it is in the diff.
- Self-review done and its findings fixed.
- Typecheck and the covering tests are green, and you can name which ones ran and why that set
  covers the change.
- Everything is committed.
