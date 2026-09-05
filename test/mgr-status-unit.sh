#!/usr/bin/env bash
# mgr-status-unit.sh — bash wrapper so test/run.sh can drive the one TypeScript
# test in this suite. extensions/mgr-status.ts runs inside omp, which is a bun
# process, so bun is the runtime that has to load it here too.
set -u

here="$(cd "$(dirname "$0")" && pwd)"

if ! command -v bun >/dev/null 2>&1; then
  printf 'mgr-status-unit: bun is required (omp itself runs on bun)\n' >&2
  exit 1
fi

exec bun test "$here/mgr-status.test.ts"
