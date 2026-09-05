#!/usr/bin/env bash
# mgr-quota-smoke.sh — smoke test for the quota-guard integration in bin/mgr.
#
# Self-contained and hermetic: fake `gh` and `herdr` on a temp PATH, a fake
# `mgr-guard` reached through MGR_GUARD_BIN (never placed next to bin/mgr), a
# throwaway git repo as cwd, MGR_STATE_DIR in the temp dir. No network, no live
# herdr session, no omp. Exits non-zero on the first failed expectation.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
MGR="$here/../bin/mgr"
[ -x "$MGR" ] || { printf 'not executable: %s\n' "$MGR" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; fix="$tmp/fix"; repo="$tmp/repo"
mkdir -p "$bin" "$fix" "$repo" "$tmp/state"
git init -q "$repo"

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

sess="$tmp/session-49.jsonl"
: >"$sess"
jq -n --arg cwd "$repo" --arg sess "$sess" '
  {result:{agents:[
    {name:"issue-49",pane_id:"w9:p2",tab_id:"w9:t2",workspace_id:"w9",cwd:$cwd,
     agent:"omp",agent_status:"blocked",agent_session:{value:$sess}},
    {name:"manager",pane_id:"w9:p1",tab_id:"w9:t1",workspace_id:"w9",cwd:$cwd,
     agent:"omp",agent_status:"working",agent_session:{value:"/dev/null"}}
  ]}}' >"$fix/agents.json"
jq '{result:{agent:(.result.agents[0])}}' "$fix/agents.json" >"$fix/agent-issue-49.json"

# guard running: allotment 1 for this workspace, issue-49 stalled on anthropic,
# this repo at priority 7 (the top priority, so derived_cap == its own cap 3)
# while the machine as a whole is quota-constrained
cat >"$fix/guard-running.json" <<'EOF'
{"version":1,"guard":"running","pid":4242,"tick_at":1788523750609,"interval_s":60,
 "builder_provider":"anthropic",
 "providers":{"anthropic":{"status":"warning","fetched_at":1788523750000,
   "limits":[{"id":"anthropic:5h","label":"Claude 5 Hour","status":"warning","used":0.62,
              "resets_at":1788530000000,"burn_per_hour":0.3,"projected_at_reset":1.23,"fits":false}],
   "binding_limit":"anthropic:5h","recovers_at":null,
   "active_builders":3,"ceiling":6,"allowed_total":1,
   "reason":"projected 1.23 > 1 on anthropic:5h (burn 0.30/h, 2.1h to reset)"}},
 "allowed_total":1,"constrained":true,"demand_total":7,
 "top_priority":7,"top_cap":3,
 "priorities":{"owner/name":7,"other/proj":2},
 "managers":{"ws-w9":{"manager_id":"ws-w9","workspace_id":"w9","pane_id":"w9:p1",
   "repo":"owner/name","cap":3,"in_flight":1,"adopting":0,"ready":1,"demand":2,
   "seen_at":1788523750609,"pane_alive":true,"live":true,
   "allotment":1,"priority":7,"paused":false,
   "derived_cap":3,"demand_effective":2,
   "active_builders":1}},
 "stalled":[{"pane_id":"w9:p2","name":"issue-49","workspace_id":"w9","session":"/x.jsonl",
   "provider":"anthropic","model":"claude-fable-5-1","error":"429 rate_limit_error",
   "since":1788520000000,"retry_after_ms":976000,"attempts":1,
   "last_reignite_at":null,"next_reignite_at":1788521000000,"cause":"429"}],
 "events":[]}
EOF

# guard stopped: same (now stale) ledger, allotment 1 — mgr must NOT throttle.
# A stopped guard also carries the exit record it wrote on its way out.
jq '.guard="stopped" | .pid=null | .providers.anthropic.status="exhausted"
    | .providers.anthropic.recovers_at=1788530000000
    | .providers.anthropic.allowed_total=0 | .allowed_total=0
    | .providers.anthropic.reason="exhausted: anthropic:5h resets at 2026-09-04T12:00:00Z"
    | .last_exit_at=1788523800000
    | .last_exit_reason="idle-exit after 1800s with no live manager and nothing held"' \
  "$fix/guard-running.json" >"$fix/guard-stopped.json"

cat >"$fix/stall-49.json" <<'EOF'
{"provider":"anthropic","model":"claude-fable-5-1",
 "error":"429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}} retry-after-ms=976000",
 "since":1788520000000,"retry_after_ms":976000}
EOF

# same guard, but this project is now the low-priority one: priority 2 against a
# top of 9 (cap 3) derives a cap of 1 (the floor), and the constrained quota
# still leaves it allotment 0, so its only builder is held with cause "paused"
jq '.priorities={"owner/name":2,"other/proj":9}
    | .top_priority=9 | .top_cap=3
    | .managers["ws-w9"] += {allotment:0,priority:2,paused:true,active_builders:0,
                             derived_cap:1,demand_effective:1}
    | .stalled=[{pane_id:"w9:p2",name:"issue-49",workspace_id:"w9",session:"/x.jsonl",
                 provider:"anthropic",model:null,error:null,since:1788522000000,
                 retry_after_ms:null,attempts:0,last_reignite_at:null,next_reignite_at:null,
                 cause:"paused",paused_at:1788522000000,esc_sent:1,manager_id:"ws-w9"}]' \
  "$fix/guard-running.json" >"$fix/guard-paused.json"
jq '.guard="stopped" | .pid=null' "$fix/guard-paused.json" >"$fix/guard-paused-stopped.json"

# quota is fine (nothing constrained), but priority 2 against a top of 9 (cap 3)
# derives a cap of 1: the derived ceiling, not the provider, is what binds here
jq '.priorities={"owner/name":2,"other/proj":9}
    | .top_priority=9 | .top_cap=3
    | .constrained=false | .allowed_total=6
    | .providers.anthropic.status="ok" | .providers.anthropic.reason="ok"
    | .providers.anthropic.allowed_total=6
    | .managers["ws-w9"] += {derived_cap:1,demand_effective:1,allotment:1,
                             priority:2,paused:false}' \
  "$fix/guard-running.json" >"$fix/guard-derived.json"

# what `mgr-guard stall --pane w9:p2 <session>` prints for a paused builder: no
# provider error at all, only the guard's own ledger entry
cat >"$fix/stall-49-paused.json" <<'EOF'
{"provider":"anthropic","model":null,"error":null,"since":1788522000000,
 "retry_after_ms":null,"cause":"paused","paused_at":1788522000000,"esc_sent":1,
 "manager_id":"ws-w9"}
EOF

# the operator's pause as the guard reports it: cap 0 and demand 0 for this
# manager, allotment 0 whatever the priority says, and its only builder held
# with cause "operator-paused" (the guard's own squeeze says "paused")
jq '.paused_repos=["owner/name"]
    | .managers["ws-w9"] += {cap:0,demand:0,demand_effective:0,allotment:0,
                             active_builders:0,paused:true,paused_by_operator:true}
    | .stalled=[{pane_id:"w9:p2",name:"issue-49",workspace_id:"w9",session:"/x.jsonl",
                 provider:"anthropic",model:null,error:null,since:1788522000000,
                 retry_after_ms:null,attempts:0,last_reignite_at:null,next_reignite_at:null,
                 cause:"operator-paused",paused_at:1788522000000,esc_sent:1,
                 manager_id:"ws-w9"}]' \
  "$fix/guard-running.json" >"$fix/guard-op-paused.json"
jq '.guard="stopped" | .pid=null' \
  "$fix/guard-op-paused.json" >"$fix/guard-op-paused-stopped.json"

# and what `mgr-guard stall --pane` prints for that builder
jq '.cause="operator-paused"' \
  "$fix/stall-49-paused.json" >"$fix/stall-49-op-paused.json"

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
  "agent list") cat "$MGR_TEST_FIX/agents.json";;
  "tab list")
    printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"manager","workspace_id":"w9"},{"tab_id":"w9:t2","label":"#49 do-the-thing","workspace_id":"w9"}]}}\n';;
  "agent get")
    f="$MGR_TEST_FIX/agent-${3:-}.json"
    [ -f "$f" ] || exit 1
    cat "$f";;
  "agent wait")
    # the guard's resume, faked: MGR_TEST_ON_RESUME (if it names an executable)
    # is what the guard would have done to the builder while mgr parked on it
    case " $* " in
      *" --until working "*)
        if [ -n "${MGR_TEST_ON_RESUME:-}" ] && [ -x "$MGR_TEST_ON_RESUME" ]; then
          "$MGR_TEST_ON_RESUME"
        fi;;
    esac
    exit 0;;
  "agent prompt") exit 0;;
  *) exit 1;;
esac
EOF

cat >"$bin/mgr-guard" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'mgr-guard %s\n' "$*" >>"$MGR_TEST_LOG"
case "${1:-}" in
  status) cat "$MGR_TEST_GUARD";;
  stall)
    # MGR_TEST_RESUMED exists -> the hold is over. MGR_TEST_STALL_AFTER names a
    # marker the first check creates: the hold lands only after that check.
    if [ -n "${MGR_TEST_RESUMED:-}" ] && [ -f "$MGR_TEST_RESUMED" ]; then
      printf 'null\n'
    elif [ -n "${MGR_TEST_STALL_AFTER:-}" ] && [ ! -f "$MGR_TEST_STALL_AFTER" ]; then
      : >"$MGR_TEST_STALL_AFTER"; printf 'null\n'
    elif [ -f "$MGR_TEST_STALL" ]; then cat "$MGR_TEST_STALL"
    else printf 'null\n'; fi;;
  priority)
    shift
    if [ $# -eq 0 ]; then
      printf '{"priorities":{"owner/name":7,"other/proj":2},"default":5}\n'
    else
      r="$1"; shift
      case "${1:-}" in
        '')       jq -nc --arg r "$r" '{repo:$r,priority:7,explicit:true}';;
        --clear)  jq -nc --arg r "$r" '{repo:$r,priority:5,explicit:false}';;
        *)        jq -nc --arg r "$r" --argjson n "$1" '{repo:$r,priority:$n,explicit:true}';;
      esac
    fi;;
  pause|unpause|paused)
    # the operator pause map, faked down to one bit: MGR_TEST_PAUSED exists
    # <=> this repo is paused. `paused` only reads it, so mgr can ask freely.
    sub="$1"; r="${2:-}"; m="${MGR_TEST_PAUSED:-}"
    [ -n "$r" ] || { printf '{"error":{"code":2,"message":"usage"}}\n' >&2; exit 2; }
    case "$sub" in
      pause)   [ -n "$m" ] && : >"$m";;
      unpause) [ -n "$m" ] && rm -f "$m";;
    esac
    p=false
    if [ -n "$m" ] && [ -f "$m" ]; then p=true; fi
    jq -nc --arg r "$r" --argjson p "$p" '{repo:$r,paused:$p}';;
  register)
    printf '%s\n' "${2:-}" >>"$MGR_TEST_REGISTER"
    printf '%s\n' "${2:-}";;
  touch)
    # the per-command heartbeat: only the call itself matters here, so the
    # answer is the guard's own success shape and the log line proves the args
    jq -nc --arg id "${2:-}" '{touched:true,manager_id:$id,seen_at:1788523760000}';;
  start|stop) printf '{"running":true,"pid":4242}\n';;
  *) printf '{"error":{"code":2,"message":"usage"}}\n' >&2; exit 2;;
esac
EOF
# what the guard does while mgr parks on `--until working`: it brings the
# builder back, so every later stall check comes back empty
cat >"$bin/on-resume" <<'EOF'
#!/usr/bin/env bash
: >"$MGR_TEST_RESUMED"
EOF
chmod +x "$bin/gh" "$bin/herdr" "$bin/mgr-guard" "$bin/on-resume"

# ------------------------------------------------------------------ env

export PATH="$bin:$PATH"
export MGR_GUARD_BIN="$bin/mgr-guard"
export MGR_STATE_DIR="$tmp/state"
export MGR_TEST_FIX="$fix"
export MGR_TEST_LOG="$tmp/calls.log"
export MGR_TEST_REGISTER="$tmp/register.log"
export MGR_TEST_GUARD="$fix/guard-running.json"
export MGR_TEST_STALL="$fix/stall-49.json"
export MGR_TEST_RESUMED="$tmp/resumed"
export MGR_TEST_PAUSED="$tmp/paused"   # exists = the operator paused this repo
export MGR_TEST_ON_RESUME=            # set per case; empty = the guard does nothing
export MGR_TEST_STALL_AFTER=          # set per case; the hold lands after check #1
export HERDR_WORKSPACE_ID=w9
export HERDR_PANE_ID=w9:p1
export HERDR_TAB_ID=w9:t1
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_REGISTER"

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

# the wait/stall calls mgr made, in order — one token each
calls() {
  sed -n 's/^herdr agent wait issue-49 --until working$/park/p
          s/^herdr agent wait issue-49$/settle/p
          s/^mgr-guard stall --pane .*/stall/p' "$MGR_TEST_LOG" \
    | tr '\n' ' ' | sed 's/ *$//'
}

# the mgr-guard subcommands mgr called, in order — one token each. The
# per-command heartbeat must always be the first of them.
guard_calls() {
  sed -n 's/^mgr-guard \([a-z]*\).*/\1/p' "$MGR_TEST_LOG" | tr '\n' ' ' | sed 's/ *$//'
}

# --------------------------------------------------- 1. throttled board

printf '\n# 1. guard running, allotment 1, one in-flight builder\n'
out=$("$MGR" board --cap 3); rc=$?
check 'board exit'                0 "$rc"
check 'stdout is one json doc'    1 "$(jq -s 'length' <<<"$out")"
check 'cap'                       3 "$(jq -r '.cap' <<<"$out")"
check 'cap_effective'             1 "$(jq -r '.cap_effective' <<<"$out")"
check 'slots_free'                0 "$(jq -r '.slots_free' <<<"$out")"
check 'quota.guard'         running "$(jq -r '.quota.guard' <<<"$out")"
check 'quota.provider'    anthropic "$(jq -r '.quota.provider' <<<"$out")"
check 'quota.used'             0.62 "$(jq -r '.quota.used' <<<"$out")"
check 'quota.resets_at' 1788530000000 "$(jq -r '.quota.resets_at' <<<"$out")"
check 'quota.burn_per_hour'     0.3 "$(jq -r '.quota.burn_per_hour' <<<"$out")"
check 'quota.projected_at_reset' 1.23 "$(jq -r '.quota.projected_at_reset' <<<"$out")"
check 'quota.allowed_total'       1 "$(jq -r '.quota.allowed_total' <<<"$out")"
check 'quota.allotment'           1 "$(jq -r '.quota.allotment' <<<"$out")"
check 'quota.derived_cap'         3 "$(jq -r '.quota.derived_cap' <<<"$out")"
check 'quota.stalled'          '[49]' "$(jq -c '.quota.stalled' <<<"$out")"
check 'quota.paused_builders'    '[]' "$(jq -c '.quota.paused_builders' <<<"$out")"
check 'quota.priority'            7 "$(jq -r '.quota.priority' <<<"$out")"
check 'quota.constrained'      true "$(jq -r '.quota.constrained' <<<"$out")"
check 'quota.paused'          false "$(jq -r '.quota.paused' <<<"$out")"
check 'quota.managers' \
  '[{"manager_id":"ws-w9","repo":"owner/name","cap":3,"in_flight":1,"derived_cap":3,"allotment":1,"live":true,"pane_alive":true,"seen_at":1788523750609,"priority":7,"paused":false,"paused_by_operator":false}]' \
  "$(jq -c '.quota.managers' <<<"$out")"
# nothing exited yet: a running guard has no exit record to report
check 'quota.last_exit_at while running' null \
  "$(jq -r '.quota.last_exit_at' <<<"$out")"
check 'quota.last_exit_reason while running' null \
  "$(jq -r '.quota.last_exit_reason' <<<"$out")"
# derived 3 == cap 3: the derived ceiling does not bite, so the provider speaks
check 'quota.reason' \
  'projected 1.23 > 1 on anthropic:5h (burn 0.30/h, 2.1h to reset)' \
  "$(jq -r '.quota.reason' <<<"$out")"
check 'in_flight numbers'    '[49]' "$(jq -c '[.in_flight[].number]' <<<"$out")"
check 'in_flight quota_stalled' true "$(jq -r '.in_flight[0].quota_stalled' <<<"$out")"
check 'in_flight quota_paused' false "$(jq -r '.in_flight[0].quota_paused' <<<"$out")"
check 'heartbeat manager_id' ws-w9 "$(jq -rs 'last|.manager_id' "$MGR_TEST_REGISTER")"
check 'heartbeat demand'         2 "$(jq -rs 'last|.demand' "$MGR_TEST_REGISTER")"
check 'heartbeat counts' '1/0/1' \
  "$(jq -rs 'last|"\(.in_flight)/\(.adopting)/\(.ready)"' "$MGR_TEST_REGISTER")"
check 'heartbeat pane_id'   w9:p1 "$(jq -rs 'last|.pane_id' "$MGR_TEST_REGISTER")"
check 'heartbeat repo' owner/name "$(jq -rs 'last|.repo' "$MGR_TEST_REGISTER")"

# --------------------------------------------------- 2. launch refused

printf '\n# 2. launch #7 refused by the quota allotment\n'
err=$("$MGR" launch 7 2>&1 >/dev/null); rc=$?
check 'launch exit'               3 "$rc"
check 'launch error code'         3 "$(jq -r '.error.code' <<<"$err")"
check 'launch error message' \
  'no free slots (cap=3, cap_effective=1, quota: projected 1.23 > 1 on anthropic:5h (burn 0.30/h, 2.1h to reset))' \
  "$(jq -r '.error.message' <<<"$err")"
check 'no tab was created' 0 \
  "$(grep -c 'herdr tab create' "$MGR_TEST_LOG" || true)"

# --------------------------------------------------- 3. wait on a stalled builder

printf '\n# 3. guard stopped, builder #49 dead on a 429\n'
export MGR_TEST_GUARD="$fix/guard-stopped.json"
out=$("$MGR" wait 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'wait number'              49 "$(jq -r '.number' <<<"$out")"
check 'wait pane_id'          w9:p2 "$(jq -r '.pane_id' <<<"$out")"
check 'wait agent_status' quota-stalled "$(jq -r '.agent_status' <<<"$out")"
check 'wait report'            null "$(jq -r '.report' <<<"$out")"
check 'stall.provider'    anthropic "$(jq -r '.stall.provider' <<<"$out")"
check 'stall.model' claude-fable-5-1 "$(jq -r '.stall.model' <<<"$out")"
check 'stall.since'  1788520000000 "$(jq -r '.stall.since' <<<"$out")"
check 'stall.retry_after_ms' 976000 "$(jq -r '.stall.retry_after_ms' <<<"$out")"
check 'stall.error kept'       true \
  "$(jq -r '.stall.error | test("retry-after-ms=976000")' <<<"$out")"
check 'stall.resets_at' 1788530000000 "$(jq -r '.stall.resets_at' <<<"$out")"
check 'stall.guard'        stopped "$(jq -r '.stall.guard' <<<"$out")"
check 'stall.cause defaults to 429' 429 "$(jq -r '.stall.cause' <<<"$out")"
check 'guard asked with --pane' 1 \
  "$(grep -c "mgr-guard stall --pane w9:p2 $sess" "$MGR_TEST_LOG" || true)"
check 'no herdr agent wait when guard is down' 0 \
  "$(grep -c 'herdr agent wait' "$MGR_TEST_LOG" || true)"

# --------------------------------------------------- 4. no guard, no throttle

printf '\n# 4. guard stopped: cap_effective == cap even with a stale allotment\n'
out=$("$MGR" board --cap 3)
check 'cap_effective'             3 "$(jq -r '.cap_effective' <<<"$out")"
check 'slots_free'                2 "$(jq -r '.slots_free' <<<"$out")"
check 'quota.guard'         stopped "$(jq -r '.quota.guard' <<<"$out")"
check 'quota.allotment still shown' 1 "$(jq -r '.quota.allotment' <<<"$out")"
# a dead guard is only actionable with its exit record: this one left because
# nothing was holding it up, so starting it again is the whole answer
check 'quota.last_exit_at' 1788523800000 "$(jq -r '.quota.last_exit_at' <<<"$out")"
check 'quota.last_exit_reason' \
  'idle-exit after 1800s with no live manager and nothing held' \
  "$(jq -r '.quota.last_exit_reason' <<<"$out")"
err=$("$MGR" launch 7 2>&1 >/dev/null)
check 'launch is no longer refused for slots' false \
  "$(jq -r '(.error.message // "") | startswith("no free slots")' <<<"$err")"

# --------------------------------------------------- 5. guard subcommand + no guard binary

printf '\n# 5. mgr guard dispatch and a missing guard binary\n'
check 'guard status execs the guard' '{"running":true,"pid":4242}' \
  "$(MGR_GUARD_BIN="$bin/mgr-guard" "$MGR" guard start)"
err=$("$MGR" guard bogus 2>&1 >/dev/null); rc=$?
check 'guard usage exit'          2 "$rc"
check 'guard usage message' 'usage: mgr guard <start|stop|status>' \
  "$(jq -r '.error.message' <<<"$err")"
out=$(MGR_GUARD_BIN="$tmp/nope" "$MGR" board --cap 2)
check 'missing guard binary = stopped' stopped "$(jq -r '.quota.guard' <<<"$out")"
check 'missing guard binary = no throttle' 2 "$(jq -r '.cap_effective' <<<"$out")"
check 'usage lists guard' 1 "$("$MGR" --help | grep -c 'mgr guard <start|stop|status>')"
check 'usage lists MGR_GUARD_BIN' 1 "$("$MGR" --help | grep -c 'MGR_GUARD_BIN')"
check 'usage lists priority' 1 "$("$MGR" --help | grep -c 'mgr priority \[N|--clear\]')"

# --------------------------------------------------- 6. guard running: the wait rides it out

printf '\n# 6. guard running: the wait parks on the resume and keeps going\n'
export MGR_TEST_GUARD="$fix/guard-running.json"
export MGR_TEST_ON_RESUME="$bin/on-resume"
rm -f "$MGR_TEST_RESUMED"; : >"$MGR_TEST_LOG"
out=$("$MGR" wait 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'agent_status passthrough' blocked "$(jq -r '.agent_status' <<<"$out")"
check 'no stall key'          false "$(jq -r 'has("stall")' <<<"$out")"
check 'wait report'            null "$(jq -r '.report' <<<"$out")"
check 'parked, settled, re-checked the stall' 'stall park settle stall' "$(calls)"

printf '\n# 6b. --no-quota-block returns the hold to the caller instead\n'
export MGR_TEST_ON_RESUME=
rm -f "$MGR_TEST_RESUMED"; : >"$MGR_TEST_LOG"
out=$("$MGR" wait 49 --no-quota-block); rc=$?
check 'wait exit'                 0 "$rc"
check 'wait agent_status' quota-stalled "$(jq -r '.agent_status' <<<"$out")"
check 'stall.guard'        running "$(jq -r '.stall.guard' <<<"$out")"
check 'stall.resets_at from first limit' 1788530000000 \
  "$(jq -r '.stall.resets_at' <<<"$out")"
check 'parked once, settled once, then gave up' 'stall park settle stall' "$(calls)"

printf '\n# 6c. the hold lands after the settle: the loop parks and waits it out\n'
export MGR_TEST_ON_RESUME="$bin/on-resume"
export MGR_TEST_STALL_AFTER="$tmp/held-after"
rm -f "$MGR_TEST_RESUMED" "$MGR_TEST_STALL_AFTER"; : >"$MGR_TEST_LOG"
out=$("$MGR" wait 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'agent_status passthrough' blocked "$(jq -r '.agent_status' <<<"$out")"
check 'no stall key'          false "$(jq -r 'has("stall")' <<<"$out")"
check 'settled, was held, parked, settled again' \
  'stall settle stall park settle stall' "$(calls)"
export MGR_TEST_STALL_AFTER=

printf '\n# 6d. wait usage: exactly one target, flag on either side\n'
err=$("$MGR" wait 49 50 2>&1 >/dev/null); rc=$?
check 'two targets exit'          2 "$rc"
check 'two targets message' 'usage: mgr wait <N|pane_id> [--no-quota-block]' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" wait --no-quota-block 2>&1 >/dev/null); rc=$?
check 'no target exit'            2 "$rc"
check 'usage lists --no-quota-block' 1 \
  "$("$MGR" --help | grep -c 'mgr wait <N|pane_id> \[--no-quota-block\]')"
check 'usage lists the 60s resume cooldown' 1 \
  "$("$MGR" --help | grep -c 'MGR_GUARD_RESUME_COOLDOWN_S.*(60)')"

# --------------------------------------------------- 7. not stalled: ordinary result

printf '\n# 7. builder not stalled: the ordinary wait result\n'
export MGR_TEST_STALL="$tmp/no-stall.json"   # absent -> the guard prints null
export MGR_TEST_ON_RESUME=
rm -f "$MGR_TEST_RESUMED"
out=$("$MGR" wait 49)
check 'agent_status passthrough' blocked "$(jq -r '.agent_status' <<<"$out")"
check 'no stall key'          false "$(jq -r 'has("stall")' <<<"$out")"
check 'report'                 null "$(jq -r '.report' <<<"$out")"

# --------------------------------------------------- 8. priority forwarding

printf '\n# 8. mgr priority forwards this repo to the guard\n'
export MGR_TEST_STALL="$fix/stall-49.json"
check 'priority show' '{"repo":"owner/name","priority":7,"explicit":true}' \
  "$("$MGR" priority)"
check 'priority show forwards the repo' 1 \
  "$(grep -cx 'mgr-guard priority owner/name' "$MGR_TEST_LOG")"
check 'priority set' '{"repo":"owner/name","priority":7,"explicit":true}' \
  "$("$MGR" priority 7)"
check 'priority set forwards repo + N' 1 \
  "$(grep -cx 'mgr-guard priority owner/name 7' "$MGR_TEST_LOG")"
check 'priority 0 is allowed' '{"repo":"owner/name","priority":0,"explicit":true}' \
  "$("$MGR" priority 0)"
check 'priority clear' '{"repo":"owner/name","priority":5,"explicit":false}' \
  "$("$MGR" priority --clear)"
check 'priority clear forwards --clear' 1 \
  "$(grep -cx 'mgr-guard priority owner/name --clear' "$MGR_TEST_LOG")"
err=$("$MGR" priority bogus 2>&1 >/dev/null); rc=$?
check 'priority bad arg exit'     2 "$rc"
check 'priority bad arg message' 'priority must be a non-negative integer: bogus' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" priority 3 4 2>&1 >/dev/null); rc=$?
check 'priority too many args exit' 2 "$rc"
check 'priority usage message' 'usage: mgr priority [N|--clear]' \
  "$(jq -r '.error.message' <<<"$err")"
err=$(MGR_GUARD_BIN="$tmp/nope" "$MGR" priority 4 2>&1 >/dev/null); rc=$?
check 'priority without a guard binary exits 1' 1 "$rc"
check 'priority without a guard binary explains why' true \
  "$(jq -r '.error.message | startswith("mgr-guard is not executable")' <<<"$err")"

# --------------------------------------------------- 9. paused board

printf '\n# 9. low priority + constrained quota: this project is paused\n'
export MGR_TEST_GUARD="$fix/guard-paused.json"
out=$("$MGR" board --cap 3)
check 'cap_effective'             0 "$(jq -r '.cap_effective' <<<"$out")"
check 'slots_free'                0 "$(jq -r '.slots_free' <<<"$out")"
check 'quota.priority'            2 "$(jq -r '.quota.priority' <<<"$out")"
check 'quota.constrained'      true "$(jq -r '.quota.constrained' <<<"$out")"
check 'quota.paused'           true "$(jq -r '.quota.paused' <<<"$out")"
check 'quota.paused_builders' '[49]' "$(jq -c '.quota.paused_builders' <<<"$out")"
check 'quota.stalled drops paused entries' '[]' \
  "$(jq -c '.quota.stalled' <<<"$out")"
check 'in_flight quota_paused'  true "$(jq -r '.in_flight[0].quota_paused' <<<"$out")"
check 'in_flight quota_stalled' false "$(jq -r '.in_flight[0].quota_stalled' <<<"$out")"
check 'quota.managers[].priority' 2 "$(jq -r '.quota.managers[0].priority' <<<"$out")"
check 'quota.managers[].paused' true "$(jq -r '.quota.managers[0].paused' <<<"$out")"
check 'quota.derived_cap'         1 "$(jq -r '.quota.derived_cap' <<<"$out")"
check 'quota.managers[].derived_cap' 1 \
  "$(jq -r '.quota.managers[0].derived_cap' <<<"$out")"
# allotment 0 is tighter than the derived cap 1: the quota, not the ceiling, binds
check 'quota.reason' \
  'projected 1.23 > 1 on anthropic:5h (burn 0.30/h, 2.1h to reset)' \
  "$(jq -r '.quota.reason' <<<"$out")"

printf '\n# 9b. quota is fine but the derived cap binds: reason explains the cap\n'
export MGR_TEST_GUARD="$fix/guard-derived.json"
out=$("$MGR" board --cap 3)
check 'cap_effective'             1 "$(jq -r '.cap_effective' <<<"$out")"
check 'slots_free'                0 "$(jq -r '.slots_free' <<<"$out")"
check 'quota.constrained'     false "$(jq -r '.quota.constrained' <<<"$out")"
check 'quota.paused'          false "$(jq -r '.quota.paused' <<<"$out")"
check 'quota.allotment'           1 "$(jq -r '.quota.allotment' <<<"$out")"
check 'quota.derived_cap'         1 "$(jq -r '.quota.derived_cap' <<<"$out")"
check 'quota.managers[].derived_cap' 1 \
  "$(jq -r '.quota.managers[0].derived_cap' <<<"$out")"
check 'quota.reason' 'priority 2 vs top 9 (cap 3) → cap 1' \
  "$(jq -r '.quota.reason' <<<"$out")"
: >"$MGR_TEST_LOG"
err=$("$MGR" launch 7 2>&1 >/dev/null); rc=$?
check 'launch exit'               3 "$rc"
check 'launch error code'         3 "$(jq -r '.error.code' <<<"$err")"
check 'launch error message' \
  'no free slots (cap=3, cap_effective=1, quota: priority 2 vs top 9 (cap 3) → cap 1)' \
  "$(jq -r '.error.message' <<<"$err")"
check 'no tab was created' 0 \
  "$(grep -c 'herdr tab create' "$MGR_TEST_LOG" || true)"

printf '\n# 9c. guard stopped: the derived cap is stale, so no derived reason\n'
export MGR_TEST_GUARD="$fix/guard-paused-stopped.json"
out=$("$MGR" board --cap 3)
check 'cap_effective'             3 "$(jq -r '.cap_effective' <<<"$out")"
check 'quota.derived_cap still shown' 1 "$(jq -r '.quota.derived_cap' <<<"$out")"
check 'quota.reason is the provider reason' false \
  "$(jq -r '.quota.reason | startswith("priority ")' <<<"$out")"

# --------------------------------------------------- 10. wait on a paused builder

printf '\n# 10. wait on a builder the guard paused for a higher-priority project\n'
export MGR_TEST_STALL="$fix/stall-49-paused.json"
export MGR_TEST_GUARD="$fix/guard-paused-stopped.json"
rm -f "$MGR_TEST_RESUMED"; : >"$MGR_TEST_LOG"
out=$("$MGR" wait 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'wait number'              49 "$(jq -r '.number' <<<"$out")"
check 'wait pane_id'          w9:p2 "$(jq -r '.pane_id' <<<"$out")"
check 'wait agent_status' quota-paused "$(jq -r '.agent_status' <<<"$out")"
check 'stall.cause'         paused "$(jq -r '.stall.cause' <<<"$out")"
check 'stall.paused_at' 1788522000000 "$(jq -r '.stall.paused_at' <<<"$out")"
check 'stall.esc_sent'            1 "$(jq -r '.stall.esc_sent' <<<"$out")"
check 'stall.resets_at'  1788530000000 "$(jq -r '.stall.resets_at' <<<"$out")"
check 'stall.guard'         stopped "$(jq -r '.stall.guard' <<<"$out")"
check 'wait report'            null "$(jq -r '.report' <<<"$out")"
check 'the guard was asked about this pane' 1 \
  "$(grep -c "mgr-guard stall --pane w9:p2 $sess" "$MGR_TEST_LOG" || true)"
check 'no herdr agent wait when guard is down' 0 \
  "$(grep -c 'herdr agent wait' "$MGR_TEST_LOG" || true)"

printf '\n# 10b. guard running: a paused builder is waited out, same as a 429\n'
export MGR_TEST_GUARD="$fix/guard-paused.json"
export MGR_TEST_ON_RESUME="$bin/on-resume"
rm -f "$MGR_TEST_RESUMED"; : >"$MGR_TEST_LOG"
out=$("$MGR" wait 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'agent_status passthrough' blocked "$(jq -r '.agent_status' <<<"$out")"
check 'no stall key'          false "$(jq -r 'has("stall")' <<<"$out")"
check 'wait report'            null "$(jq -r '.report' <<<"$out")"
check 'parked, settled, re-checked the stall' 'stall park settle stall' "$(calls)"

printf '\n# 10c. --no-quota-block, flag first: the pause is returned to the caller\n'
export MGR_TEST_ON_RESUME=
rm -f "$MGR_TEST_RESUMED"; : >"$MGR_TEST_LOG"
out=$("$MGR" wait --no-quota-block 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'wait number'              49 "$(jq -r '.number' <<<"$out")"
check 'wait agent_status' quota-paused "$(jq -r '.agent_status' <<<"$out")"
check 'stall.cause'         paused "$(jq -r '.stall.cause' <<<"$out")"
check 'stall.guard'        running "$(jq -r '.stall.guard' <<<"$out")"
check 'parked once, settled once, then gave up' 'stall park settle stall' "$(calls)"

# --------------------------------------------------- 11. the operator's pause

printf '\n# 11. operator pause: an alias for cap 0\n'
export MGR_TEST_GUARD="$fix/guard-running.json"
export MGR_TEST_STALL="$fix/stall-49.json"
export MGR_TEST_ON_RESUME=
rm -f "$MGR_TEST_PAUSED"; : >"$MGR_TEST_LOG"; : >"$MGR_TEST_REGISTER"
out=$("$MGR" pause); rc=$?
check 'pause exit'                0 "$rc"
check 'pause stdout' \
  '{"repo":"owner/name","paused":true,"cap":0,"previous_cap":3}' "$out"
check 'pause forwards the repo to the guard' 1 \
  "$(grep -cx 'mgr-guard pause owner/name' "$MGR_TEST_LOG")"
# the pause is only real once the guard's ledger knows: pause re-registers
check 'pause re-registers cap 0'  0 "$(jq -rs 'last|.cap' "$MGR_TEST_REGISTER")"
check 'pause re-registers demand 0' 0 \
  "$(jq -rs 'last|.demand' "$MGR_TEST_REGISTER")"
out=$("$MGR" pause); rc=$?
check 'pause again exit'          0 "$rc"
check 'pause is idempotent' \
  '{"repo":"owner/name","paused":true,"cap":0,"previous_cap":3}' "$out"

printf '\n# 11b. while paused the board reports cap 0 and names the pause\n'
: >"$MGR_TEST_REGISTER"
out=$("$MGR" board --cap 2); rc=$?
check 'board exit'                0 "$rc"
check 'paused_by_operator'     true "$(jq -r '.paused_by_operator' <<<"$out")"
check 'cap (the pause beats --cap 2)' 0 "$(jq -r '.cap' <<<"$out")"
check 'cap_effective'             0 "$(jq -r '.cap_effective' <<<"$out")"
check 'slots_free'                0 "$(jq -r '.slots_free' <<<"$out")"
check 'config.cap keeps the configured cap' 2 "$(jq -r '.config.cap' <<<"$out")"
check 'quota.reason' 'paused by the operator (mgr unpause lifts it)' \
  "$(jq -r '.quota.reason' <<<"$out")"
# the guard's own squeeze flag is a different thing and stays as the guard left it
check 'quota.paused is the guard flag, not this one' false \
  "$(jq -r '.quota.paused' <<<"$out")"
check 'paused_by_operator sits immediately before cap' true \
  "$(jq -r '(keys_unsorted|index("paused_by_operator")) as $i
            | keys_unsorted[$i+1] == "cap"' <<<"$out")"
check 'heartbeat cap'             0 "$(jq -rs 'last|.cap' "$MGR_TEST_REGISTER")"
check 'heartbeat demand'          0 "$(jq -rs 'last|.demand' "$MGR_TEST_REGISTER")"

printf '\n# 11c. launch while paused: refused before it touches gh or herdr\n'
: >"$MGR_TEST_LOG"
err=$("$MGR" launch 7 --cap 2 2>&1 >/dev/null); rc=$?
check 'launch exit'               3 "$rc"
check 'launch error code'         3 "$(jq -r '.error.code' <<<"$err")"
check 'launch error message' \
  'this project is paused by the operator (cap 0); mgr unpause lifts it' \
  "$(jq -r '.error.message' <<<"$err")"
check 'no tab was created' 0 \
  "$(grep -c 'herdr tab create' "$MGR_TEST_LOG" || true)"

printf '\n# 11d. mgr unpause restores the cap; resume is the same command\n'
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_REGISTER"
out=$("$MGR" unpause); rc=$?
check 'unpause exit'              0 "$rc"
check 'unpause stdout' '{"repo":"owner/name","paused":false,"cap":3}' "$out"
check 'unpause forwards the repo to the guard' 1 \
  "$(grep -cx 'mgr-guard unpause owner/name' "$MGR_TEST_LOG")"
check 'unpause re-registers the restored cap' 3 \
  "$(jq -rs 'last|.cap' "$MGR_TEST_REGISTER")"
out=$("$MGR" unpause); rc=$?
check 'unpause when not paused exits 0' 0 "$rc"
check 'unpause is idempotent' '{"repo":"owner/name","paused":false,"cap":3}' "$out"
check 'resume is an alias for unpause' \
  '{"repo":"owner/name","paused":false,"cap":3}' "$("$MGR" resume)"
check 'MGR_CAP counts as the restored cap' \
  '{"repo":"owner/name","paused":false,"cap":2}' "$(MGR_CAP=2 "$MGR" unpause)"

printf '\n# 11e. a persisted cap is what pause remembers and unpause restores\n'
# subshell: a main-shell `git` lands in bash's command hash, and section 12
# later proves a restricted PATH has no git with `command -v`
( git -C "$repo" config --local mgr.cap 4 )
check 'pause remembers the persisted cap' \
  '{"repo":"owner/name","paused":true,"cap":0,"previous_cap":4}' "$("$MGR" pause)"
check 'unpause restores the persisted cap' \
  '{"repo":"owner/name","paused":false,"cap":4}' "$("$MGR" unpause)"
( git -C "$repo" config --local --unset mgr.cap ) || true
check 'the persisted cap is gone again' '' \
  "$(git -C "$repo" config --local --get mgr.cap || true)"
out=$("$MGR" board --cap 3)
check 'paused_by_operator after unpause' false \
  "$(jq -r '.paused_by_operator' <<<"$out")"
check 'cap after unpause'         3 "$(jq -r '.cap' <<<"$out")"
check 'quota.managers[].paused_by_operator without a pause' false \
  "$(jq -r '.quota.managers[0].paused_by_operator' <<<"$out")"

printf '\n# 11f. pause/unpause usage, and a missing guard binary\n'
err=$("$MGR" pause extra 2>&1 >/dev/null); rc=$?
check 'pause extra arg exit'      2 "$rc"
check 'pause usage message' 'usage: mgr pause' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" unpause extra 2>&1 >/dev/null); rc=$?
check 'unpause extra arg exit'    2 "$rc"
check 'unpause usage message' 'usage: mgr unpause' \
  "$(jq -r '.error.message' <<<"$err")"
err=$(MGR_GUARD_BIN="$tmp/nope" "$MGR" pause 2>&1 >/dev/null); rc=$?
check 'pause without a guard binary exits 1' 1 "$rc"
check 'pause without a guard binary explains why' true \
  "$(jq -r '.error.message | startswith("mgr-guard is not executable")' <<<"$err")"
check 'usage lists pause' 1 "$("$MGR" --help | grep -c '^ *mgr pause')"
check 'usage lists unpause|resume' 1 \
  "$("$MGR" --help | grep -c '^ *mgr unpause|resume')"
check 'usage no longer sells priority 0 as the pause' 0 \
  "$("$MGR" --help | grep -c '0 pauses the project' || true)"

printf '\n# 11g. the guard reports the flag per manager and marks the holds\n'
export MGR_TEST_GUARD="$fix/guard-op-paused.json"
: >"$MGR_TEST_PAUSED"
out=$("$MGR" board --cap 3)
check 'quota.managers[].paused_by_operator' true \
  "$(jq -r '.quota.managers[0].paused_by_operator' <<<"$out")"
check 'quota.managers key order' \
  '["manager_id","repo","cap","in_flight","derived_cap","allotment","live","pane_alive","seen_at","priority","paused","paused_by_operator"]' \
  "$(jq -c '.quota.managers[0]|keys_unsorted' <<<"$out")"
check 'quota.paused_builders counts operator-paused holds' '[49]' \
  "$(jq -c '.quota.paused_builders' <<<"$out")"
check 'quota.stalled stays 429-only' '[]' "$(jq -c '.quota.stalled' <<<"$out")"
check 'in_flight quota_paused'  true "$(jq -r '.in_flight[0].quota_paused' <<<"$out")"
check 'in_flight quota_stalled' false \
  "$(jq -r '.in_flight[0].quota_stalled' <<<"$out")"

printf '\n# 11h. wait on a builder the operator pause put down\n'
export MGR_TEST_GUARD="$fix/guard-op-paused-stopped.json"
export MGR_TEST_STALL="$fix/stall-49-op-paused.json"
rm -f "$MGR_TEST_RESUMED"; : >"$MGR_TEST_LOG"
out=$("$MGR" wait 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'wait number'              49 "$(jq -r '.number' <<<"$out")"
check 'wait pane_id'          w9:p2 "$(jq -r '.pane_id' <<<"$out")"
check 'wait agent_status' quota-paused "$(jq -r '.agent_status' <<<"$out")"
check 'stall.cause' operator-paused "$(jq -r '.stall.cause' <<<"$out")"
check 'stall.esc_sent'            1 "$(jq -r '.stall.esc_sent' <<<"$out")"
check 'stall.guard'         stopped "$(jq -r '.stall.guard' <<<"$out")"
check 'wait report'            null "$(jq -r '.report' <<<"$out")"

export MGR_TEST_GUARD="$fix/guard-running.json"
export MGR_TEST_STALL="$fix/stall-49.json"
rm -f "$MGR_TEST_PAUSED"; : >"$MGR_TEST_LOG"; : >"$MGR_TEST_REGISTER"

# --------------------------------------------------- 12. self-location

printf '\n# 12. self-location: paths, version, and the guard next to the real script\n'
root=$(cd "$here/.." && pwd)
check 'version matches the checkout package.json' \
  "$(jq -c '{version}' "$root/package.json")" "$("$MGR" --version)"
check 'usage lists paths' 1 "$("$MGR" --help | grep -c 'mgr paths')"
check 'usage lists --version' 1 "$("$MGR" --help | grep -c 'mgr --version')"

# the brief the builder gets must carry resolved paths, never a hardcoded
# ~/.claude/skills/manager/... (the fakes never reach `herdr agent prompt`)
check 'no hardcoded skill path in mgr' 0 "$(grep -c 'skills/manager' "$MGR" || true)"
check 'briefs use the resolved builder.md' 3 \
  "$(grep -c '^ *brief=.*\$MGR_BUILDER_MD' "$MGR" || true)"
check 'briefs use the resolved mgr' 3 \
  "$(grep -c '^ *brief=.*\$MGR_SELF' "$MGR" || true)"

# a published package reached through a node_modules/.bin symlink
pkg="$tmp/pkg"
mkdir -p "$pkg/bin" "$tmp/nm/.bin"
cp "$MGR" "$pkg/bin/mgr"
cp "$bin/mgr-guard" "$pkg/bin/mgr-guard"       # the fake guard, as shipped next to mgr
cp "$root/SKILL.md" "$root/builder.md" "$pkg/"
printf '{"version":"9.9.9"}' >"$pkg/package.json"
link="$tmp/nm/.bin/mgr"
ln -s "$pkg/bin/mgr" "$link"
real_pkg=$(readlink -f "$pkg")

out=$("$link" paths); rc=$?
check 'paths through a symlink exits 0'   0 "$rc"
check 'paths root'       "$real_pkg"            "$(jq -r '.root' <<<"$out")"
check 'paths skill_md'   "$real_pkg/SKILL.md"   "$(jq -r '.skill_md' <<<"$out")"
check 'paths builder_md' "$real_pkg/builder.md" "$(jq -r '.builder_md' <<<"$out")"
check 'paths mgr'        "$real_pkg/bin/mgr"    "$(jq -r '.mgr' <<<"$out")"
check 'version through a symlink reads the package root' '{"version":"9.9.9"}' \
  "$("$link" --version)"

# paths/version answer from the checkout alone: only jq (plus coreutils) on PATH
mini="$tmp/mini"; mkdir -p "$mini"
for c in bash jq readlink dirname; do ln -s "$(command -v "$c")" "$mini/$c"; done
check 'restricted PATH really has no gh' '' "$(PATH="$mini" command -v gh || true)"
check 'restricted PATH really has no herdr' '' "$(PATH="$mini" command -v herdr || true)"
check 'restricted PATH really has no git' '' "$(PATH="$mini" command -v git || true)"
out=$(PATH="$mini" "$link" paths); rc=$?
check 'paths without gh/herdr/git exits 0' 0 "$rc"
check 'paths without gh/herdr/git root' "$real_pkg" "$(jq -r '.root' <<<"$out")"
check 'version without gh/herdr/git' '{"version":"9.9.9"}' \
  "$(PATH="$mini" "$link" --version)"

# a checkout without package.json cannot answer --version
mkdir -p "$tmp/nopkg/bin"
cp "$MGR" "$tmp/nopkg/bin/mgr"
err=$("$tmp/nopkg/bin/mgr" --version 2>&1 >/dev/null); rc=$?
check 'version without package.json exits 1' 1 "$rc"
check 'version without package.json explains why' true \
  "$(jq -r '.error.message | startswith("package.json not found at")' <<<"$err")"

# guard_bin defaults next to the REAL script, not next to the symlink
export MGR_TEST_GUARD="$fix/guard-running.json"
check 'guard default follows the symlink' '{"running":true,"pid":4242}' \
  "$(env -u MGR_GUARD_BIN "$link" guard start)"
out=$(env -u MGR_GUARD_BIN "$link" board --cap 2)
check 'board finds the guard next to the real script' running \
  "$(jq -r '.quota.guard' <<<"$out")"

# ------------------------------------- 13. the per-command manager heartbeat

printf '\n# 13. every command stamps the manager heartbeat before it dispatches\n'
export MGR_TEST_GUARD="$fix/guard-running.json"
export MGR_TEST_STALL="$tmp/no-stall.json"   # absent -> nothing is held
export MGR_TEST_ON_RESUME=
: >"$MGR_TEST_LOG"
"$MGR" board --cap 3 >/dev/null
check 'board touches before its own guard calls' 'touch paused status register' \
  "$(guard_calls)"
check 'touch carries the manager id and the pane' 1 \
  "$(grep -cx 'mgr-guard touch ws-w9 w9:p1' "$MGR_TEST_LOG")"
# the point of the whole thing: `mgr wait` can park for the length of a quota
# window, and the heartbeat lands before it, not after
: >"$MGR_TEST_LOG"
"$MGR" wait 49 >/dev/null
check 'wait touches before it asks about the stall' touch \
  "$(guard_calls | cut -d' ' -f1)"
: >"$MGR_TEST_LOG"
"$MGR" guard status >/dev/null
check 'guard status touches before it execs the guard' 'touch status' \
  "$(guard_calls)"
: >"$MGR_TEST_LOG"
env -u HERDR_PANE_ID "$MGR" board --cap 3 >/dev/null
check 'no pane, no touch' 0 "$(grep -c 'mgr-guard touch' "$MGR_TEST_LOG" || true)"
: >"$MGR_TEST_LOG"
env -u HERDR_WORKSPACE_ID "$MGR" board --cap 3 >/dev/null
check 'no workspace, no touch' 0 \
  "$(grep -c 'mgr-guard touch' "$MGR_TEST_LOG" || true)"
export MGR_TEST_STALL="$fix/stall-49.json"


printf '\n'
if [ "$fails" -eq 0 ]; then printf 'all checks passed\n'; exit 0; fi
printf '%d check(s) failed\n' "$fails"; exit 1
