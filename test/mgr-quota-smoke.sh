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

# guard running: two provider limits with a live burn projection (the 5h one
# does not fit), one registered manager, issue-49 stalled on a 429 waiting for
# the guard to reignite it. This is state.json v2 plus the {guard,pid} wrapper
# `mgr-guard status` adds.
cat >"$fix/guard-running.json" <<'EOF'
{"version":2,"guard":"running","pid":4242,"tick_at":1788523750609,"interval_s":60,
 "builder_provider":"anthropic",
 "providers":{"anthropic":{"status":"warning","ok":true,"fetched_at":1788523750000,
   "usage_fetch_failures":0,"recovers_at":null,
   "reason":"anthropic:5h at 62% burning 0.3/h → 1.23× the window by 17:13Z",
   "limits":[{"id":"anthropic:5h","label":"Claude 5 Hour","status":"warning","used":0.62,
              "resets_at":1788530000000,"burn_per_hour":0.3,"projected_at_reset":1.23,
              "fits":false,"hours_to_reset":2.1,"sample_count":3,
              "samples":[{"t":1788516000000,"used":0.35},{"t":1788520000000,"used":0.5},
                         {"t":1788523750000,"used":0.62}]},
             {"id":"anthropic:week","label":"Claude Week","status":"ok","used":0.31,
              "resets_at":1788900000000,"burn_per_hour":0.02,"projected_at_reset":0.52,
              "fits":true,"hours_to_reset":10.5,"sample_count":3,"samples":[]}]}},
 "managers":{"ws-w9":{"manager_id":"ws-w9","workspace_id":"w9","pane_id":"w9:p1",
   "repo":"owner/name","primary":"/tmp/repo","cap":3,"in_flight":1,"adopting":0,"ready":1,
   "seen_at":1788523750609,"pane_alive":true,"live":true}},
 "stalled":[{"pane_id":"w9:p2","name":"issue-49","workspace_id":"w9","session":"/x.jsonl",
   "provider":"anthropic","model":"claude-fable-5-1","error":"429 rate_limit_error",
   "since":1788520000000,"retry_after_ms":976000,"recovers_at":null,"manager_id":"ws-w9",
   "attempts":1,"last_reignite_at":null,"next_reignite_at":1788521000000}],
 "events":[]}
EOF

# guard stopped: the same ledger, now stale and exhausted — the cap must not
# move because of it. A stopped guard also carries the exit record it wrote on
# its way out, plus the recovery time of the limit that ran out.
jq '.guard="stopped" | .pid=null
    | .providers.anthropic.status="exhausted" | .providers.anthropic.ok=false
    | .providers.anthropic.usage_fetch_failures=2
    | .providers.anthropic.recovers_at=1788531111000
    | .providers.anthropic.reason="unknown: holding last verdict (exhausted until 2026-09-04T12:11:51Z)"
    | .last_exit_at=1788523800000
    | .last_exit_reason="idle-exit after 1800s with no live manager and nothing stalled"' \
  "$fix/guard-running.json" >"$fix/guard-stopped.json"

# a guard that answers but has no reading at all: no provider, no limits
cat >"$fix/guard-blank.json" <<'EOF'
{"version":2,"guard":"running","pid":4242,"tick_at":1788523750609,"interval_s":60,
 "builder_provider":null,"providers":{},"managers":{},"stalled":[],"events":[]}
EOF

# the projection moves: the 5h limit doubles and the weekly one tips over
jq '.providers.anthropic.limits[0].projected_at_reset=2.56
    | .providers.anthropic.limits[1].projected_at_reset=1.04
    | .providers.anthropic.limits[1].fits=false' \
  "$fix/guard-running.json" >"$fix/guard-moved.json"
# and then barely moves: 0.05 is noise, not news
jq '.providers.anthropic.limits[0].projected_at_reset=2.61' \
  "$fix/guard-moved.json" >"$fix/guard-nudged.json"
# a limit the provider had not reported before
jq '.providers.anthropic.limits += [{"id":"anthropic:opus","label":"Opus Weekly",
      "status":"ok","used":0.4,"resets_at":1788900000000,"burn_per_hour":0.04,
      "projected_at_reset":0.8,"fits":true,"hours_to_reset":10.5,
      "sample_count":2,"samples":[]}]' \
  "$fix/guard-nudged.json" >"$fix/guard-newlimit.json"

cat >"$fix/stall-49.json" <<'EOF'
{"provider":"anthropic","model":"claude-fable-5-1",
 "error":"429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}} retry-after-ms=976000",
 "since":1788520000000,"retry_after_ms":976000}
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
  "tab list")
    printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"manager","workspace_id":"w9"},{"tab_id":"w9:t2","label":"#49 do-the-thing","workspace_id":"w9"}]}}\n';;
  "agent get")
    f="$MGR_TEST_FIX/agent-${3:-}.json"
    [ -f "$f" ] || exit 1
    cat "$f";;
  "agent wait")
    # the guard's reignite, faked: MGR_TEST_ON_RESUME (if it names an
    # executable) is what the guard would have done to the builder while mgr
    # parked on it
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
    # MGR_TEST_RESUMED exists -> the builder was reignited. MGR_TEST_STALL_AFTER
    # names a marker the first check creates: the 429 lands only after it.
    if [ -n "${MGR_TEST_RESUMED:-}" ] && [ -f "$MGR_TEST_RESUMED" ]; then
      printf 'null\n'
    elif [ -n "${MGR_TEST_STALL_AFTER:-}" ] && [ ! -f "$MGR_TEST_STALL_AFTER" ]; then
      : >"$MGR_TEST_STALL_AFTER"; printf 'null\n'
    elif [ -f "$MGR_TEST_STALL" ]; then cat "$MGR_TEST_STALL"
    else printf 'null\n'; fi;;
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
# what the guard does while mgr parks on `--until working`: it reignites the
# builder, so every later stall check comes back empty
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
export MGR_TEST_ON_RESUME=            # set per case; empty = the guard does nothing
export MGR_TEST_STALL_AFTER=          # set per case; the 429 lands after check #1
export HERDR_WORKSPACE_ID=w9
export HERDR_PANE_ID=w9:p1
export HERDR_TAB_ID=w9:t1
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_REGISTER"

report="$tmp/state/managers/ws-w9.last_report.json"

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
          s/^mgr-guard stall .*/stall/p' "$MGR_TEST_LOG" \
    | tr '\n' ' ' | sed 's/ *$//'
}

# the mgr-guard subcommands mgr called, in order — one token each. The
# per-command heartbeat must always be the first of them.
guard_calls() {
  sed -n 's/^mgr-guard \([a-z]*\).*/\1/p' "$MGR_TEST_LOG" | tr '\n' ' ' | sed 's/ *$//'
}

# --------------------------------------------------- 1. the board's projection

printf '\n# 1. guard running: the board carries the burn projection, nothing else\n'
out=$("$MGR" board --cap 3); rc=$?
check 'board exit'                0 "$rc"
check 'stdout is one json doc'    1 "$(jq -s 'length' <<<"$out")"
check 'cap'                       3 "$(jq -r '.cap' <<<"$out")"
# one builder in flight, nothing adopting: the cap is the only dial
check 'slots_free'                2 "$(jq -r '.slots_free' <<<"$out")"
check 'paused_by_operator'    false "$(jq -r '.paused_by_operator' <<<"$out")"
check 'quota keys' \
  '["guard","last_exit_at","last_exit_reason","provider","status","limits","reason","stalled","managers","changed","delta"]' \
  "$(jq -c '.quota|keys_unsorted' <<<"$out")"
check 'quota.guard'         running "$(jq -r '.quota.guard' <<<"$out")"
check 'quota.provider'    anthropic "$(jq -r '.quota.provider' <<<"$out")"
check 'quota.status'        warning "$(jq -r '.quota.status' <<<"$out")"
check 'quota.limits[0] keys' \
  '["id","used","burn_per_hour","projected_at_reset","resets_at","fits"]' \
  "$(jq -c '.quota.limits[0]|keys_unsorted' <<<"$out")"
check 'quota.limits' \
  '[{"id":"anthropic:5h","used":0.62,"burn_per_hour":0.3,"projected_at_reset":1.23,"resets_at":1788530000000,"fits":false},{"id":"anthropic:week","used":0.31,"burn_per_hour":0.02,"projected_at_reset":0.52,"resets_at":1788900000000,"fits":true}]' \
  "$(jq -c '.quota.limits' <<<"$out")"
check 'quota.reason is the guard sentence, verbatim' \
  'anthropic:5h at 62% burning 0.3/h → 1.23× the window by 17:13Z' \
  "$(jq -r '.quota.reason' <<<"$out")"
check 'quota.stalled'         '[49]' "$(jq -c '.quota.stalled' <<<"$out")"
check 'in_flight numbers'     '[49]' "$(jq -c '[.in_flight[].number]' <<<"$out")"
check 'in_flight quota_stalled' true "$(jq -r '.in_flight[0].quota_stalled' <<<"$out")"
check 'quota.managers' \
  '[{"manager_id":"ws-w9","repo":"owner/name","cap":3,"in_flight":1,"live":true,"pane_alive":true,"seen_at":1788523750609}]' \
  "$(jq -c '.quota.managers' <<<"$out")"
# nothing exited yet: a running guard has no exit record to report
check 'quota.last_exit_at while running' null \
  "$(jq -r '.quota.last_exit_at' <<<"$out")"
check 'quota.last_exit_reason while running' null \
  "$(jq -r '.quota.last_exit_reason' <<<"$out")"

printf '\n# 1b. every pace-dialing field is gone from the board\n'
check 'no cap_effective'      false "$(jq -r 'has("cap_effective")' <<<"$out")"
check 'no top-level quota_paused' false \
  "$(jq -r '[.in_flight[]|has("quota_paused")]|any' <<<"$out")"
check 'no quota.allotment'    false "$(jq -r '.quota|has("allotment")' <<<"$out")"
check 'no quota.derived_cap'  false "$(jq -r '.quota|has("derived_cap")' <<<"$out")"
check 'no quota.allowed_total' false "$(jq -r '.quota|has("allowed_total")' <<<"$out")"
check 'no quota.constrained'  false "$(jq -r '.quota|has("constrained")' <<<"$out")"
check 'no quota.priority'     false "$(jq -r '.quota|has("priority")' <<<"$out")"
check 'no quota.paused'       false "$(jq -r '.quota|has("paused")' <<<"$out")"
check 'no quota.paused_builders' false \
  "$(jq -r '.quota|has("paused_builders")' <<<"$out")"
check 'no single binding limit on quota' '[]' \
  "$(jq -c '[.quota|keys[]|select(IN("used","resets_at","burn_per_hour","projected_at_reset"))]' <<<"$out")"
check 'no priority/allotment per manager' '[]' \
  "$(jq -c '[.quota.managers[0]|keys[]|select(IN("priority","allotment","derived_cap","paused","paused_by_operator"))]' <<<"$out")"

printf '\n# 1c. the registration heartbeat: attribution only, no demand\n'
check 'heartbeat keys' \
  '["manager_id","workspace_id","pane_id","repo","primary","cap","in_flight","adopting","ready"]' \
  "$(jq -sc 'last|keys_unsorted' "$MGR_TEST_REGISTER")"
check 'heartbeat has no demand' false \
  "$(jq -rs 'last|has("demand")' "$MGR_TEST_REGISTER")"
check 'heartbeat manager_id' ws-w9 "$(jq -rs 'last|.manager_id' "$MGR_TEST_REGISTER")"
check 'heartbeat counts' '3/1/0/1' \
  "$(jq -rs 'last|"\(.cap)/\(.in_flight)/\(.adopting)/\(.ready)"' "$MGR_TEST_REGISTER")"
check 'heartbeat pane_id'   w9:p1 "$(jq -rs 'last|.pane_id' "$MGR_TEST_REGISTER")"
check 'heartbeat repo' owner/name "$(jq -rs 'last|.repo' "$MGR_TEST_REGISTER")"

# ------------------------------------------- 2. the cap is the only dial there is

printf '\n# 2. a bad guard state never moves the cap\n'
export MGR_TEST_GUARD="$fix/guard-stopped.json"
out=$("$MGR" board --cap 3)
check 'slots_free with a stale exhausted ledger' 2 "$(jq -r '.slots_free' <<<"$out")"
check 'quota.guard'         stopped "$(jq -r '.quota.guard' <<<"$out")"
check 'quota.status'      exhausted "$(jq -r '.quota.status' <<<"$out")"
# a dead guard is only actionable with its exit record: this one left because
# nothing was stalled, so starting it again is the whole answer
check 'quota.last_exit_at' 1788523800000 "$(jq -r '.quota.last_exit_at' <<<"$out")"
check 'quota.last_exit_reason' \
  'idle-exit after 1800s with no live manager and nothing stalled' \
  "$(jq -r '.quota.last_exit_reason' <<<"$out")"

export MGR_TEST_GUARD="$fix/guard-blank.json"
out=$("$MGR" board --cap 3)
check 'slots_free with no reading at all' 2 "$(jq -r '.slots_free' <<<"$out")"
check 'quota.provider'         null "$(jq -r '.quota.provider' <<<"$out")"
check 'quota.limits'             '[]' "$(jq -c '.quota.limits' <<<"$out")"
check 'quota.reason'           null "$(jq -r '.quota.reason' <<<"$out")"
check 'quota.stalled'            '[]' "$(jq -c '.quota.stalled' <<<"$out")"
check 'quota.managers'           '[]' "$(jq -c '.quota.managers' <<<"$out")"

out=$(MGR_GUARD_BIN="$tmp/nope" "$MGR" board --cap 2)
check 'missing guard binary = stopped' stopped "$(jq -r '.quota.guard' <<<"$out")"
check 'missing guard binary = full cap' 2 "$(jq -r '.cap' <<<"$out")"
check 'missing guard binary = slots from the cap' 1 \
  "$(jq -r '.slots_free' <<<"$out")"

printf '\n# 2b. launch refuses on the cap alone\n'
export MGR_TEST_GUARD="$fix/guard-running.json"
: >"$MGR_TEST_LOG"
err=$("$MGR" launch 7 --cap 1 2>&1 >/dev/null); rc=$?
check 'launch exit'               3 "$rc"
check 'launch error code'         3 "$(jq -r '.error.code' <<<"$err")"
check 'launch error message' 'no free slots (cap=1)' \
  "$(jq -r '.error.message' <<<"$err")"
check 'no tab was created' 0 \
  "$(grep -c 'herdr tab create' "$MGR_TEST_LOG" || true)"

# ------------------------------------------ 3. the recorded burn projection

printf '\n# 3. mgr board records the projection and reports what moved\n'
rm -rf "$tmp/state/managers"
out=$("$MGR" board --cap 3)
check 'first board: changed'   true "$(jq -r '.quota.changed' <<<"$out")"
check 'first board: delta' 'first projection' "$(jq -r '.quota.delta' <<<"$out")"
check 'the report landed for this manager' 1 "$([ -f "$report" ] && printf 1 || printf 0)"
check 'report keys' '["at","provider","limits"]' \
  "$(jq -c 'keys_unsorted' "$report")"
check 'report provider'   anthropic "$(jq -r '.provider' "$report")"
check 'report limits' \
  '[{"id":"anthropic:5h","projected_at_reset":1.23,"fits":false},{"id":"anthropic:week","projected_at_reset":0.52,"fits":true}]' \
  "$(jq -c '.limits' "$report")"
check 'report at is a ms epoch' true "$(jq -r '.at > 1700000000000' "$report")"

out=$("$MGR" board --cap 3)
check 'same projection: changed' false "$(jq -r '.quota.changed' <<<"$out")"
check 'same projection: delta'   null "$(jq -r '.quota.delta' <<<"$out")"

printf '\n# 3b. a limit that moved and a limit that tipped over\n'
export MGR_TEST_GUARD="$fix/guard-moved.json"
out=$("$MGR" board --cap 3)
check 'moved: changed'         true "$(jq -r '.quota.changed' <<<"$out")"
check 'moved: delta' \
  'anthropic:5h 1.23× → 2.56×; anthropic:week 0.52× → 1.04× (now over)' \
  "$(jq -r '.quota.delta' <<<"$out")"
check 'the report was overwritten' \
  '[{"id":"anthropic:5h","projected_at_reset":2.56,"fits":false},{"id":"anthropic:week","projected_at_reset":1.04,"fits":false}]' \
  "$(jq -c '.limits' "$report")"

printf '\n# 3c. a 0.05 move is noise, not news\n'
export MGR_TEST_GUARD="$fix/guard-nudged.json"
out=$("$MGR" board --cap 3)
check 'nudged: changed'       false "$(jq -r '.quota.changed' <<<"$out")"
check 'nudged: delta'          null "$(jq -r '.quota.delta' <<<"$out")"
check 'the nudge was still recorded' 2.61 \
  "$(jq -r '.limits[0].projected_at_reset' "$report")"

printf '\n# 3d. internal boards never record: only the operator sees the change\n'
export MGR_TEST_GUARD="$fix/guard-newlimit.json"
before=$(md5sum <"$report" 2>/dev/null || md5 -q "$report")
err=$("$MGR" launch 7 --cap 1 2>&1 >/dev/null); rc=$?
check 'launch still refused on the cap' 3 "$rc"
check 'launch left the report alone' "$before" \
  "$(md5sum <"$report" 2>/dev/null || md5 -q "$report")"
out=$("$MGR" board --cap 3)
check 'new limit: changed'     true "$(jq -r '.quota.changed' <<<"$out")"
check 'new limit: delta' 'anthropic:opus 0.8× (new)' \
  "$(jq -r '.quota.delta' <<<"$out")"
check 'the new limit is recorded too' 3 "$(jq -r '.limits|length' "$report")"

printf '\n# 3e. no workspace, no recording\n'
export MGR_TEST_GUARD="$fix/guard-moved.json"
before=$(md5sum <"$report" 2>/dev/null || md5 -q "$report")
out=$(env -u HERDR_WORKSPACE_ID "$MGR" board --cap 3)
check 'headless board: changed' false "$(jq -r '.quota.changed' <<<"$out")"
check 'headless board: delta'    null "$(jq -r '.quota.delta' <<<"$out")"
check 'headless board left the report alone' "$before" \
  "$(md5sum <"$report" 2>/dev/null || md5 -q "$report")"
export MGR_TEST_GUARD="$fix/guard-running.json"

# --------------------------------------------- 4. wait on a stalled builder

printf '\n# 4. guard stopped, builder #49 stopped on a 429: nobody will revive it\n'
export MGR_TEST_GUARD="$fix/guard-stopped.json"
: >"$MGR_TEST_LOG"
out=$("$MGR" wait 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'wait number'              49 "$(jq -r '.number' <<<"$out")"
check 'wait pane_id'          w9:p2 "$(jq -r '.pane_id' <<<"$out")"
check 'wait agent_status' quota-stalled "$(jq -r '.agent_status' <<<"$out")"
check 'wait report'            null "$(jq -r '.report' <<<"$out")"
check 'stall keys' \
  '["provider","model","error","since","retry_after_ms","resets_at","guard"]' \
  "$(jq -c '.stall|keys_unsorted' <<<"$out")"
check 'stall has no cause'    false "$(jq -r '.stall|has("cause")' <<<"$out")"
check 'stall.provider'    anthropic "$(jq -r '.stall.provider' <<<"$out")"
check 'stall.model' claude-fable-5-1 "$(jq -r '.stall.model' <<<"$out")"
check 'stall.since'   1788520000000 "$(jq -r '.stall.since' <<<"$out")"
check 'stall.retry_after_ms' 976000 "$(jq -r '.stall.retry_after_ms' <<<"$out")"
check 'stall.error kept'       true \
  "$(jq -r '.stall.error | test("retry-after-ms=976000")' <<<"$out")"
check 'stall.resets_at is the provider recovery' 1788531111000 \
  "$(jq -r '.stall.resets_at' <<<"$out")"
check 'stall.guard'         stopped "$(jq -r '.stall.guard' <<<"$out")"
check 'the guard was asked about the session file' 1 \
  "$(grep -cx "mgr-guard stall $sess" "$MGR_TEST_LOG" || true)"
check 'no herdr agent wait when the guard is down' 0 \
  "$(grep -c 'herdr agent wait' "$MGR_TEST_LOG" || true)"

printf '\n# 4b. guard running: the wait parks on the reignite and keeps going\n'
export MGR_TEST_GUARD="$fix/guard-running.json"
export MGR_TEST_ON_RESUME="$bin/on-resume"
rm -f "$MGR_TEST_RESUMED"; : >"$MGR_TEST_LOG"
out=$("$MGR" wait 49); rc=$?
check 'wait exit'                 0 "$rc"
check 'agent_status passthrough' blocked "$(jq -r '.agent_status' <<<"$out")"
check 'no stall key'          false "$(jq -r 'has("stall")' <<<"$out")"
check 'wait report'            null "$(jq -r '.report' <<<"$out")"
check 'parked, settled, re-checked the stall' 'stall park settle stall' "$(calls)"

printf '\n# 4c. --no-quota-block returns the stall to the caller instead\n'
export MGR_TEST_ON_RESUME=
rm -f "$MGR_TEST_RESUMED"; : >"$MGR_TEST_LOG"
out=$("$MGR" wait 49 --no-quota-block); rc=$?
check 'wait exit'                 0 "$rc"
check 'wait agent_status' quota-stalled "$(jq -r '.agent_status' <<<"$out")"
check 'stall.guard'        running "$(jq -r '.stall.guard' <<<"$out")"
check 'stall.resets_at from the first limit' 1788530000000 \
  "$(jq -r '.stall.resets_at' <<<"$out")"
check 'parked once, settled once, then gave up' 'stall park settle stall' "$(calls)"

printf '\n# 4d. the 429 lands after the settle: the loop parks and waits it out\n'
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

printf '\n# 4e. builder not stalled: the ordinary wait result\n'
export MGR_TEST_STALL="$tmp/no-stall.json"   # absent -> the guard prints null
export MGR_TEST_ON_RESUME=
rm -f "$MGR_TEST_RESUMED"
out=$("$MGR" wait 49)
check 'agent_status passthrough' blocked "$(jq -r '.agent_status' <<<"$out")"
check 'no stall key'          false "$(jq -r 'has("stall")' <<<"$out")"
check 'report'                 null "$(jq -r '.report' <<<"$out")"

printf '\n# 4f. wait usage: exactly one target, flag on either side\n'
export MGR_TEST_STALL="$fix/stall-49.json"
err=$("$MGR" wait 49 50 2>&1 >/dev/null); rc=$?
check 'two targets exit'          2 "$rc"
check 'two targets message' 'usage: mgr wait <N|pane_id> [--no-quota-block]' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" wait --no-quota-block 2>&1 >/dev/null); rc=$?
check 'no target exit'            2 "$rc"
check 'usage lists --no-quota-block' 1 \
  "$("$MGR" --help | grep -c 'mgr wait <N|pane_id> \[--no-quota-block\]')"

# ------------------------------------------------ 5. the operator's pause

printf '\n# 5. mgr pause: a launch gate this CLI owns, kept in .git/config\n'
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_REGISTER"
before=$(md5sum <"$report" 2>/dev/null || md5 -q "$report")
out=$("$MGR" pause); rc=$?
check 'pause exit'                0 "$rc"
check 'pause stdout' \
  '{"repo":"owner/name","paused":true,"cap":0,"previous_cap":3}' "$out"
check 'the pause is in the primary git config' true \
  "$(git -C "$repo" config --local --get mgr.paused)"
check 'the guard was never asked to pause anything' 0 \
  "$(grep -c 'mgr-guard pause\|mgr-guard unpause\|mgr-guard paused' "$MGR_TEST_LOG" || true)"
# the pause is only real once the guard's ledger knows: pause re-registers
check 'pause re-registers cap 0'  0 "$(jq -rs 'last|.cap' "$MGR_TEST_REGISTER")"
check 'the internal board did not record' "$before" \
  "$(md5sum <"$report" 2>/dev/null || md5 -q "$report")"
out=$("$MGR" pause); rc=$?
check 'pause again exit'          0 "$rc"
check 'pause is idempotent' \
  '{"repo":"owner/name","paused":true,"cap":0,"previous_cap":3}' "$out"
check 'and stores exactly one value' 1 \
  "$(git -C "$repo" config --local --get-all mgr.paused | wc -l | tr -d ' ')"
check 'paused is not a config key' 2 \
  "$("$MGR" config get paused >/dev/null 2>&1; printf '%s' "$?")"

printf '\n# 5b. while paused the board reports cap 0 and no slots\n'
: >"$MGR_TEST_REGISTER"
out=$("$MGR" board --cap 2); rc=$?
check 'board exit'                0 "$rc"
check 'paused_by_operator'     true "$(jq -r '.paused_by_operator' <<<"$out")"
check 'cap (the pause beats --cap 2)' 0 "$(jq -r '.cap' <<<"$out")"
check 'slots_free'                0 "$(jq -r '.slots_free' <<<"$out")"
check 'config.cap keeps the configured cap' 2 "$(jq -r '.config.cap' <<<"$out")"
# the pause is not a quota verdict: the projection speaks for itself
check 'quota.reason is still the guard sentence' \
  'anthropic:5h at 62% burning 0.3/h → 1.23× the window by 17:13Z' \
  "$(jq -r '.quota.reason' <<<"$out")"
check 'paused_by_operator sits immediately before cap' true \
  "$(jq -r '(keys_unsorted|index("paused_by_operator")) as $i
            | keys_unsorted[$i+1] == "cap"' <<<"$out")"
check 'heartbeat cap'             0 "$(jq -rs 'last|.cap' "$MGR_TEST_REGISTER")"

printf '\n# 5c. launch while paused: refused before it touches gh or herdr\n'
: >"$MGR_TEST_LOG"
err=$("$MGR" launch 7 --cap 2 2>&1 >/dev/null); rc=$?
check 'launch exit'               3 "$rc"
check 'launch error code'         3 "$(jq -r '.error.code' <<<"$err")"
check 'launch error message' \
  'this project is paused by the operator (cap 0); mgr unpause lifts it' \
  "$(jq -r '.error.message' <<<"$err")"
check 'no tab was created' 0 \
  "$(grep -c 'herdr tab create' "$MGR_TEST_LOG" || true)"

printf '\n# 5d. mgr unpause restores the cap; resume is the same command\n'
: >"$MGR_TEST_LOG"; : >"$MGR_TEST_REGISTER"
out=$("$MGR" unpause); rc=$?
check 'unpause exit'              0 "$rc"
check 'unpause stdout' '{"repo":"owner/name","paused":false,"cap":3}' "$out"
check 'the git config value is gone' '' \
  "$(git -C "$repo" config --local --get mgr.paused || true)"
check 'unpause re-registers the restored cap' 3 \
  "$(jq -rs 'last|.cap' "$MGR_TEST_REGISTER")"
out=$("$MGR" unpause); rc=$?
check 'unpause when not paused exits 0' 0 "$rc"
check 'unpause is idempotent' '{"repo":"owner/name","paused":false,"cap":3}' "$out"
check 'resume is an alias for unpause' \
  '{"repo":"owner/name","paused":false,"cap":3}' "$("$MGR" resume)"
check 'MGR_CAP counts as the restored cap' \
  '{"repo":"owner/name","paused":false,"cap":2}' "$(MGR_CAP=2 "$MGR" unpause)"
out=$("$MGR" board --cap 3)
check 'paused_by_operator after unpause' false \
  "$(jq -r '.paused_by_operator' <<<"$out")"
check 'cap after unpause'         3 "$(jq -r '.cap' <<<"$out")"
check 'slots_free after unpause'  2 "$(jq -r '.slots_free' <<<"$out")"

printf '\n# 5e. a persisted cap is what pause remembers and unpause restores\n'
# subshell: a main-shell `git` lands in bash's command hash, and section 7
# later proves a restricted PATH has no git with `command -v`
( git -C "$repo" config --local mgr.cap 4 )
check 'pause remembers the persisted cap' \
  '{"repo":"owner/name","paused":true,"cap":0,"previous_cap":4}' "$("$MGR" pause)"
check 'unpause restores the persisted cap' \
  '{"repo":"owner/name","paused":false,"cap":4}' "$("$MGR" unpause)"
( git -C "$repo" config --local --unset mgr.cap ) || true
check 'the persisted cap is gone again' '' \
  "$(git -C "$repo" config --local --get mgr.cap || true)"

printf '\n# 5f. pause/unpause usage, and no guard binary needed for either\n'
err=$("$MGR" pause extra 2>&1 >/dev/null); rc=$?
check 'pause extra arg exit'      2 "$rc"
check 'pause usage message' 'usage: mgr pause' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" unpause extra 2>&1 >/dev/null); rc=$?
check 'unpause extra arg exit'    2 "$rc"
check 'unpause usage message' 'usage: mgr unpause' \
  "$(jq -r '.error.message' <<<"$err")"
check 'pause works without a guard binary' \
  '{"repo":"owner/name","paused":true,"cap":0,"previous_cap":3}' \
  "$(MGR_GUARD_BIN="$tmp/nope" "$MGR" pause)"
check 'and unpause too' '{"repo":"owner/name","paused":false,"cap":3}' \
  "$(MGR_GUARD_BIN="$tmp/nope" "$MGR" unpause)"
check 'usage lists pause' 1 "$("$MGR" --help | grep -c '^ *mgr pause')"
check 'usage lists unpause|resume' 1 \
  "$("$MGR" --help | grep -c '^ *mgr unpause|resume')"

# ------------------------------------- 6. the pace dials are gone from the CLI

printf '\n# 6. mgr priority and the pace knobs no longer exist\n'
err=$("$MGR" priority 2>&1 >/dev/null); rc=$?
check 'priority exit'             2 "$rc"
check 'priority is an unknown subcommand' \
  'unknown subcommand: priority (try: mgr --help)' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" priority 7 2>&1 >/dev/null); rc=$?
check 'priority N exit'           2 "$rc"
check 'usage never mentions priority' 0 \
  "$("$MGR" --help | grep -ci 'priority' || true)"
check 'usage never mentions the resume cooldown' 0 \
  "$("$MGR" --help | grep -c 'RESUME_COOLDOWN' || true)"
check 'usage lists MGR_STATE_DIR' 1 "$("$MGR" --help | grep -c 'MGR_STATE_DIR')"
check 'usage lists MGR_GUARD_BIN' 1 "$("$MGR" --help | grep -c 'MGR_GUARD_BIN')"

printf '\n# 6b. mgr guard dispatch\n'
check 'guard start execs the guard' '{"running":true,"pid":4242}' \
  "$("$MGR" guard start)"
err=$("$MGR" guard bogus 2>&1 >/dev/null); rc=$?
check 'guard usage exit'          2 "$rc"
check 'guard usage message' 'usage: mgr guard <start|stop|status>' \
  "$(jq -r '.error.message' <<<"$err")"
check 'usage lists guard' 1 "$("$MGR" --help | grep -c 'mgr guard <start|stop|status>')"

# --------------------------------------------------- 7. self-location

printf '\n# 7. self-location: paths, version, and the guard next to the real script\n'
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
check 'guard default follows the symlink' '{"running":true,"pid":4242}' \
  "$(env -u MGR_GUARD_BIN "$link" guard start)"
out=$(env -u MGR_GUARD_BIN "$link" board --cap 2)
check 'board finds the guard next to the real script' running \
  "$(jq -r '.quota.guard' <<<"$out")"

# ------------------------------------- 8. the per-command manager heartbeat

printf '\n# 8. every command stamps the manager heartbeat before it dispatches\n'
export MGR_TEST_STALL="$tmp/no-stall.json"   # absent -> nothing is stalled
export MGR_TEST_ON_RESUME=
: >"$MGR_TEST_LOG"
"$MGR" board --cap 3 >/dev/null
check 'board touches before its own guard calls' 'touch status register' \
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

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'all checks passed\n'; exit 0; fi
printf '%d check(s) failed\n' "$fails"; exit 1
