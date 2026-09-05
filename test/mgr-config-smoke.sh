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
# and is briefed with the workflow file of its size, from the same checkout
wf="$(cd "$here/.." && pwd -P)/workflows"
# and with the model-role overlay of its house, from omp/packages/
pkgs="$(cd "$here/.." && pwd -P)/omp/packages"
# the paths `mgr` reports as itself and as the contract (readlink -f of $MGR)
MGR_REAL="$(cd "$here/.." && pwd -P)/bin/mgr"
MGR_REAL_BUILDER="$(cd "$here/.." && pwd -P)/builder.md"
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
[{"number":7,"title":"Another thing","labels":[{"name":"size:small"}],"body":""},
 {"number":49,"title":"Do the thing","labels":[{"name":"mgr:in-flight"},{"name":"size:large"}],"body":""}]
EOF
cat >"$fix/issue-7.json" <<'EOF'
{"number":7,"title":"Another thing","state":"OPEN","labels":[{"name":"size:small"}],"body":""}
EOF
cat >"$fix/issue-49.json" <<'EOF'
{"number":49,"title":"Do the thing","state":"OPEN","labels":[{"name":"mgr:in-flight"},{"name":"size:large"}],"body":""}
EOF
# the same issue 7 without a size label, and with two of them: `mgr launch`
# refuses on both, `mgr size` fixes both
cat >"$fix/issue-7-nosize.json" <<'EOF'
{"number":7,"title":"Another thing","state":"OPEN","labels":[],"body":""}
EOF
cat >"$fix/issue-7-twosizes.json" <<'EOF'
{"number":7,"title":"Another thing","state":"OPEN","labels":[{"name":"size:tiny"},{"name":"size:large"}],"body":""}
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
        # MGR_TEST_ISSUE_VARIANT swaps in a variant fixture of the same issue
        # (e.g. -nosize), so a case can change its labels without new fakes
        f="$MGR_TEST_FIX/issue-${3:-}${MGR_TEST_ISSUE_VARIANT:-}.json"
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
export MGR_TEST_ISSUE_VARIANT=       # set per case; empty = the labelled fixtures
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
check 'list on a fresh repo' \
  '{"omp-arg":[],"env":[],"brief-extra":null,"cap":null,"house":null,"rigor":null,"sizing":null}' \
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
check 'set house'         '{"key":"house","value":"openai"}' \
  "$("$MGR" config set house openai)"
check 'get house'         '{"key":"house","value":"openai"}' \
  "$("$MGR" config get house)"
check 'set house again replaces it' '{"key":"house","value":"anthropic"}' \
  "$("$MGR" config set house anthropic)"
check 'house is stored under mgr.house' anthropic \
  "$(git -C "$repo" config --local --get-all mgr.house)"
err=$("$MGR" config set house bogus 2>&1 >/dev/null); rc=$?
check 'a bogus house exit' 2 "$rc"
check 'a bogus house message' 'house must be one of anthropic|openai|gemini: bogus' \
  "$(jq -r '.error.message' <<<"$err")"
check 'unset house' '{"key":"house","value":null}' "$("$MGR" config unset house)"
check 'get rigor unset'   '{"key":"rigor","value":null}' "$("$MGR" config get rigor)"
check 'set rigor'         '{"key":"rigor","value":"sprint"}' \
  "$("$MGR" config set rigor sprint)"
check 'set rigor production' '{"key":"rigor","value":"production"}' \
  "$("$MGR" config set rigor production)"
"$MGR" config set rigor sprint >/dev/null
check 'rigor is stored under mgr.rigor' sprint \
  "$(git -C "$repo" config --local --get-all mgr.rigor)"
check 'the working tree stays clean after set rigor' '' "$(git -C "$repo" status --porcelain)"
check 'unset rigor' '{"key":"rigor","value":null}' "$("$MGR" config unset rigor)"
err=$("$MGR" config set rigor bogus 2>&1 >/dev/null); rc=$?
check 'a bogus rigor exit' 2 "$rc"
check 'a bogus rigor message' 'rigor must be one of sprint|production: bogus' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" config add rigor x 2>&1 >/dev/null); rc=$?
check 'add rigor (single-valued) exit' 2 "$rc"
check 'add rigor (single-valued) message' 'config key rigor is single-valued: use set' \
  "$(jq -r '.error.message' <<<"$err")"
check 'get sizing unset'    '{"key":"sizing","value":null}' "$("$MGR" config get sizing)"
check 'set sizing lean'     '{"key":"sizing","value":"lean"}' \
  "$("$MGR" config set sizing lean)"
check 'set sizing balanced' '{"key":"sizing","value":"balanced"}' \
  "$("$MGR" config set sizing balanced)"
check 'set sizing careful'  '{"key":"sizing","value":"careful"}' \
  "$("$MGR" config set sizing careful)"
"$MGR" config set sizing lean >/dev/null
check 'sizing is stored under mgr.sizing' lean \
  "$(git -C "$repo" config --local --get-all mgr.sizing)"
check 'the working tree stays clean after set sizing' '' "$(git -C "$repo" status --porcelain)"
check 'unset sizing' '{"key":"sizing","value":null}' "$("$MGR" config unset sizing)"
err=$("$MGR" config set sizing bogus 2>&1 >/dev/null); rc=$?
check 'a bogus sizing exit' 2 "$rc"
check 'a bogus sizing message' 'sizing must be one of lean|balanced|careful: bogus' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" config add sizing x 2>&1 >/dev/null); rc=$?
check 'add sizing (single-valued) exit' 2 "$rc"
check 'add sizing (single-valued) message' 'config key sizing is single-valued: use set' \
  "$(jq -r '.error.message' <<<"$err")"

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
       "brief-extra":$be,cap:4,house:null,rigor:null,sizing:null}')" \
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
check 'unknown key message' \
  'unknown config key: bogus (omp-arg|env|brief-extra|cap|house|rigor|sizing)' \
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

# --------------------------------------------------- 2b. rigor precedence

printf '\n# 2b. rigor: MGR_RIGOR > git config > production, bad values warn to stderr\n'
"$MGR" config set rigor sprint >/dev/null
check 'git config rigor'           sprint     "$("$MGR" board | jq -r '.rigor')"
check 'MGR_RIGOR beats git config' production "$(MGR_RIGOR=production "$MGR" board | jq -r '.rigor')"
"$MGR" config unset rigor >/dev/null
check 'default rigor'              production "$("$MGR" board | jq -r '.rigor')"

: >"$tmp/rigor.err"
out=$(MGR_RIGOR=bogus "$MGR" board 2>"$tmp/rigor.err")
check 'bad MGR_RIGOR: board stdout still parses as JSON' true \
  "$(jq -e . >/dev/null 2>&1 <<<"$out" && printf true || printf false)"
check 'bad MGR_RIGOR: falls back to production' production "$(jq -r '.rigor' <<<"$out")"
check 'bad MGR_RIGOR: warns on stderr' true \
  "$(contains 'mgr: warning: rigor must be one of sprint|production: bogus — verifying as production' \
     "$(cat "$tmp/rigor.err")")"
check 'bad MGR_RIGOR: warns exactly once' 1 "$(wc -l <"$tmp/rigor.err" | tr -d ' ')"

git -C "$repo" config --local mgr.rigor bogus
: >"$tmp/rigor2.err"
out=$("$MGR" board 2>"$tmp/rigor2.err")
check 'hand-edited store: falls back to production' production "$(jq -r '.rigor' <<<"$out")"
check 'hand-edited store: warns exactly once' 1 "$(wc -l <"$tmp/rigor2.err" | tr -d ' ')"
check 'hand-edited store: config get still echoes the raw value' \
  '{"key":"rigor","value":"bogus"}' "$("$MGR" config get rigor)"
"$MGR" config unset rigor >/dev/null

# --------------------------------------------------- 2c. sizing precedence

printf '\n# 2c. sizing: MGR_SIZING > git config > balanced, bad values warn to stderr\n'
"$MGR" config set sizing careful >/dev/null
check 'git config sizing'           careful  "$("$MGR" board | jq -r '.sizing')"
check 'MGR_SIZING beats git config' lean     "$(MGR_SIZING=lean "$MGR" board | jq -r '.sizing')"
check 'board .config.sizing tracks a non-default' careful "$("$MGR" board | jq -r '.config.sizing')"
"$MGR" config unset sizing >/dev/null
check 'default sizing'              balanced "$("$MGR" board | jq -r '.sizing')"

: >"$tmp/sizing.err"
out=$(MGR_SIZING=bogus "$MGR" board 2>"$tmp/sizing.err")
check 'bad MGR_SIZING: board stdout still parses as JSON' true \
  "$(jq -e . >/dev/null 2>&1 <<<"$out" && printf true || printf false)"
check 'bad MGR_SIZING: falls back to balanced' balanced "$(jq -r '.sizing' <<<"$out")"
check 'bad MGR_SIZING: warns on stderr' true \
  "$(contains 'mgr: warning: sizing must be one of lean|balanced|careful: bogus — sizing as balanced' \
     "$(cat "$tmp/sizing.err")")"
check 'bad MGR_SIZING: warns exactly once' 1 "$(wc -l <"$tmp/sizing.err" | tr -d ' ')"

git -C "$repo" config --local mgr.sizing bogus
: >"$tmp/sizing2.err"
out=$("$MGR" board 2>"$tmp/sizing2.err")
check 'hand-edited store: falls back to balanced' balanced "$(jq -r '.sizing' <<<"$out")"
check 'hand-edited store: sizing warns exactly once' 1 "$(wc -l <"$tmp/sizing2.err" | tr -d ' ')"
check 'hand-edited store: config get sizing still echoes the raw value' \
  '{"key":"sizing","value":"bogus"}' "$("$MGR" config get sizing)"
"$MGR" config unset sizing >/dev/null

# --------------------------------------------------- 3. launch wiring

printf '\n# 3. launch: --model @builder + the house overlay, then omp-arg after --, one --env per entry, brief-extra appended\n'
"$MGR" config set cap 3 >/dev/null
"$MGR" config add omp-arg --extension >/dev/null
"$MGR" config add omp-arg /abs/ext.ts >/dev/null
"$MGR" config add env LINK=ws://127.0.0.1:1/link >/dev/null
"$MGR" config add env OTHER=x >/dev/null
"$MGR" config set brief-extra "$fix/extra.md" >/dev/null
"$MGR" config set house anthropic >/dev/null

: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
out=$("$MGR" launch 7); rc=$?
check 'launch exit'      0 "$rc"
check 'launch pane_id'   w9:p7 "$(jq -r '.pane_id' <<<"$out")"
check 'launch worktree'  "$wt" "$(jq -r '.worktree' <<<"$out")"
check 'tab create argv' 1 \
  "$(grep -cxF "herdr tab create --workspace w9 --cwd $wt --label #7 another-thing --env LINK=ws://127.0.0.1:1/link --env OTHER=x --no-focus" "$MGR_TEST_LOG" || true)"
check 'agent start argv' 1 \
  "$(grep -cxF "herdr agent start issue-7 --kind omp --pane w9:p7 --timeout 120000 -- --extension $ext --model @builder --config $pkgs/anthropic.yml --extension /abs/ext.ts" "$MGR_TEST_LOG" || true)"

prompt=$(cat "$MGR_TEST_PROMPT")
check 'brief head' true \
  "$(starts_with 'You are the builder for issue #7 in owner/name.' "$prompt")"
check 'brief keeps the original tail' true \
  "$(contains 'Begin with: gh issue view 7 --comments' "$prompt")"
check 'brief names the size' true "$(contains 'Size: small.' "$prompt")"
check 'brief names the house' true \
  "$(contains 'Size: small. House: anthropic. Rigor: production. Sizing: balanced. Read' "$prompt")"
check 'brief sends the builder to its workflow file' true \
  "$(contains "Its Build section sends you to $wf/small.md, which is how you build and verify at your size — read it before you touch code." "$prompt")"
check 'brief drops the old proportionate-verification sentence' false \
  "$(contains 'Verification is proportionate' "$prompt")"
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
  "$(grep -cxF "herdr agent start issue-7 --kind omp --pane w9:p7 --timeout 120000 -- --extension $ext --model @builder --config $pkgs/anthropic.yml --foo bar" "$MGR_TEST_LOG" || true)"
check 'MGR_ENV replaces the git list' 1 \
  "$(grep -cxF "herdr tab create --workspace w9 --cwd $wt --label #7 another-thing --env A=1 --env B=2 --no-focus" "$MGR_TEST_LOG" || true)"
check 'MGR_BRIEF_EXTRA replaces the git path' "$(printf '\nOverride rules')" \
  "$(printf '%s' "$(cat "$MGR_TEST_PROMPT")" | tail -n 2)"
drop_wt

printf '\n# 3d. no config at all: no --env, only the status extension and the model after --\n'
"$MGR" config unset omp-arg >/dev/null
"$MGR" config unset env >/dev/null
"$MGR" config unset brief-extra >/dev/null
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
"$MGR" launch 7 >/dev/null; rc=$?
check 'launch exit' 0 "$rc"
check 'agent start has only the status extension and the model' 1 \
  "$(grep -cxF "herdr agent start issue-7 --kind omp --pane w9:p7 --timeout 120000 -- --extension $ext --model @builder --config $pkgs/anthropic.yml" "$MGR_TEST_LOG" || true)"
check 'tab create has no --env' 1 \
  "$(grep -cxF "herdr tab create --workspace w9 --cwd $wt --label #7 another-thing --no-focus" "$MGR_TEST_LOG" || true)"
check 'brief has no extra' 1 \
  "$(printf '%s\n' "$(cat "$MGR_TEST_PROMPT")" | wc -l | tr -d ' ')"
drop_wt

printf '\n# 3e. the size label is a launch precondition\n'
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
err=$(MGR_TEST_ISSUE_VARIANT=-nosize "$MGR" launch 7 2>&1 >/dev/null); rc=$?
check 'no size label: exit' 3 "$rc"
check 'no size label: code' 3 "$(jq -r '.error.code' <<<"$err")"
check 'no size label: message names the fix' \
  "issue #7 has no size: label; add exactly one with: gh issue edit 7 --add-label size:<tiny|small|medium|large> (or: $MGR_REAL size 7 <size>)" \
  "$(jq -r '.error.message' <<<"$err")"
check 'no size label: nothing was created' 0 \
  "$(grep -c 'herdr tab create' "$MGR_TEST_LOG" || true)"
check 'no size label: no worktree' false \
  "$(if [ -d "$wt" ]; then printf true; else printf false; fi)"

err=$(MGR_TEST_ISSUE_VARIANT=-twosizes "$MGR" launch 7 2>&1 >/dev/null); rc=$?
check 'two size labels: exit' 3 "$rc"
check 'two size labels: message names them and the fix' \
  "issue #7 has several size: labels (large tiny); remove all but one with: gh issue edit 7 --remove-label size:<size> (or: $MGR_REAL size 7 <size>)" \
  "$(jq -r '.error.message' <<<"$err")"

printf '\n# 3f. mgr size swaps the label; a live builder resizes itself\n'
: >"$MGR_TEST_LOG"
check 'size 7 medium' '{"number":7,"size":"medium"}' "$("$MGR" size 7 medium)"
check 'size 7 medium: one gh edit, add then remove' 1 \
  "$(grep -cxF 'gh issue edit 7 --add-label size:medium --remove-label size:small' \
     "$MGR_TEST_LOG" || true)"
check 'size 7 medium: the size labels exist first' 1 \
  "$(grep -cxF 'gh label create size:medium --color 5319e7 --force --description builder workflow and model: medium' \
     "$MGR_TEST_LOG" || true)"
check 'size on an issue that already has it drops no label' \
  '{"number":7,"size":"small"}' "$("$MGR" size 7 small)"
check 'size 7 small: add only' 1 \
  "$(grep -cxF 'gh issue edit 7 --add-label size:small' "$MGR_TEST_LOG" || true)"
err=$("$MGR" size 49 tiny 2>&1 >/dev/null); rc=$?
check 'size on an in-flight issue: exit' 3 "$rc"
check 'size on an in-flight issue: message' \
  'issue #49 is in flight; its builder resizes itself (comment builder: resized <from>→<to> and swap the label)' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" size 7 huge 2>&1 >/dev/null); rc=$?
check 'a bogus size: exit' 2 "$rc"
check 'a bogus size: message' 'size must be one of tiny|small|medium|large: huge' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" size 7 2>&1 >/dev/null); rc=$?
check 'size without a size word: exit' 2 "$rc"
check 'size usage message' 'usage: mgr size <N> <tiny|small|medium|large>' \
  "$(jq -r '.error.message' <<<"$err")"

printf '\n# 3g. the house: --house > MGR_HOUSE > mgr config house > this session\n'
: >"$MGR_TEST_LOG"
"$MGR" launch 7 --house gemini >/dev/null
check '--house wins over the store' 1 \
  "$(grep -cF -- "--config $pkgs/gemini.yml" "$MGR_TEST_LOG" || true)"
drop_wt
: >"$MGR_TEST_LOG"
MGR_HOUSE=openai "$MGR" launch 7 >/dev/null
check 'MGR_HOUSE wins over the store' 1 \
  "$(grep -cF -- "--config $pkgs/openai.yml" "$MGR_TEST_LOG" || true)"
drop_wt
: >"$MGR_TEST_LOG"
MGR_HOUSE=openai "$MGR" launch 7 --house anthropic >/dev/null
check '--house wins over MGR_HOUSE' 1 \
  "$(grep -cF -- "--config $pkgs/anthropic.yml" "$MGR_TEST_LOG" || true)"
drop_wt
check 'board carries the resolved house' anthropic "$("$MGR" board | jq -r '.house')"

# nothing configured and a manager session that names no provider: `mgr launch`
# has no package to overlay and says so
"$MGR" config unset house >/dev/null
: >"$MGR_TEST_LOG"
err=$("$MGR" launch 7 2>&1 >/dev/null); rc=$?
check 'no house: exit' 3 "$rc"
check 'no house: message names the fix' \
  'cannot determine the model house; run: mgr config set house <anthropic|openai|gemini>' \
  "$(jq -r '.error.message' <<<"$err")"
check 'no house: nothing was created' 0 \
  "$(grep -c 'herdr tab create' "$MGR_TEST_LOG" || true)"
check 'board house is null when nothing resolves' null "$("$MGR" board | jq -r '.house')"
err=$("$MGR" launch 7 --house bogus 2>&1 >/dev/null); rc=$?
check 'a bogus --house exit' 2 "$rc"
check 'a bogus --house message' 'house must be one of anthropic|openai|gemini: bogus' \
  "$(jq -r '.error.message' <<<"$err")"
"$MGR" config set house anthropic >/dev/null

# --------------------------------------------------- 3h. rigor in the brief

printf '\n# 3h. rigor: the brief carries the configured value; a bad env value degrades to production\n'
"$MGR" config set rigor sprint >/dev/null
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
"$MGR" launch 7 >/dev/null; rc=$?
check 'launch exit (rigor sprint)' 0 "$rc"
check 'brief names rigor sprint' true "$(contains 'Rigor: sprint.' "$(cat "$MGR_TEST_PROMPT")")"
drop_wt
"$MGR" config unset rigor >/dev/null

: >"$MGR_TEST_PROMPT"
err=$(MGR_RIGOR=bogus "$MGR" launch 7 2>&1 >/dev/null); rc=$?
check 'bad MGR_RIGOR: launch still exits 0' 0 "$rc"
check 'bad MGR_RIGOR: brief still carries production' true \
  "$(contains 'Rigor: production.' "$(cat "$MGR_TEST_PROMPT")")"
check 'bad MGR_RIGOR: launch warns exactly once' 1 \
  "$(printf '%s\n' "$err" | grep -c 'mgr: warning: rigor must be one of sprint|production: bogus' || true)"
drop_wt

# --------------------------------------------------- 3i. sizing in the brief

printf '\n# 3i. sizing: the brief carries the configured value; a bad env value degrades to balanced\n'
"$MGR" config set sizing careful >/dev/null
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
"$MGR" launch 7 >/dev/null; rc=$?
check 'launch exit (sizing careful)' 0 "$rc"
check 'brief names sizing careful' true "$(contains 'Sizing: careful.' "$(cat "$MGR_TEST_PROMPT")")"
drop_wt
"$MGR" config unset sizing >/dev/null

: >"$MGR_TEST_PROMPT"
err=$(MGR_SIZING=bogus "$MGR" launch 7 2>&1 >/dev/null); rc=$?
check 'bad MGR_SIZING: launch still exits 0' 0 "$rc"
check 'bad MGR_SIZING: brief still carries balanced' true \
  "$(contains 'Sizing: balanced.' "$(cat "$MGR_TEST_PROMPT")")"
check 'bad MGR_SIZING: launch warns exactly once' 1 \
  "$(printf '%s\n' "$err" | grep -c 'mgr: warning: sizing must be one of lean|balanced|careful: bogus' || true)"
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
check 'adopt (bound) brief carries the labelled size, the house and its workflow' true \
  "$(contains "Size: small. House: anthropic. Rigor: production. Sizing: balanced. Read $MGR_REAL_BUILDER now and follow it exactly; it is your complete contract. Its Build section sends you to $wf/small.md," \
     "$(cat "$MGR_TEST_PROMPT")")"
check 'adopt (bound) starts no agent' 0 \
  "$(grep -c 'herdr agent start' "$MGR_TEST_LOG" || true)"
check 'adopt (bound) passes no --env' 0 \
  "$(grep -c -- '--env' "$MGR_TEST_LOG" || true)"

# an adoptee is mid-work: no size label is briefed as medium, never refused
: >"$MGR_TEST_PROMPT"
MGR_TEST_ISSUE_VARIANT=-nosize "$MGR" adopt w9:p3 7 >/dev/null; rc=$?
check 'adopt (bound, unlabelled) exit' 0 "$rc"
check 'adopt (bound, unlabelled) is briefed as medium' true \
  "$(contains "Size: medium." "$(cat "$MGR_TEST_PROMPT")")"
check 'adopt (bound, unlabelled) points at medium.md' true \
  "$(contains "$wf/medium.md" "$(cat "$MGR_TEST_PROMPT")")"
: >"$MGR_TEST_PROMPT"
MGR_TEST_ISSUE_VARIANT=-twosizes "$MGR" adopt w9:p3 7 >/dev/null; rc=$?
check 'adopt (bound, ambiguous) exit' 0 "$rc"
check 'adopt (bound, ambiguous) is briefed as medium' true \
  "$(contains "Size: medium." "$(cat "$MGR_TEST_PROMPT")")"

# no house resolves: the adopt brief simply leaves House out — never a refusal
"$MGR" config unset house >/dev/null
: >"$MGR_TEST_PROMPT"
"$MGR" adopt w9:p3 7 >/dev/null; rc=$?
check 'adopt (bound, no house) exit' 0 "$rc"
check 'adopt (bound, no house) omits House' true \
  "$(contains 'Size: small. Rigor: production. Sizing: balanced. Read ' "$(cat "$MGR_TEST_PROMPT")")"
check 'adopt (bound, no house) says House nowhere' false \
  "$(contains 'House: ' "$(cat "$MGR_TEST_PROMPT")")"
"$MGR" config set house anthropic >/dev/null

: >"$MGR_TEST_LOG"; : >"$MGR_TEST_PROMPT"
out=$("$MGR" adopt w9:p3); rc=$?
check 'adopt (unbound) exit'  0 "$rc"
check 'adopt (unbound) agent' adopt-w9-p3 "$(jq -r '.agent' <<<"$out")"
check 'adopt (unbound) brief-extra appended' \
  "$(printf '\nExtra house rules:\n- keep it boring')" \
  "$(printf '%s' "$(cat "$MGR_TEST_PROMPT")" | tail -n 3)"
check 'adopt (unbound) carries the house and no size of its own' true \
  "$(contains 'Policy: auto-merge. House: anthropic. Rigor: production. Sizing: balanced. Resume your work only after bind succeeds.' \
     "$(cat "$MGR_TEST_PROMPT")")"
check 'adopt (unbound) briefs no size: the session sizes itself' false \
  "$(contains 'Size: ' "$(cat "$MGR_TEST_PROMPT")")"
check 'adopt (unbound) tells the session to label the issue it creates' true \
  "$(contains 'Add exactly one size label to that issue, sized by the work you are doing: gh issue edit <new issue number> --add-label size:<tiny|small|medium|large>, then run' \
     "$(cat "$MGR_TEST_PROMPT")")"
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
       "brief-extra":$be,cap:4,rigor:"production",sizing:"balanced"}')" \
  "$(jq -c '.config' <<<"$out")"
check 'board .config.cap == .cap' true \
  "$(jq -r '.config.cap == .cap' <<<"$out")"
check 'board .config.rigor' production "$(jq -r '.config.rigor' <<<"$out")"
check 'board .config.rigor == .rigor' true \
  "$(jq -r 'if .config.rigor == .rigor then "true" else "false" end' <<<"$out")"
check 'board .config.sizing' balanced "$(jq -r '.config.sizing' <<<"$out")"
check 'board .config.sizing == .sizing' true \
  "$(jq -r 'if .config.sizing == .sizing then "true" else "false" end' <<<"$out")"
manager=$(jq -nc --arg cwd "$repo" \
  '{pane_id:"w9:p1",tab_id:"w9:t1",agent:"manager",cwd:$cwd}')
check 'board .manager' "$manager" "$(jq -c '.manager' <<<"$out")"
check 'board .self'    w9:p1     "$(jq -r '.self' <<<"$out")"
check 'the manager tab was looked up' 1 \
  "$(grep -cx 'herdr tab list --workspace w9' "$MGR_TEST_LOG" || true)"
# every issue row carries the size its label says, or null
check 'board in_flight row size' large \
  "$(jq -r '.in_flight[] | select(.number==49) | .size' <<<"$out")"
check 'board ready row size' small \
  "$(jq -r '.ready[] | select(.number==7) | .size' <<<"$out")"
check 'board ready row keys' '["number","title","policy","size","blocked_by"]' \
  "$(jq -c '.ready[0] | keys_unsorted' <<<"$out")"

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

# --------------------------------------------------- 5b. paths and labels

printf '\n# 5b. paths carries the workflows and omp dirs; labels covers mgr:* and size:*\n'
out=$("$MGR" paths)
check 'paths keys' '["root","skill_md","builder_md","workflows","omp","mgr"]' \
  "$(jq -c 'keys_unsorted' <<<"$out")"
check 'paths workflows' "$wf" "$(jq -r '.workflows' <<<"$out")"
check 'paths workflows is absolute and ends in /workflows' true \
  "$(jq -r '.workflows | startswith("/") and endswith("/workflows")' <<<"$out")"
check 'paths omp is absolute and ends in /omp' true \
  "$(jq -r '.omp | startswith("/") and endswith("/omp")' <<<"$out")"
check 'labels' \
  '{"labels":["mgr:in-flight","mgr:awaiting-approval","mgr:manual-approve","size:tiny","size:small","size:medium","size:large"]}' \
  "$("$MGR" labels)"

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
check 'usage mentions rigor in the config clause' true \
  "$(if [ "$("$MGR" --help | grep -c 'rigor' || true)" -ge 1 ]; then printf true; else printf false; fi)"
check 'usage mentions sizing in the config clause' 1 \
  "$("$MGR" --help | grep -c '(lean|balanced|careful' || true)"
for v in MGR_OMP_ARGS MGR_ENV MGR_BRIEF_EXTRA MGR_CAP MGR_RIGOR MGR_SIZING HERDR_WORKSPACE_ID; do
  check "usage lists $v" 1 "$("$MGR" --help | grep -c "$v" || true)"
done

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'all checks passed\n'; exit 0; fi
printf '%d check(s) failed\n' "$fails"; exit 1
