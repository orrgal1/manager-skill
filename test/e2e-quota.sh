#!/usr/bin/env bash
# End-to-end: real bin/mgr + real bin/mgr-guard, fake omp/herdr/gh.
# Scenario: two managers, one builder dead on a 429, provider exhausted ->
# recovered; the guard throttles, then reignites; mgr board/launch/wait
# reflect the guard's verdict. Exit non-zero on any failed assertion.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
cleanup() { rm -rf "$T"; if [ -n "${GUARD_FAKE_PID:-}" ]; then kill "$GUARD_FAKE_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT
export MGR_STATE_DIR="$T/state" MGR_GUARD_NOTIFY=0 MGR_GUARD_MIN_SLOPE_SPAN_S=1
FAKE="$T/bin"; mkdir -p "$FAKE"
fail=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }
is()   { if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1: got '$2' want '$3'"; fi; }

# `mgr` treats the guard as running when guard.pid holds a live pid (kill -0), so
# the fixture pins a real process there. It must outlive the assertions in the
# block -- a short `sleep` would expire mid-block on a loaded machine and the
# guard would read as stopped -- so it is long-lived and retired explicitly.
GUARD_FAKE_PID=""
guard_alive() {
  mkdir -p "$MGR_STATE_DIR"
  sleep 600 & GUARD_FAKE_PID=$!
  printf '%s\n' "$GUARD_FAKE_PID" >"$MGR_STATE_DIR/guard.pid"
}
guard_gone() {
  if [ -n "$GUARD_FAKE_PID" ]; then
    kill "$GUARD_FAKE_PID" 2>/dev/null || true
    wait "$GUARD_FAKE_PID" 2>/dev/null || true
    GUARD_FAKE_PID=""
  fi
}

# ---- fixtures
SESS="$T/issue-49.jsonl"
cat >"$SESS" <<'EOF'
{"type":"session","version":3,"id":"x","timestamp":"2026-09-04T09:55:08.214Z","cwd":"/w"}
{"type":"message","id":"a","message":{"role":"assistant","content":[],"provider":"anthropic","model":"claude-fable-5-1","stopReason":"error","errorStatus":429,"errorMessage":"429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"This request would exceed your account's rate limit. Please try again later.\"}} retry-after-ms=976000"},"timestamp":"2026-09-04T11:33:43.818Z"}
EOF
SESS_OK="$T/issue-50.jsonl"
cat >"$SESS_OK" <<'EOF'
{"type":"message","id":"b","message":{"role":"assistant","content":[],"provider":"anthropic","model":"claude-opus-5","stopReason":"stop"},"timestamp":"2026-09-04T11:40:00.000Z"}
EOF
usage_file() { # usage_file <status> <used> <resets_at>
  jq -nc --arg s "$1" --argjson u "$2" --argjson r "$3" '{generatedAt:0,reports:[{provider:"anthropic",fetchedAt:0,
    limits:[{id:"anthropic:5h",label:"Claude 5 Hour",status:$s,window:{resetsAt:$r},amount:{usedFraction:$u}},
            {id:"anthropic:7d",label:"Claude 7 Day",status:"ok",window:{resetsAt:($r+600000000)},amount:{usedFraction:0.2}}]}]}'
}
AGENTS="$T/agents.json"
jq -nc --arg s49 "$SESS" --arg s50 "$SESS_OK" '{result:{agents:[
  {name:"manager",pane_id:"w3:p1",tab_id:"w3:t1",workspace_id:"w3",cwd:"/w",agent:"omp",agent_status:"idle"},
  {name:"issue-49",pane_id:"w3:p2",tab_id:"w3:t2",workspace_id:"w3",cwd:"/w-issue-49-x",agent:"omp",agent_status:"blocked",agent_session:{value:$s49}},
  {name:"issue-50",pane_id:"w3:p3",tab_id:"w3:t3",workspace_id:"w3",cwd:"/w-issue-50-y",agent:"omp",agent_status:"working",agent_session:{value:$s50}},
  {name:"manager-shape",pane_id:"w9:p1",tab_id:"w9:t1",workspace_id:"w9",cwd:"/s",agent:"omp",agent_status:"idle"}]}}' >"$AGENTS"

cat >"$FAKE/omp" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "usage invalidate") exit 0;;
  "usage --json"|"usage --json"*) cat "\$FAKE_USAGE";;
  "config list") printf '%s\n' '{"modelRoles":{"value":{"default":"anthropic/claude-fable-5-1:high"}}}';;
  *) exit 1;;
esac
EOF
cat >"$FAKE/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent list") cat "$AGENTS";;
  "agent get") jq -c --arg t "\$3" '{result:{agent:(.result.agents[] | select(.name==\$t or .pane_id==\$t))}}' "$AGENTS";;
  "agent wait") printf '%s %s\n' "\$3" "\${4:-settle} \${5:-}" >>"$T/waits.log"; exit 0;;
  "agent prompt") printf '%s\t%s\n' "\$3" "\$4" >>"$T/prompts.log"; printf '{}\n';;
  "agent send-keys") printf '%s %s\n' "\$3" "\$4" >>"$T/keys.log"; printf '{}\n';;
  "notification show") exit 0;;
  *) exit 1;;
esac
EOF
cat >"$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") printf 'acme/proj\n';;
  "issue list") printf '%s\n' '[{"number":49,"title":"Add progress tracking","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":50,"title":"Wait screen","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":51,"title":"Next thing","labels":[],"body":""},{"number":52,"title":"Another","labels":[],"body":""}]';;
  "issue view") case "$3" in 51) printf '%s\n' '{"number":51,"title":"Next thing","state":"OPEN","labels":[],"body":""}';; *) printf '';; esac;;
  "label create"|"issue edit"|"issue comment") exit 0;;
  *) exit 1;;
esac
EOF
cat >"$FAKE/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"worktree list --porcelain"*) printf 'worktree /w\nHEAD abc\nbranch refs/heads/main\n\n';;
  *"rev-parse --show-toplevel"*) printf '/w\n';;
  *"branch --show-current"*) printf 'main\n';;
  *) exit 0;;
esac
EOF
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
export HERDR_WORKSPACE_ID=w3 HERDR_PANE_ID=w3:p1 HERDR_TAB_ID=w3:t1

NOW0=1788522000000   # 5h window resets 10 min later
RESET=$((NOW0 + 600000))

echo "# 1. exhausted: guard throttles to 0, stalled builder is NOT reignited"
export FAKE_USAGE="$T/usage.json"; usage_file exhausted 1 "$RESET" >"$FAKE_USAGE"
"$ROOT/bin/mgr-guard" register '{"manager_id":"ws-w9","workspace_id":"w9","pane_id":"w9:p1","repo":"acme/shape","primary":"/s","cap":3,"in_flight":0,"adopting":0,"ready":2,"demand":2}' >/dev/null
st=$(MGR_GUARD_NOW_MS=$NOW0 "$ROOT/bin/mgr-guard" tick)
is "providers.anthropic.status" "$(jq -r '.providers.anthropic.status' <<<"$st")" exhausted
is "allowed_total" "$(jq -r '.allowed_total' <<<"$st")" 0
is "stalled[0].name" "$(jq -r '.stalled[0].name' <<<"$st")" issue-49
is "no prompt yet" "$([ -f "$T/prompts.log" ] && wc -l <"$T/prompts.log" | tr -d ' ' || echo 0)" 0

echo "# 2. mgr board (real mgr, real guard) sees the throttle and registers itself"
# make the guard look alive: status checks guard.pid + tick freshness
guard_alive
bd=$(MGR_GUARD_NOW_MS=$NOW0 "$ROOT/bin/mgr" board --cap 3)
is "quota.guard" "$(jq -r '.quota.guard' <<<"$bd")" running
is "cap_effective" "$(jq -r '.cap_effective' <<<"$bd")" 0
is "slots_free" "$(jq -r '.slots_free' <<<"$bd")" 0
is "quota.stalled" "$(jq -c '.quota.stalled' <<<"$bd")" '[49]'
is "in_flight 49 quota_stalled" "$(jq -r '.in_flight[] | select(.number==49) | .quota_stalled' <<<"$bd")" true
is "registered ws-w3" "$(jq -r '.manager_id' "$MGR_STATE_DIR/managers/ws-w3.json")" ws-w3
is "ws-w3 demand" "$(jq -r '.demand' "$MGR_STATE_DIR/managers/ws-w3.json")" 3

echo "# 3. mgr launch is refused with the quota reason"
set +e
err=$(MGR_GUARD_NOW_MS=$NOW0 "$ROOT/bin/mgr" launch 51 --cap 3 2>&1 >/dev/null); rc=$?
set -e
is "launch exit" "$rc" 3
case "$err" in *"cap_effective=0, quota: exhausted: anthropic:5h"*) ok "launch refusal names the quota";; *) bad "launch refusal: $err";; esac
guard_gone

echo "# 4. window reset: usage ok, guard restores capacity and reignites issue-49 once"
NOW1=$((RESET + 60000))
usage_file ok 0.02 $((RESET + 18000000)) >"$FAKE_USAGE"
st=$(MGR_GUARD_NOW_MS=$NOW1 "$ROOT/bin/mgr-guard" tick)
is "status" "$(jq -r '.providers.anthropic.status' <<<"$st")" ok
is "allowed_total = ceiling (3+3)" "$(jq -r '.allowed_total' <<<"$st")" 6
is "allotment ws-w3" "$(jq -r '.managers["ws-w3"].allotment' <<<"$st")" 3
is "allotment ws-w9" "$(jq -r '.managers["ws-w9"].allotment' <<<"$st")" 2
is "reignite prompts" "$(wc -l <"$T/prompts.log" | tr -d ' ')" 1
is "prompt target" "$(cut -f1 "$T/prompts.log")" w3:p2
case "$(cut -f2 "$T/prompts.log")" in "mgr-guard: provider quota for anthropic is available again (anthropic:5h at 2%)."*) ok "reignite text";; *) bad "reignite text: $(cut -f2 "$T/prompts.log")";; esac
is "attempts" "$(jq -r '.stalled[0].attempts' <<<"$st")" 1
is "events has reignite" "$(jq -r '[.events[] | select(.kind=="reignite")] | length' <<<"$st")" 1
is "events has recovered" "$(jq -r '[.events[] | select(.kind=="recovered")] | length' <<<"$st")" 1

echo "# 5. next tick within backoff: no second prompt"
st=$(MGR_GUARD_NOW_MS=$((NOW1 + 60000)) "$ROOT/bin/mgr-guard" tick)
is "still one prompt" "$(wc -l <"$T/prompts.log" | tr -d ' ')" 1

echo "# 6. trajectory: burn projects past 1 before reset -> dial back"
NOW2=$((NOW1 + 3600000)); R2=$((NOW2 + 7200000))   # 2h to reset
: >"$MGR_STATE_DIR/samples.jsonl"
usage_file ok 0.7 "$R2" >"$FAKE_USAGE"
guard_alive
MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" board --cap 3 >/dev/null   # heartbeat after the clock jump
guard_gone
for i in 0 1 2; do
  t=$((NOW2 - 1200000 + i * 600000)); u=$(jq -n "0.5 + $i * 0.1")
  jq -nc --argjson t "$t" --argjson u "$u" --argjson r "$R2" '{t:$t,provider:"anthropic",limit:"anthropic:5h",used:$u,resets_at:$r,status:"ok"}' >>"$MGR_STATE_DIR/samples.jsonl"
done
usage_file ok 0.7 "$R2" >"$FAKE_USAGE"
st=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr-guard" tick)
# burn 0.6/h, 2h to reset -> projected 1.9 > 1; active builders = 1 (issue-50; issue-49 stalled) -> max(1, floor(1*0.3/1.2)) = 1
is "burn_per_hour" "$(jq -r '.providers.anthropic.limits[0].burn_per_hour' <<<"$st")" 0.6
is "projected_at_reset" "$(jq -r '.providers.anthropic.limits[0].projected_at_reset' <<<"$st")" 1.9
is "allowed_total" "$(jq -r '.allowed_total' <<<"$st")" 1
case "$(jq -r '.providers.anthropic.reason' <<<"$st")" in "projected 1.9 > 1 on anthropic:5h"*) ok "reason";; *) bad "reason: $(jq -r '.providers.anthropic.reason' <<<"$st")";; esac
# water-filling, 1 slot: w9 (demand 2) is served first with share floor(1/2)=0, w3 (demand 3) takes the slot
is "ws-w3 allotment" "$(jq -r '.managers["ws-w3"].allotment' <<<"$st")" 1
is "ws-w9 allotment" "$(jq -r '.managers["ws-w9"].allotment' <<<"$st")" 0

echo "# 7. mgr wait on the stalled builder with the guard running parks until working"
guard_alive
out=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" wait 49)
is "wait status (settled, still stalled)" "$(jq -r '.agent_status' <<<"$out")" quota-stalled
is "stall.provider" "$(jq -r '.stall.provider' <<<"$out")" anthropic
is "stall.guard" "$(jq -r '.stall.guard' <<<"$out")" running
is "waited --until working first" "$(head -1 "$T/waits.log")" "issue-49 --until working"
guard_gone

echo "# 8. guard stopped: wait returns immediately with guard=stopped; board does not throttle"
rm -f "$MGR_STATE_DIR/guard.pid"; : >"$T/waits.log"
out=$("$ROOT/bin/mgr" wait 49)
is "stall.guard" "$(jq -r '.stall.guard' <<<"$out")" stopped
is "no herdr wait issued" "$(wc -l <"$T/waits.log" | tr -d ' ')" 0
bd=$("$ROOT/bin/mgr" board --cap 3)
is "cap_effective without guard" "$(jq -r '.cap_effective' <<<"$bd")" 3
is "quota.guard" "$(jq -r '.quota.guard' <<<"$bd")" stopped

echo "# 9. priorities: this project (acme/proj, w3) is low, acme/shape (w9) is high; constrained -> w3 paused"
bd=$("$ROOT/bin/mgr" priority 2)
is "mgr priority sets acme/proj" "$(jq -c '[.repo,.priority]' <<<"$bd")" '["acme/proj",2]'
"$ROOT/bin/mgr-guard" priority acme/shape 8 >/dev/null
is "priorities.json" "$(jq -c . "$MGR_STATE_DIR/priorities.json")" '{"acme/proj":2,"acme/shape":8}'
# w9 gets a working builder; w3's issue-50 is working and will be the pause candidate
jq -c --arg s50 "$SESS_OK" '.result.agents += [{name:"issue-12",pane_id:"w9:p4",tab_id:"w9:t4",workspace_id:"w9",cwd:"/s-issue-12",agent:"omp",agent_status:"working",agent_session:{value:$s50}}]' "$AGENTS" >"$AGENTS.new" && mv "$AGENTS.new" "$AGENTS"
guard_alive
MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" board --cap 3 >/dev/null
guard_gone
"$ROOT/bin/mgr-guard" register '{"manager_id":"ws-w9","workspace_id":"w9","pane_id":"w9:p1","repo":"acme/shape","primary":"/s","cap":3,"in_flight":1,"adopting":0,"ready":1,"demand":2}' >/dev/null
# keep the projection binding: same rising samples, allowed_total stays 1 (active builders: issue-50 + issue-12 = 2 -> floor(2*0.25)=0 -> max 1)
st=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr-guard" tick)
is "constrained" "$(jq -r '.constrained' <<<"$st")" true
is "allowed_total" "$(jq -r '.allowed_total' <<<"$st")" 1
is "w9 (prio 8) allotment" "$(jq -r '.managers["ws-w9"].allotment' <<<"$st")" 1
is "w3 (prio 2) allotment" "$(jq -r '.managers["ws-w3"].allotment' <<<"$st")" 0
is "w3 paused" "$(jq -r '.managers["ws-w3"].paused' <<<"$st")" true
is "esc sent to issue-50" "$(cat "$T/keys.log")" "w3:p3 esc"
is "paused entry" "$(jq -r '[.stalled[] | select(.cause=="paused")] | .[0].name' <<<"$st")" issue-50
is "priority_changed events" "$(jq -r '[.events[] | select(.kind=="priority_changed")] | length' <<<"$st")" 2
is "paused event" "$(jq -r '[.events[] | select(.kind=="paused")] | length' <<<"$st")" 1

echo "# 10. board and wait in the paused project"
jq -c '(.result.agents[] | select(.name=="issue-50") | .agent_status) = "idle"' "$AGENTS" >"$AGENTS.new" && mv "$AGENTS.new" "$AGENTS"
guard_alive
bd=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" board --cap 3)
is "quota.priority" "$(jq -r '.quota.priority' <<<"$bd")" 2
is "quota.constrained" "$(jq -r '.quota.constrained' <<<"$bd")" true
is "quota.paused" "$(jq -r '.quota.paused' <<<"$bd")" true
is "quota.paused_builders" "$(jq -c '.quota.paused_builders' <<<"$bd")" '[50]'
is "quota.stalled (429 only)" "$(jq -c '.quota.stalled' <<<"$bd")" '[49]'
is "in_flight 50 quota_paused" "$(jq -r '.in_flight[] | select(.number==50) | .quota_paused' <<<"$bd")" true
is "cap_effective" "$(jq -r '.cap_effective' <<<"$bd")" 0
: >"$T/waits.log"
out=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" wait 50)
is "wait status" "$(jq -r '.agent_status' <<<"$out")" quota-paused
is "stall.cause" "$(jq -r '.stall.cause' <<<"$out")" paused
is "parked --until working first" "$(head -1 "$T/waits.log")" "issue-50 --until working"
guard_gone

echo "# 11. quota back: w3 gets room again and issue-50 is resumed after the cooldown"
: >"$MGR_STATE_DIR/samples.jsonl"; usage_file ok 0.1 "$R2" >"$FAKE_USAGE"; : >"$T/prompts.log"
st=$(MGR_GUARD_NOW_MS=$((NOW2 + 60000)) "$ROOT/bin/mgr-guard" tick)   # inside the 300s cooldown
is "constrained now false" "$(jq -r '.constrained' <<<"$st")" false
is "w3 allotment" "$(jq -r '.managers["ws-w3"].allotment' <<<"$st")" 3
# w3 has room again, so the 429-stalled issue-49 (w3:p2) is reignited now; the paused issue-50 waits out the cooldown
is "429 reignite now that w3 has room" "$(cut -f1 "$T/prompts.log")" w3:p2
is "no resume inside cooldown" "$(cut -f1 "$T/prompts.log" | { grep -c 'w3:p3' || true; })" 0
st=$(MGR_GUARD_NOW_MS=$((NOW2 + 400000)) "$ROOT/bin/mgr-guard" tick)
resume=$(awk -F'\t' '$1=="w3:p3"{print $2}' "$T/prompts.log")
is "resume prompt sent once" "$(awk -F'\t' '$1=="w3:p3"' "$T/prompts.log" | wc -l | tr -d ' ')" 1
case "$resume" in "mgr-guard: this project's quota allotment is back (priority 2, allotment 3)."*) ok "resume text";; *) bad "resume text: $resume";; esac
is "paused entry removed" "$(jq -r '[.stalled[] | select(.cause=="paused")] | length' <<<"$st")" 0
is "resumed event" "$(jq -r '[.events[] | select(.kind=="resumed")] | length' <<<"$st")" 1
is "w3 no longer paused" "$(jq -r '.managers["ws-w3"].paused' <<<"$st")" false

[ "$fail" = 0 ] && echo "e2e-quota: all assertions passed" || { echo "e2e-quota: FAILURES"; exit 1; }
