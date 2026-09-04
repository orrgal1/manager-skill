#!/usr/bin/env bash
# Runs every test in sequence. Each test is hermetic: it builds a temp state dir
# and fake gh/herdr/omp on its own PATH, so no network and no live tools needed.
set -u

here="$(cd "$(dirname "$0")" && pwd)"

tests="guard-smoke mgr-quota-smoke e2e-quota"
failed=0

for t in $tests; do
  if bash "$here/$t.sh" >"${TMPDIR:-/tmp}/mgr-test-$t.out" 2>&1; then
    printf 'PASS %s\n' "$t"
  else
    printf 'FAIL %s\n' "$t"
    sed 's/^/  | /' "${TMPDIR:-/tmp}/mgr-test-$t.out"
    failed=1
  fi
done

exit "$failed"
