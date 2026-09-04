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
# this repo at priority 7 while the machine as a whole is quota-constrained
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
 "priorities":{"owner/name":7,"other/proj":2},
 "managers":{"ws-w9":{"manager_id":"ws-w9","workspace_id":"w9","pane_id":"w9:p1",
   "repo":"owner/name","cap":3,"in_flight":1,"adopting":0,"ready":1,"demand":2,
   "seen_at":1788523750609,"live":true,"allotment":1,"priority":7,"paused":false,
   "active_builders":1}},
 "stalled":[{"pane_id":"w9:p2","name":"issue-49","workspace_id":"w9","session":"/x.jsonl",
   "provider":"anthropic","model":"claude-fable-5-1","error":"429 rate_limit_error",
   "since":1788520000000,"retry_after_ms":976000,"attempts":1,
   "last_reignite_at":null,"next_reignite_at":1788521000000,"cause":"429"}],
 "events":[]}
EOF

# guard stopped: same (now stale) ledger, allotment 1 — mgr must NOT throttle
jq '.guard="stopped" | .pid=null | .providers.anthropic.status="exhausted"
    | .providers.anthropic.recovers_at=1788530000000
    | .providers.anthropic.allowed_total=0 | .allowed_total=0
    | .providers.anthropic.reason="exhausted: anthropic:5h resets at 2026-09-04T12:00:00Z"' \
  "$fix/guard-running.json" >"$fix/guard-stopped.json"

cat >"$fix/stall-49.json" <<'EOF'
{"provider":"anthropic","model":"claude-fable-5-1",
 "error":"429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}} retry-after-ms=976000",
 "since":1788520000000,"retry_after_ms":976000}
EOF

# same guard, but this project is now the low-priority one: allotment 0 and its
# only builder held by the guard with cause "paused"
jq '.priorities={"owner/name":2,"other/proj":9}
    | .managers["ws-w9"] += {allotment:0,priority:2,paused:true,active_builders:0}
    | .stalled=[{pane_id:"w9:p2",name:"issue-49",workspace_id:"w9",session:"/x.jsonl",
                 provider:"anthropic",model:null,error:null,since:1788522000000,
                 retry_after_ms:null,attempts:0,last_reignite_at:null,next_reignite_at:null,
                 cause:"paused",paused_at:1788522000000,esc_sent:1,manager_id:"ws-w9"}]' \
  "$fix/guard-running.json" >"$fix/guard-paused.json"
jq '.guard="stopped" | .pid=null' "$fix/guard-paused.json" >"$fix/guard-paused-stopped.json"

# what `mgr-guard stall --pane w9:p2 <session>` prints for a paused builder: no
# provider error at all, only the guard's own ledger entry
cat >"$fix/stall-49-paused.json" <<'EOF'
{"provider":"anthropic","model":null,"error":null,"since":1788522000000,
 "retry_after_ms":null,"cause":"paused","paused_at":1788522000000,"esc_sent":1,
 "manager_id":"ws-w9"}
EOF

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
  "agent get")
    f="$MGR_TEST_FIX/agent-${3:-}.json"
    [ -f "$f" ] || exit 1
    cat "$f";;
  "agent wait")   exit 0;;
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
    if [ -f "$MGR_TEST_STALL" ]; then cat "$MGR_TEST_STALL"; else printf 'null\n'; fi;;
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
  register)
    printf '%s\n' "${2:-}" >>"$MGR_TEST_REGISTER"
    printf '%s\n' "${2:-}";;
  start|stop) printf '{"running":true,"pid":4242}\n';;
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
export MGR_TEST_REGISTER="$tmp/register.log"
export MGR_TEST_GUARD="$fix/guard-running.json"
export MGR_TEST_STALL="$fix/stall-49.json"
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
check 'quota.stalled'          '[49]' "$(jq -c '.quota.stalled' <<<"$out")"
check 'quota.paused_builders'    '[]' "$(jq -c '.quota.paused_builders' <<<"$out")"
check 'quota.priority'            7 "$(jq -r '.quota.priority' <<<"$out")"
check 'quota.constrained'      true "$(jq -r '.quota.constrained' <<<"$out")"
check 'quota.paused'          false "$(jq -r '.quota.paused' <<<"$out")"
check 'quota.managers' \
  '[{"manager_id":"ws-w9","repo":"owner/name","cap":3,"in_flight":1,"allotment":1,"live":true,"priority":7,"paused":false}]' \
  "$(jq -c '.quota.managers' <<<"$out")"
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

# --------------------------------------------------- 6. guard running: reignition wait

printf '\n# 6. guard running: wait parks on --until working, then re-checks the stall\n'
export MGR_TEST_GUARD="$fix/guard-running.json"
out=$("$MGR" wait 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'wait agent_status' quota-stalled "$(jq -r '.agent_status' <<<"$out")"
check 'stall.guard'        running "$(jq -r '.stall.guard' <<<"$out")"
check 'stall.resets_at from first limit' 1788530000000 \
  "$(jq -r '.stall.resets_at' <<<"$out")"
check 'waited for the reignition' 1 \
  "$(grep -c 'herdr agent wait issue-49 --until working' "$MGR_TEST_LOG")"
check 'then waited for the settle' 1 \
  "$(grep -cx 'herdr agent wait issue-49' "$MGR_TEST_LOG")"

# --------------------------------------------------- 7. not stalled: ordinary result

printf '\n# 7. builder not stalled: the ordinary wait result\n'
export MGR_TEST_STALL="$tmp/no-stall.json"   # absent -> the guard prints null
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

# --------------------------------------------------- 10. wait on a paused builder

printf '\n# 10. wait on a builder the guard paused for a higher-priority project\n'
export MGR_TEST_STALL="$fix/stall-49-paused.json"
export MGR_TEST_GUARD="$fix/guard-paused-stopped.json"
: >"$MGR_TEST_LOG"
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

printf '\n# 10b. guard running: a paused builder parks on the resume, same as a 429\n'
export MGR_TEST_GUARD="$fix/guard-paused.json"
: >"$MGR_TEST_LOG"
out=$("$MGR" wait 49)
check 'wait agent_status' quota-paused "$(jq -r '.agent_status' <<<"$out")"
check 'stall.guard'        running "$(jq -r '.stall.guard' <<<"$out")"
check 'parked on the resume' 1 \
  "$(grep -c 'herdr agent wait issue-49 --until working' "$MGR_TEST_LOG")"
check 'then waited for the settle' 1 \
  "$(grep -cx 'herdr agent wait issue-49' "$MGR_TEST_LOG")"


printf '\n'
if [ "$fails" -eq 0 ]; then printf 'all checks passed\n'; exit 0; fi
printf '%d check(s) failed\n' "$fails"; exit 1
