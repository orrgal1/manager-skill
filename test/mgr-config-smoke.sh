#!/usr/bin/env bash
# mgr-config-smoke.sh — smoke test for the per-repo `mgr config` store
# (omp-arg / env / brief-extra / cap), its wiring into launch / adopt / board,
# and headless operation with only HERDR_WORKSPACE_ID set.
#
# Self-contained and hermetic, like mgr-quota-smoke.sh: fake `gh` and `herdr` on
# a temp PATH, a fake `mgr-guard` reached through MGR_GUARD_BIN, MGR_STATE_DIR in
# the temp dir. The throwaway repo is a REAL git repo with a `main` branch and
# one commit, because `mgr launch` runs `git worktree add -b … main` against it.
# No network, no live herdr session, no omp.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
MGR="$here/../bin/mgr"
# every launched builder loads the status-line extension from the real checkout
# (`readlink -f` in bin/mgr resolves it even through an install.sh symlink)
ext="$(cd "$here/.." && pwd -P)/extensions/mgr-status.ts"
[ -x "$MGR" ] || { printf 'not executable: %s\n' "$MGR" >&2; exit 1; }

# physical paths throughout: `git worktree list` reports the resolved path, and
# the launch worktree name is derived from it
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; fix="$tmp/fix"; repo="$tmp/repo"
mkdir -p "$bin" "$fix" "$repo" "$tmp/state" "$tmp/nohooks"
git init -q "$repo"
# the machine's global core.hooksPath refuses commits on `main`; this throwaway
# fixture repo needs exactly that, so it gets an empty hooks dir of its own
git -C "$repo" -c core.hooksPath="$tmp/nohooks" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m init \
  || { printf 'fixture repo: initial commit failed\n' >&2; exit 1; }
git -C "$repo" branch -M main

# ------------------------------------------------------------------ fixtures

cat >"$fix/issues.json" <<'EOF'
[{"number":7,"title":"Another thing","labels":[],"body":""},
 {"number":49,"title":"Do the thing","labels":[{"name":"mgr:in-flight"}],"body":""}]
EOF
cat >"$fix/issue-7.json" <<'EOF'
{"number":7,"title":"Another thing","state":"OPEN","labels":[],"body":""}
EOF
cat >"$fix/issue-49.json" <<'EOF'
{"number":49,"title":"Do the thing","state":"OPEN","labels":[{"name":"mgr:in-flight"}],"body":""}
EOF

# the manager itself on w9:p1/w9:t1, one managed builder, and one unmanaged
# session on w9:p3/w9:t3 that the adopt sections take over
jq -n --arg cwd "$repo" '
  {result:{agents:[
    {name:"issue-49",pane_id:"w9:p2",tab_id:"w9:t2",workspace_id:"w9",cwd:$cwd,
     agent:"omp",agent_status:"blocked",agent_session:{value:"/dev/null"}},
    {name:"manager",pane_id:"w9:p1",tab_id:"w9:t1",workspace_id:"w9",cwd:$cwd,
     agent:"omp",agent_status:"working",agent_session:{value:"/dev/null"}},
    {name:"feature-x",pane_id:"w9:p3",tab_id:"w9:t3",workspace_id:"w9",cwd:$cwd,
     agent:"omp",agent_status:"working",agent_session:{value:"/dev/null"}}
  ]}}' >"$fix/agents.json"
jq '{result:{agent:(.result.agents[0])}}' "$fix/agents.json" >"$fix/agent-issue-49.json"

# `herdr tab list` has no agents in it — only labels; the manager tab is the one
# labeled `manager`
cat >"$fix/tabs.json" <<'EOF'
{"result":{"tabs":[
  {"tab_id":"w9:t1","label":"manager","workspace_id":"w9"},
  {"tab_id":"w9:t3","label":"stuff","workspace_id":"w9"}
]}}
EOF
cat >"$fix/tabs-nomanager.json" <<'EOF'
{"result":{"tabs":[
  {"tab_id":"w9:t1","label":"#12 something","workspace_id":"w9"},
  {"tab_id":"w9:t3","label":"stuff","workspace_id":"w9"}
]}}
EOF

printf 'Extra house rules:\n- keep it boring\n' >"$fix/extra.md"
printf 'Override rules\n' >"$fix/other.md"

# ------------------------------------------------------------------ fakes

cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'gh %s\n' "$*" >>"$MGR_TEST_LOG"
case "${1:-}" in
  repo)  printf 'owner/name\n';;
  label) exit 0;;
  issue)
    case "${2:-}" in
      list) cat "$MGR_TEST_FIX/issues.json";;
      view)
        case " $* " in *" comments "*) printf '\n'; exit 0;; esac
        f="$MGR_TEST_FIX/issue-${3:-}.json"
        [ -f "$f" ] || exit 1
        cat "$f";;
      edit|comment|close) exit 0;;
      *) exit 1;;
    esac;;
  *) exit 1;;
esac
EOF

cat >"$bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'herdr %s\n' "$*" >>"$MGR_TEST_LOG"
case "${1:-} ${2:-}" in
  "agent list") cat "$MGR_TEST_AGENTS";;
  "tab list")
    if [ "${MGR_TEST_TABS_FAIL:-0}" = 1 ]; then exit 1; fi
    cat "$MGR_TEST_TABS";;
  "tab create")
    printf '{"result":{"tab":{"tab_id":"w9:t7"},"root_pane":{"pane_id":"w9:p7"}}}\n';;
  "tab close")    exit 0;;
  "tab rename")   exit 0;;
  "agent start")  exit 0;;
  "agent rename") exit 0;;
  "agent prompt") printf '%s' "${4:-}" >"$MGR_TEST_PROMPT";;
  "agent get")
    f="$MGR_TEST_FIX/agent-${3:-}.json"
    [ -f "$f" ] || exit 1
    cat "$f";;
  "agent wait")   exit 0;;
  *) exit 1;;
esac
EOF

cat >"$bin/mgr-guard" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'mgr-guard %s\n' "$*" >>"$MGR_TEST_LOG"
case "${1:-}" in
  status)   printf '{"guard":"stopped"}\n';;
  stall)    printf 'null\n';;
  register) exit 0;;
  *) printf '{"error":{"code":2,"message":"usage"}}\n' >&2; exit 2;;
esac
EOF
chmod +x "$bin/gh" "$bin/herdr" "$bin/mgr-guard"

# ------------------------------------------------------------------ env

export PATH="$bin:$PATH"
export MGR_GUARD_BIN="$bin/mgr-guard"
export MGR_STATE_DIR="$tmp/state"
export MGR_TEST_FIX="$fix"
export MGR_TEST_LOG="$tmp/calls.log"
export MGR_TEST_AGENTS="$fix/agents.json"
export MGR_TEST_TABS="$fix/tabs.json"
export MGR_TEST_PROMPT="$tmp/prompt.txt"
export HERDR_WORKSPACE_ID=w9
export HERDR_PANE_ID=w9:p1
export HERDR_TAB_ID=w9:t1
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"

cd "$repo" || exit 1

fails=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s = %s\n' "$1" "$3"
  else
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}
starts_with() { case "$2" in "$1"*) printf true;; *) printf false;; esac; }
contains()    { case "$2" in *"$1"*) printf true;; *) printf false;; esac; }
# every command below runs headless when it goes through this
hl() { env -u HERDR_PANE_ID -u HERDR_TAB_ID "$MGR" "$@"; }

wt="$repo-issue-7-another-thing"
drop_wt() { # remove the launch worktree so the next launch can recreate it
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$repo" branch -D issue-7-another-thing >/dev/null 2>&1 || true
}

# the launch worktree path is derived from the primary checkout
check 'primary is the throwaway repo' "$repo" "$("$MGR" board | jq -r '.primary')"

# --------------------------------------------------- 1. config CRUD

printf '\n# 1. mgr config: git-config backed CRUD\n'
check 'list on a fresh repo' '{"omp-arg":[],"env":[],"brief-extra":null,"cap":null}' \
  "$("$MGR" config list)"
check 'get unset multi'   '{"key":"omp-arg","value":[]}'   "$("$MGR" config get omp-arg)"
check 'get unset single'  '{"key":"cap","value":null}'      "$("$MGR" config get cap)"
check 'set cap'           '{"key":"cap","value":4}'         "$("$MGR" config set cap 4)"
check 'add omp-arg'       '{"key":"omp-arg","value":["--extension"]}' \
  "$("$MGR" config add omp-arg --extension)"
check 'add omp-arg keeps order' \
  '{"key":"omp-arg","value":["--extension","/abs/ext.ts"]}' \
  "$("$MGR" config add omp-arg /abs/ext.ts)"
check 'add env'           '{"key":"env","value":["LINK=ws://127.0.0.1:1/link"]}' \
  "$("$MGR" config add env LINK=ws://127.0.0.1:1/link)"
check 'set brief-extra'   "$(jq -nc --arg v "$fix/extra.md" '{key:"brief-extra",value:$v}')" \
  "$("$MGR" config set brief-extra "$fix/extra.md")"

check 'get omp-arg'  '{"key":"omp-arg","value":["--extension","/abs/ext.ts"]}' \
  "$("$MGR" config get omp-arg)"
check 'get env'      '{"key":"env","value":["LINK=ws://127.0.0.1:1/link"]}' \
  "$("$MGR" config get env)"
check 'get brief-extra' "$(jq -nc --arg v "$fix/extra.md" '{key:"brief-extra",value:$v}')" \
  "$("$MGR" config get brief-extra)"
check 'get cap is a number' '{"key":"cap","value":4}' "$("$MGR" config get cap)"
check 'list' \
  "$(jq -nc --arg be "$fix/extra.md" \
     '{"omp-arg":["--extension","/abs/ext.ts"],env:["LINK=ws://127.0.0.1:1/link"],
       "brief-extra":$be,cap:4}')" \
  "$("$MGR" config list)"

check 'stored in the primary .git/config' "$(printf -- '--extension\n/abs/ext.ts')" \
  "$(git -C "$repo" config --local --get-all mgr.omp-arg)"
check 'stored cap' 4 "$(git -C "$repo" config --local --get-all mgr.cap)"
check 'the working tree stays clean' '' "$(git -C "$repo" status --porcelain)"

check 'unset multi'  '{"key":"env","value":[]}'  "$("$MGR" config unset env)"
check 'unset single' '{"key":"cap","value":null}' "$("$MGR" config unset cap)"
"$MGR" config unset cap >/dev/null; rc=$?
check 'unset twice still exits 0' 0 "$rc"
check 'set replaces the whole list' '{"key":"omp-arg","value":["x"]}' \
  "$("$MGR" config set omp-arg x)"
"$MGR" config unset omp-arg >/dev/null

err=$("$MGR" config get bogus 2>&1 >/dev/null); rc=$?
check 'unknown key exit' 2 "$rc"
check 'unknown key message' 'unknown config key: bogus (omp-arg|env|brief-extra|cap)' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" config add cap 3 2>&1 >/dev/null); rc=$?
check 'add on a single-valued key exit' 2 "$rc"
check 'add on a single-valued key message' 'config key cap is single-valued: use set' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" config set env NOEQ 2>&1 >/dev/null); rc=$?
check 'env without = exit' 2 "$rc"
check 'env without = message' 'env value must be KEY=VALUE: NOEQ' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" config add omp-arg '' 2>&1 >/dev/null); rc=$?
check 'empty omp-arg exit' 2 "$rc"
check 'empty omp-arg message' 'omp-arg must not be empty' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" config set cap x 2>&1 >/dev/null); rc=$?
check 'non-numeric cap exit' 2 "$rc"
check 'non-numeric cap message' 'cap must be a non-negative integer: x' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" config 2>&1 >/dev/null); rc=$?
check 'no subcommand exit' 2 "$rc"
check 'no subcommand message' true \
  "$(starts_with 'usage: mgr config' "$(jq -r '.error.message' <<<"$err")")"

# --------------------------------------------------- 2. cap precedence

printf '\n# 2. cap: --cap > MGR_CAP > git config > 3\n'
"$MGR" config set cap 4 >/dev/null
check 'git config cap'        4 "$("$MGR" board | jq -r '.cap')"
check 'MGR_CAP beats git'     5 "$(MGR_CAP=5 "$MGR" board | jq -r '.cap')"
check '--cap beats MGR_CAP'   6 "$(MGR_CAP=5 "$MGR" board --cap 6 | jq -r '.cap')"
"$MGR" config unset cap >/dev/null
check 'default cap'           3 "$("$MGR" board | jq -r '.cap')"

# --------------------------------------------------- 3. launch wiring

printf '\n# 3. launch: omp-arg after --, one --env per entry, brief-extra appended\n'
"$MGR" config set cap 3 >/dev/null
"$MGR" config add omp-arg --extension >/dev/null
"$MGR" config add omp-arg /abs/ext.ts >/dev/null
"$MGR" config add env LINK=ws://127.0.0.1:1/link >/dev/null
"$MGR" config add env OTHER=x >/dev/null
"$MGR" config set brief-extra "$fix/extra.md" >/dev/null

: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
out=$("$MGR" launch 7); rc=$?
check 'launch exit'      0 "$rc"
check 'launch pane_id'   w9:p7 "$(jq -r '.pane_id' <<<"$out")"
check 'launch worktree'  "$wt" "$(jq -r '.worktree' <<<"$out")"
check 'tab create argv' 1 \
  "$(grep -cxF "herdr tab create --workspace w9 --cwd $wt --label #7 another-thing --env LINK=ws://127.0.0.1:1/link --env OTHER=x --no-focus" "$MGR_TEST_LOG" || true)"
check 'agent start argv' 1 \
  "$(grep -cxF "herdr agent start issue-7 --kind omp --pane w9:p7 --timeout 120000 -- --extension $ext --extension /abs/ext.ts" "$MGR_TEST_LOG" || true)"

prompt=$(cat "$MGR_TEST_PROMPT")
check 'brief head' true \
  "$(starts_with 'You are the builder for issue #7 in owner/name.' "$prompt")"
check 'brief keeps the original tail' true \
  "$(contains 'Begin with: gh issue view 7 --comments' "$prompt")"
check 'brief points at proportionate verification before the first check' true \
  "$(contains 'Verification is proportionate to the change: its Self-review section says which checks a change warrants, so read it before you run any check.' "$prompt")"
check 'brief-extra appended after a blank line' \
  "$(printf '\nExtra house rules:\n- keep it boring')" \
  "$(printf '%s' "$prompt" | tail -n 3)"
check 'brief is brief + blank + 2 extra lines' 4 \
  "$(printf '%s\n' "$prompt" | wc -l | tr -d ' ')"

check 'the worktree exists' true "$(if [ -d "$wt" ]; then printf true; else printf false; fi)"
check 'the worktree is registered' 1 \
  "$(git -C "$repo" worktree list --porcelain | grep -cxF "worktree $wt" || true)"
drop_wt

printf '\n# 3b. a brief-extra that is not readable warns and launches anyway\n'
"$MGR" config set brief-extra "$fix/nope.md" >/dev/null
: >"$MGR_TEST_PROMPT"
err=$("$MGR" launch 7 2>&1 >/dev/null); rc=$?
check 'launch exit' 0 "$rc"
check 'warned about the missing file' 1 \
  "$(printf '%s\n' "$err" | grep -c 'mgr: warning: brief-extra file not found:' || true)"
prompt=$(cat "$MGR_TEST_PROMPT")
check 'brief is the plain one line' 1 "$(printf '%s\n' "$prompt" | wc -l | tr -d ' ')"
check 'brief head' true \
  "$(starts_with 'You are the builder for issue #7 in owner/name.' "$prompt")"
drop_wt

printf '\n# 3c. MGR_OMP_ARGS / MGR_ENV / MGR_BRIEF_EXTRA replace the git values\n'
"$MGR" config set brief-extra "$fix/extra.md" >/dev/null
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
MGR_OMP_ARGS='--foo bar' MGR_ENV='A=1 B=2' MGR_BRIEF_EXTRA="$fix/other.md" \
  "$MGR" launch 7 >/dev/null; rc=$?
check 'launch exit' 0 "$rc"
check 'MGR_OMP_ARGS replaces the git list' 1 \
  "$(grep -cxF "herdr agent start issue-7 --kind omp --pane w9:p7 --timeout 120000 -- --extension $ext --foo bar" "$MGR_TEST_LOG" || true)"
check 'MGR_ENV replaces the git list' 1 \
  "$(grep -cxF "herdr tab create --workspace w9 --cwd $wt --label #7 another-thing --env A=1 --env B=2 --no-focus" "$MGR_TEST_LOG" || true)"
check 'MGR_BRIEF_EXTRA replaces the git path' "$(printf '\nOverride rules')" \
  "$(printf '%s' "$(cat "$MGR_TEST_PROMPT")" | tail -n 2)"
drop_wt

printf '\n# 3d. no config at all: no --env, only the status extension after --\n'
"$MGR" config unset omp-arg >/dev/null
"$MGR" config unset env >/dev/null
"$MGR" config unset brief-extra >/dev/null
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
"$MGR" launch 7 >/dev/null; rc=$?
check 'launch exit' 0 "$rc"
check 'agent start has only the status extension' 1 \
  "$(grep -cxF "herdr agent start issue-7 --kind omp --pane w9:p7 --timeout 120000 -- --extension $ext" "$MGR_TEST_LOG" || true)"
check 'tab create has no --env' 1 \
  "$(grep -cxF "herdr tab create --workspace w9 --cwd $wt --label #7 another-thing --no-focus" "$MGR_TEST_LOG" || true)"
check 'brief has no extra' 1 \
  "$(printf '%s\n' "$(cat "$MGR_TEST_PROMPT")" | wc -l | tr -d ' ')"
drop_wt

# --------------------------------------------------- 4. adopt

printf '\n# 4. adopt: brief-extra applies, omp-arg/env do not\n'
"$MGR" config set brief-extra "$fix/extra.md" >/dev/null
"$MGR" config add omp-arg --extension >/dev/null
"$MGR" config add env LINK=ws://127.0.0.1:1/link >/dev/null

: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
out=$("$MGR" adopt w9:p3 7); rc=$?
check 'adopt (bound) exit'  0 "$rc"
check 'adopt (bound) agent' issue-7 "$(jq -r '.agent' <<<"$out")"
check 'adopt (bound) brief-extra appended' \
  "$(printf '\nExtra house rules:\n- keep it boring')" \
  "$(printf '%s' "$(cat "$MGR_TEST_PROMPT")" | tail -n 3)"
check 'adopt (bound) brief points at proportionate verification' true \
  "$(contains 'Verification is proportionate to the change: its Self-review section' "$(cat "$MGR_TEST_PROMPT")")"
check 'adopt (bound) starts no agent' 0 \
  "$(grep -c 'herdr agent start' "$MGR_TEST_LOG" || true)"
check 'adopt (bound) passes no --env' 0 \
  "$(grep -c -- '--env' "$MGR_TEST_LOG" || true)"

: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
out=$("$MGR" adopt w9:p3); rc=$?
check 'adopt (unbound) exit'  0 "$rc"
check 'adopt (unbound) agent' adopt-w9-p3 "$(jq -r '.agent' <<<"$out")"
check 'adopt (unbound) brief-extra appended' \
  "$(printf '\nExtra house rules:\n- keep it boring')" \
  "$(printf '%s' "$(cat "$MGR_TEST_PROMPT")" | tail -n 3)"
check 'adopt (unbound) brief points at proportionate verification' true \
  "$(contains 'Verification is proportionate to the change: its Self-review section' "$(cat "$MGR_TEST_PROMPT")")"
check 'adopt (unbound) starts no agent' 0 \
  "$(grep -c 'herdr agent start' "$MGR_TEST_LOG" || true)"
check 'adopt (unbound) passes no --env' 0 \
  "$(grep -c -- '--env' "$MGR_TEST_LOG" || true)"

# --------------------------------------------------- 5. board config/manager/self

printf '\n# 5. board: config, manager, self\n'
"$MGR" config set cap 4 >/dev/null
: >"$MGR_TEST_LOG"
out=$("$MGR" board)
check 'board .config' \
  "$(jq -nc --arg be "$fix/extra.md" \
     '{"omp-arg":["--extension"],env:["LINK=ws://127.0.0.1:1/link"],
       "brief-extra":$be,cap:4}')" \
  "$(jq -c '.config' <<<"$out")"
check 'board .config.cap == .cap' true \
  "$(jq -r '.config.cap == .cap' <<<"$out")"
manager=$(jq -nc --arg cwd "$repo" \
  '{pane_id:"w9:p1",tab_id:"w9:t1",agent:"manager",cwd:$cwd}')
check 'board .manager' "$manager" "$(jq -c '.manager' <<<"$out")"
check 'board .self'    w9:p1     "$(jq -r '.self' <<<"$out")"
check 'the manager tab was looked up' 1 \
  "$(grep -cx 'herdr tab list --workspace w9' "$MGR_TEST_LOG" || true)"

out=$(hl board); rc=$?
check 'headless board exit'    0 "$rc"
check 'headless .self'         null "$(jq -r '.self' <<<"$out")"
check 'headless .manager'      "$manager" "$(jq -c '.manager' <<<"$out")"
check 'the manager is not adoptable' false \
  "$(jq -r '([.unmanaged[].pane_id] | index("w9:p1")) != null' <<<"$out")"
check 'other sessions still are' true \
  "$(jq -r '([.unmanaged[].pane_id] | index("w9:p3")) != null' <<<"$out")"

check 'no manager label -> null' null \
  "$(MGR_TEST_TABS="$fix/tabs-nomanager.json" "$MGR" board | jq -r '.manager')"
out=$(MGR_TEST_TABS_FAIL=1 "$MGR" board 2>/dev/null); rc=$?
check 'tab list failure exit' 0 "$rc"
check 'tab list failure -> null manager' null "$(jq -r '.manager' <<<"$out")"

# --------------------------------------------------- 6. headless commands

printf '\n# 6. headless: only HERDR_WORKSPACE_ID set\n'
"$MGR" config unset omp-arg >/dev/null
"$MGR" config unset env >/dev/null
"$MGR" config unset brief-extra >/dev/null
"$MGR" config unset cap >/dev/null

hl config list >/dev/null; rc=$?; check 'headless config list' 0 "$rc"
hl board >/dev/null;       rc=$?; check 'headless board'       0 "$rc"
hl prompt 49 hello >/dev/null; rc=$?; check 'headless prompt'  0 "$rc"
hl wait 49 >/dev/null;     rc=$?; check 'headless wait'        0 "$rc"
hl retire 49 >/dev/null 2>&1; rc=$?; check 'headless retire'   0 "$rc"
hl launch 7 >/dev/null;    rc=$?; check 'headless launch'      0 "$rc"
drop_wt
hl adopt w9:p3 7 >/dev/null; rc=$?; check 'headless adopt'     0 "$rc"
err=$(hl bind 7 2>&1 >/dev/null); rc=$?
check 'headless bind exit' 3 "$rc"
check 'headless bind explains why' true \
  "$(contains 'HERDR_PANE_ID unset' "$(jq -r '.error.message' <<<"$err")")"

# --------------------------------------------------- 7. usage

printf '\n# 7. usage lists the config surface\n'
check 'usage lists mgr config' 1 \
  "$("$MGR" --help | grep -c 'mgr config <set|add|get|unset|list>' || true)"
for v in MGR_OMP_ARGS MGR_ENV MGR_BRIEF_EXTRA MGR_CAP HERDR_WORKSPACE_ID; do
  check "usage lists $v" 1 "$("$MGR" --help | grep -c "$v" || true)"
done

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'all checks passed\n'; exit 0; fi
printf '%d check(s) failed\n' "$fails"; exit 1
