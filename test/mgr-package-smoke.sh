#!/usr/bin/env bash
# mgr-package-smoke.sh — smoke test for bin/mgr-package: listing the packages
# this checkout ships, applying one into the omp config, installing the size
# agent files, and reaching both through the `mgr package` / `mgr setup`
# dispatcher.
#
# Hermetic, like the other tests: a fake `omp` on a temp PATH that refuses to
# work on any agent dir but the temp one, `PI_CODING_AGENT_DIR` pointing at that
# dir, fake `gh`/`herdr` so `bin/mgr` finds its deps. The real ~/.omp/agent is
# never read and never written — the fake exits 9 if it is ever aimed there.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd -P)
MGR="$root/bin/mgr"
PKG="$root/bin/mgr-package"
for x in "$MGR" "$PKG"; do
  [ -x "$x" ] || { printf 'not executable: %s\n' "$x" >&2; exit 1; }
done

tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; agent="$tmp/agent"; repo="$tmp/repo"
mkdir -p "$bin" "$agent" "$repo" "$tmp/nohooks"

# a minimal omp config: one unmanaged setting the apply must leave alone, plus a
# modelRoles block for the role diff to compare against
cat >"$agent/config.yml" <<'EOF'
emojiAutocomplete: false
modelRoles:
  default: anthropic/claude-opus-5:high
EOF

# ------------------------------------------------------------------ fakes

# Only what bin/mgr-package uses: `config path`, `config get modelRoles --json`,
# `config set <key> <json>`. The set renders the three managed keys back into
# config.yml the way omp does — comments dropped, unmanaged keys kept, no
# trailing newline — and logs the JSON it was handed.
cat >"$bin/omp" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[ "${PI_CODING_AGENT_DIR:-}" = "$OMP_FAKE_DIR" ] \
  || { printf 'fake omp: refusing to touch %s\n' "${PI_CODING_AGENT_DIR:-<unset>}" >&2; exit 9; }
dir="$PI_CODING_AGENT_DIR"
cfg="$dir/config.yml"
state="$dir/.state"; mkdir -p "$state"

kf() { printf '%s/%s.json' "$state" "$(printf '%s' "$1" | tr '.' '-')"; }
# a key already written by this fake, else read back out of config.yml
get() {
  [ -f "$(kf "$1")" ] && { cat "$(kf "$1")"; return; }
  [ "$1" = modelRoles ] || { printf '{}'; return; }
  awk '
    /^[A-Za-z]/ { inb = ($0 == "modelRoles:"); next }
    inb && /^  [^ ]/ { sub(/^  /, ""); i = index($0, ": ")
                       v = substr($0, i + 2); gsub(/"/, "", v)
                       print substr($0, 1, i - 1) "\t" v }' "$cfg" \
  | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
             | {key:.[0], value:.[1]}) | from_entries'
}
# omp quotes a role value that starts with @; everything else is plain
scalars() { # scalars <indent> <json>
  jq -r --arg i "$1" 'to_entries[] | $i + .key + ": "
    + (if (.value | startswith("@")) then "\"" + .value + "\"" else .value end)' <<<"$2"
}
lists() { # lists <indent> <json>
  jq -r --arg i "$1" 'to_entries[] | ($i + .key + ":"), (.value[] | $i + "  - " + .)' <<<"$2"
}

case "${1:-} ${2:-}" in
  "config path") printf '%s\n' "$dir";;
  "config get")
    [ "${3:-}" = modelRoles ] || { printf 'fake omp: get %s\n' "${3:-}" >&2; exit 2; }
    jq -nc --argjson v "$(get modelRoles)" '{key:"modelRoles",value:$v}';;
  "config set")
    key="${3:?}"; val="${4:?}"
    # the atomicity test makes one named key fail after earlier ones succeeded
    [ "${FAKE_OMP_FAIL_ON:-}" = "$key" ] \
      && { printf 'fake omp: forced failure on %s\n' "$key" >&2; exit 7; }
    printf '%s\n' "$val" | jq -e . >/dev/null || { printf 'fake omp: bad JSON\n' >&2; exit 2; }
    printf 'omp config set %s %s\n' "$key" "$val" >>"${OMP_FAKE_LOG:-/dev/null}"
    printf '%s' "$val" >"$(kf "$key")"
    # the unmanaged part of config.yml, captured once and kept verbatim
    [ -f "$state/preamble.yml" ] || awk '
      /^[A-Za-z]/ { skip = ($0 ~ /^(modelRoles|task|retry|activePackage):/) }
      !skip { print }' "$cfg" >"$state/preamble.yml"
    {
      cat "$state/preamble.yml"
      printf 'modelRoles:\n'; scalars '  ' "$(get modelRoles)"
      printf 'task:\n  agentModelOverrides:\n'; scalars '    ' "$(get task-agentModelOverrides)"
      printf 'retry:\n  fallbackChains:\n'; lists '    ' "$(get retry-fallbackChains)"
    } >"$state/render.yml"
    printf '%s' "$(cat "$state/render.yml")" >"$cfg"   # omp drops the trailing newline
    printf '\xe2\x9c\x94 Set %s\n' "$key";;
  *) printf 'fake omp: unsupported: %s\n' "$*" >&2; exit 2;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/herdr"
chmod +x "$bin/omp" "$bin/gh" "$bin/herdr"

export PATH="$bin:$PATH"
export PI_CODING_AGENT_DIR="$agent"
export OMP_FAKE_DIR="$agent"
export OMP_FAKE_LOG="$tmp/omp-calls.log"
: >"$OMP_FAKE_LOG"

# a real repo so `mgr config get house` (the setup fallback) has a store
git init -q "$repo"
git -C "$repo" -c core.hooksPath="$tmp/nohooks" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m init || { printf 'fixture repo failed\n' >&2; exit 1; }
git -C "$repo" branch -M main
cd "$repo" || exit 1

fails=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}
roles_set() { # the JSON the last `omp config set modelRoles` was handed
  grep '^omp config set modelRoles ' "$OMP_FAKE_LOG" | tail -1 \
    | sed 's/^omp config set modelRoles //'
}
# a value out of config.yml's modelRoles block, so the file itself is asserted
cfg_role() { # cfg_role <role>
  awk -v r="  $1: " '
    /^[A-Za-z]/ { in_roles = ($0 == "modelRoles:") }
    in_roles && index($0, r) == 1 { print substr($0, length(r) + 1) }' "$agent/config.yml"
}

# --------------------------------------------------- 1. listing

printf '\n# 1. mgr-package package: what is applied and what is available\n'
out=$("$PKG" package); rc=$?
check 'list exit' 0 "$rc"
check 'nothing applied yet' null "$(jq -r '.active' <<<"$out")"
check 'the three houses' '["anthropic","gemini","openai"]' "$(jq -c '.available' <<<"$out")"
check 'the packages dir' "$root/omp/packages" "$(jq -r '.dir' <<<"$out")"

# --------------------------------------------------- 2. applying one

printf '\n# 2. mgr-package package <house>: the roles land in config.yml\n'
out=$("$PKG" package openai); rc=$?
check 'apply exit' 0 "$rc"
check 'apply reports the package' openai "$(jq -r '.package' <<<"$out")"
check 'apply reports the previous one' null "$(jq -r '.previous' <<<"$out")"
check 'apply names the config it wrote' "$agent/config.yml" "$(jq -r '.config' <<<"$out")"
check 'apply took a backup' true \
  "$(jq -r '.backup | startswith("'"$agent"'/config.yml.bak-")' <<<"$out")"
check 'review is the top rung' openai-codex/gpt-6-astra:high \
  "$(jq -r '.changes[] | select(.role == "review") | .to' <<<"$out")"
check 'the diff carries the old default' anthropic/claude-opus-5:high \
  "$(jq -r '.changes[] | select(.role == "default") | .from' <<<"$out")"
check 'apply counts the agent overrides' 6 "$(jq -r '.agent_overrides' <<<"$out")"
check 'default model-fallback policy is never' never "$(jq -r '.model_fallback' <<<"$out")"
check 'apply does not write fallback chains by default' 0 "$(jq -r '.fallback_chains' <<<"$out")"
check 'apply says a live session needs a restart' true \
  "$(jq -r '.note | test("restart")' <<<"$out")"

check 'omp was handed review' openai-codex/gpt-6-astra:high \
  "$(jq -r '.review' <<<"$(roles_set)")"
check 'omp was handed the whole role set' 21 "$(jq -r 'length' <<<"$(roles_set)")"
check 'config.yml modelRoles.review' openai-codex/gpt-6-astra:high "$(cfg_role review)"
check 'config.yml modelRoles.builder is the top rung' openai-codex/gpt-6-astra:high "$(cfg_role builder)"
check 'config.yml modelRoles.sketch is the top rung, with plan' openai-codex/gpt-6-astra:high "$(cfg_role sketch)"
check 'config.yml modelRoles.sweep is the work rung, below review' openai-codex/gpt-5.6-sol:high \
  "$(cfg_role sweep)"
check 'config.yml modelRoles.tiny is the bottom rung' openai-codex/gpt-5.6-luna:low \
  "$(cfg_role tiny)"
check 'config.yml is stamped' 1 \
  "$(grep -cx 'activePackage: openai' "$agent/config.yml" || true)"
check 'the unmanaged setting survived' 1 \
  "$(grep -cx 'emojiAutocomplete: false' "$agent/config.yml" || true)"
check 'the overrides landed' 1 \
  "$(grep -c '^omp config set task.agentModelOverrides ' "$OMP_FAKE_LOG" || true)"
check 'the chains do not land by default' 0 \
  "$(grep -c '^omp config set retry.fallbackChains ' "$OMP_FAKE_LOG" || true)"
check 'MGR_MODEL_FALLBACK=ask still does not write chains' 0 \
  "$(out=$(MGR_MODEL_FALLBACK=ask "$PKG" package openai); jq -r '.fallback_chains' <<<"$out")"
check 'ask still does not land in the log' 0 \
  "$(grep -c '^omp config set retry.fallbackChains ' "$OMP_FAKE_LOG" || true)"
out=$(MGR_MODEL_FALLBACK=auto "$PKG" package openai)
check 'MGR_MODEL_FALLBACK=auto reports the policy' auto "$(jq -r '.model_fallback' <<<"$out")"
check 'MGR_MODEL_FALLBACK=auto writes the chains once' 1 "$(jq -r '.fallback_chains' <<<"$out")"
check 'the chains landed exactly once, only under auto' 1 \
  "$(grep -c '^omp config set retry.fallbackChains ' "$OMP_FAKE_LOG" || true)"
err=$(MGR_MODEL_FALLBACK=bogus "$PKG" package openai 2>&1 >/dev/null); rc=$?
check 'a bogus MGR_MODEL_FALLBACK is refused' true \
  "$(if [ "$rc" -ne 0 ]; then printf true; else printf false; fi)"
check 'the bogus value is named in the error' true \
  "$(jq -r '.error.message | test("bogus")' <<<"$err")"
check 'a bogus MGR_MODEL_FALLBACK changed nothing in the log' 1 \
  "$(grep -c '^omp config set retry.fallbackChains ' "$OMP_FAKE_LOG" || true)"
check 'the list now reports it as active' openai "$("$PKG" package | jq -r '.active')"

out=$("$PKG" package anthropic)
check 'a second apply reports the previous package' openai "$(jq -r '.previous' <<<"$out")"
check 'config.yml is restamped' 1 \
  "$(grep -cx 'activePackage: anthropic' "$agent/config.yml" || true)"
check 'plan is the top rung' anthropic/claude-fable-5-1:high "$(cfg_role plan)"
check 'builder is the top rung' anthropic/claude-fable-5-1:high "$(cfg_role builder)"
check 'sketch is the top rung, with plan' anthropic/claude-fable-5-1:high "$(cfg_role sketch)"
check 'sweep is the work rung, below review' anthropic/claude-opus-5:high "$(cfg_role sweep)"

# --------------------------------------------------- 3. refusals

printf '\n# 3. refusals\n'
err=$("$PKG" package nope 2>&1 >/dev/null); rc=$?
check 'unknown package exit' 4 "$rc"
check 'unknown package code' 4 "$(jq -r '.error.code' <<<"$err")"
check 'unknown package message lists the houses' \
  "unknown package 'nope'; available: anthropic, gemini, openai" \
  "$(jq -r '.error.message' <<<"$err")"
check 'unknown package changed nothing' 1 \
  "$(grep -cx 'activePackage: anthropic' "$agent/config.yml" || true)"

err=$("$PKG" 2>&1 >/dev/null); rc=$?
check 'no verb exit' 2 "$rc"
check 'no verb message' 'usage: mgr-package <package|setup> [args...]' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$PKG" bogus 2>&1 >/dev/null); rc=$?
check 'unknown verb exit' 2 "$rc"
err=$("$PKG" package a b 2>&1 >/dev/null); rc=$?
check 'two package args exit' 2 "$rc"
check 'two package args message' 'usage: mgr package [<house>]' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$PKG" setup --nope 2>&1 >/dev/null); rc=$?
check 'unknown setup flag exit' 2 "$rc"

# --------------------------------------------------- 4. setup

printf '\n# 4. mgr-package setup: the size agents, then the house package\n'
out=$("$PKG" setup --house gemini); rc=$?
check 'setup exit' 0 "$rc"
check 'setup installs the eight agents' \
  '["crux.md","large.md","medium.md","plan.md","sketch.md","small.md","sweep.md","tiny.md"]' \
  "$(jq -c '.agents.installed' <<<"$out")"
check 'setup skipped nothing' '[]' "$(jq -c '.agents.skipped' <<<"$out")"
check 'setup names the agents dir' "$agent/agents" "$(jq -r '.agents.dir' <<<"$out")"
check 'setup applied the named house' gemini "$(jq -r '.house' <<<"$out")"
check 'setup reports the package too' gemini "$(jq -r '.package.package' <<<"$out")"
check 'gemini: sketch is the top rung, with plan' google-antigravity/gemini-3.1-pro:high "$(cfg_role sketch)"
check 'gemini: sweep collapses onto Pro with review' google-antigravity/gemini-3.1-pro:high "$(cfg_role sweep)"
check 'the tiny agent runs on the small model' 'model: "@small"' \
  "$(grep '^model:' "$agent/agents/tiny.md")"
check 'the sweep agent runs on the sweep rung' 'model: "@sweep"' \
  "$(grep '^model:' "$agent/agents/sweep.md")"
check 'the agents are on disk' 8 "$(ls "$agent/agents" | wc -l | tr -d ' ')"

out=$("$PKG" setup --house gemini)
check 'a second setup installs nothing' '[]' "$(jq -c '.agents.installed' <<<"$out")"
check 'a second setup skips all eight' \
  '["crux.md","large.md","medium.md","plan.md","sketch.md","small.md","sweep.md","tiny.md"]' \
  "$(jq -c '.agents.skipped' <<<"$out")"

printf 'local edit\n' >"$agent/agents/tiny.md"
"$PKG" setup --house gemini >/dev/null
check 'without --force an existing file is left alone' 'local edit' \
  "$(cat "$agent/agents/tiny.md")"
out=$("$PKG" setup --force --house gemini)
check '--force reinstalls all eight' \
  '["crux.md","large.md","medium.md","plan.md","sketch.md","small.md","sweep.md","tiny.md"]' \
  "$(jq -c '.agents.installed' <<<"$out")"
check '--force overwrote the edit' 0 \
  "$(cmp -s "$root/omp/agents/tiny.md" "$agent/agents/tiny.md"; printf '%s' "$?")"

printf '\n# 4b. the house setup picks: --house, else mgr config house, else anthropic\n'
"$MGR" config set house openai >/dev/null
check 'mgr config house is the fallback' openai "$("$PKG" setup | jq -r '.house')"
check '--house wins over the store' gemini "$("$PKG" setup --house gemini | jq -r '.house')"
"$MGR" config unset house >/dev/null
check 'nothing configured falls back to anthropic' anthropic \
  "$("$PKG" setup | jq -r '.house')"
check 'outside a git checkout it still defaults' anthropic \
  "$(cd "$tmp" && "$PKG" setup | jq -r '.house')"
err=$("$PKG" setup --house nope 2>&1 >/dev/null); rc=$?
check 'an unknown --house exit' 4 "$rc"

check 'an empty source dir is a not-found' 4 \
  "$(OMP_AGENTS_DIR="$tmp/none" "$PKG" setup >/dev/null 2>&1; printf '%s' "$?")"

# --------------------------------------------------- 5. through the dispatcher

printf '\n# 5. mgr package / mgr setup reach the same script\n'
out=$("$MGR" package); rc=$?
check 'mgr package exit' 0 "$rc"
check 'mgr package sees the applied one' anthropic "$(jq -r '.active' <<<"$out")"
check 'mgr package resolves omp/packages from MGR_ROOT' "$root/omp/packages" \
  "$(jq -r '.dir' <<<"$out")"
out=$("$MGR" setup --force --house openai); rc=$?
check 'mgr setup exit' 0 "$rc"
check 'mgr setup applied openai' openai "$(jq -r '.house' <<<"$out")"
check 'mgr setup installed the agents' 8 "$(jq -r '.agents.installed | length' <<<"$out")"
check 'config.yml followed' openai-codex/gpt-6-astra:high "$(cfg_role review)"

# ------------------------------------- 5b. a mid-apply failure is not half-applied

printf '\n# 5b. a failed `omp config set` restores config.yml and says so\n'
cp "$agent/config.yml" "$tmp/config.before"
# the fake prints its own forced-failure line, so the JSON error is picked out
FAKE_OMP_FAIL_ON=task.agentModelOverrides "$PKG" package gemini \
  >/dev/null 2>"$tmp/fail.err"; rc=$?
err=$(grep '^{' "$tmp/fail.err" | tail -1)
check 'a mid-apply failure exits non-zero' true \
  "$(if [ "$rc" -ne 0 ]; then printf true; else printf false; fi)"
check 'the error names the step that failed' true \
  "$(jq -r '.error.message | test("omp config set task.agentModelOverrides failed")' <<<"$err")"
check 'the error names the backup it restored' true \
  "$(jq -r '.error.message | test("restored .*/config\\.yml\\.bak-")' <<<"$err")"
check 'config.yml is byte-identical to before the failed apply' 0 \
  "$(cmp -s "$tmp/config.before" "$agent/config.yml"; printf '%s' "$?")"
check 'the half-applied package never stamped itself' 0 \
  "$(grep -c '^activePackage: gemini' "$agent/config.yml" || true)"
check 'the previously applied package still stands' openai \
  "$("$PKG" package | jq -r '.active')"

# --------------------------------------------------- 6. the real agent dir

printf '\n# 6. nothing outside the temp agent dir was touched\n'
check 'every omp call was aimed at the temp dir' 0 \
  "$(grep -c 'refusing to touch' "$OMP_FAKE_LOG" || true)"
check 'the temp dir holds the config' true \
  "$(if [ -f "$agent/config.yml" ]; then printf true; else printf false; fi)"

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'all checks passed\n'; exit 0; fi
printf '%d check(s) failed\n' "$fails"; exit 1
