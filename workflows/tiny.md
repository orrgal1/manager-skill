You were sized `tiny`. If the scope test below fails, resize up (see builder.md §7) and switch files.
Resize only upward, never down. This file is the whole build-and-verify process at your size.

## Scope test

- [ ] 1 file (2 with its test), ≤ ~30 lines.
- [ ] No behaviour change beyond the literal you are editing.
- [ ] No judgement needed — copy, a constant, a CSS value, a doc line, a config value, a rename.

Any box fails → resize to `small`.

Your brief named your sizing bias — `lean`, `balanced` or `careful` (builder.md §7). It decides
which way a box you cannot call goes: under `lean` a borderline box passes and you stay here,
under `careful` it fails and you resize up, and under `balanced` a genuine toss-up resizes up.
It never rescues a box that is plainly false — a clear-cut failure resizes at every setting.

## Steps

1. Read the target file and its direct neighbour. Nothing else.
2. Edit in-session. No subagents, no scout, no plan.
3. One commit.
4. A third failed tool call, or a second file — resize to `small` instead of pushing on.

## Verification

Discover the commands from the repo's `CONTRIBUTING.md`, `docs/ops/conventions.md`, `package.json`
scripts, `justfile`, `Makefile` or CI. None exist → say so; never claim a check passed.

- Docs or copy → run nothing.
- Code → typecheck the touched package only, plus the one test file covering the changed line and,
  when the changed surface has one, its integration or e2e subset (builder.md §7).
- Never at this size: a `reviewer` pass, the full suite, a test file outside those.

## Done when

The change is in and committed and the check above is green — or it was docs/copy, and you said so.
