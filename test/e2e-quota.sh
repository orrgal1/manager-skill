#!/usr/bin/env bash
# End-to-end: real bin/mgr + real bin/mgr-guard, fake omp/herdr/gh.
# Scenario A: two managers, one builder dead on a 429, provider exhausted ->
# recovered; the guard throttles, then reignites; the priority-derived cap
# ceiling takes over as the binding limit once the provider recovers, and a
# paused builder only resumes once it has room again *and* the no-room cooldown
# has expired; mgr board/launch/wait reflect the guard's verdict (including
# waiting *through* a quota hold).
# Scenario B (issue #4): the live incident — a 7-day limit whose resets_at
# jitters by milliseconds, six seeded samples plus a 1% step, two managers at
# different priorities (shape 5 under lore 10, whose cap 6 leaves shape its full
# derived cap of 3). The burn is fitted over the whole window, the projection
# only constrains after MGR_GUARD_CONFIRM_TICKS ticks, no working builder is
# esc-interrupted until the provider itself goes hard, and recovery restores the
# ceiling on the same tick and resumes within the 60 s cooldown.
# Scenario C (issue #7): the operator's own pause — `mgr pause` is a cap-0
# override and nothing else: the board and `mgr launch` refuse on it, the guard's
# next tick interrupts the project's builder although the provider is healthy,
# `mgr wait` names the operator as the reason, and `mgr unpause` restores the cap
# and resumes the builder without waiting the resume cooldown out.
# Exit non-zero on any failed assertion.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
cleanup() { rm -rf "$T"; if [ -n "${GUARD_FAKE_PID:-}" ]; then kill "$GUARD_FAKE_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT
export MGR_STATE_DIR="$T/state" MGR_GUARD_NOTIFY=0 MGR_GUARD_MIN_SLOPE_SPAN_S=1
export MGR_GUARD_CONFIRM_TICKS=1   # scenario A constrains on a single over-1 tick
FAKE="$T/bin"; mkdir -p "$FAKE"
fail=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }
is()   { if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1: got '$2' want '$3'"; fi; }
ge()   { if [ "$2" -ge "$3" ]; then ok "$1 = $2 (>= $3)"; else bad "$1: got '$2' want >= $3"; fi; }
lines() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

# `mgr` treats the guard as running when guard.pid holds a live pid (kill -0), so
# the fixture pins a real process there. It must outlive the assertions in the
# block -- a short `sleep` would expire mid-block on a loaded machine and the
# guard would read as stopped -- so it is long-lived and retired explicitly.
GUARD_FAKE_PID=""
guard_alive() {
  mkdir -p "$MGR_STATE_DIR"
  guard_gone
  # the placeholder must not inherit the script's stdout: a caller piping this
  # test into `tail` would otherwise wait for the sleep to finish
  sleep 600 >/dev/null 2>&1 & GUARD_FAKE_PID=$!
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
  # a wait "--until working" is how the guard's revival is awaited; the hook file
  # lets a test make that revival actually happen (reignition, a lifted hold)
  "agent wait") printf '%s %s\n' "\$3" "\${4:-settle} \${5:-}" >>"$T/waits.log"
    if [ "\${4:-}" = --until ] && [ -x "$T/on-resume.sh" ]; then "$T/on-resume.sh" || true; fi
    exit 0;;
  "agent prompt") printf '%s\t%s\n' "\$3" "\$4" >>"$T/prompts.log"; printf '{}\n';;
  "agent send-keys") printf '%s %s\n' "\$3" "\$4" >>"$T/keys.log"; printf '{}\n';;
  "tab list") printf '{"result":{"tabs":[]}}\n';;
  "notification show") exit 0;;
  *) exit 1;;
esac
EOF
cat >"$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") case "${HERDR_WORKSPACE_ID:-}" in
      w9) printf 'acme/shape\n';;
      *)  printf 'acme/proj\n';;
    esac;;
  "issue list") case "${HERDR_WORKSPACE_ID:-}" in
      w9) printf '%s\n' '[{"number":2,"title":"Bubble layout","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":4,"title":"Canvas zoom","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":9,"title":"Survey pass","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":51,"title":"Next thing","labels":[],"body":""}]';;
      # scenario C's workspace: one in-flight builder (60) and two ready issues,
      # so the manager's demand is its whole cap of 3
      w5) printf '%s\n' '[{"number":60,"title":"Paused work","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":61,"title":"Pause me","labels":[],"body":""},{"number":62,"title":"And me","labels":[],"body":""}]';;
      *)  printf '%s\n' '[{"number":49,"title":"Add progress tracking","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":50,"title":"Wait screen","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":51,"title":"Next thing","labels":[],"body":""},{"number":52,"title":"Another","labels":[],"body":""}]';;
    esac;;
  "issue view") case "$3" in
      51) printf '%s\n' '{"number":51,"title":"Next thing","state":"OPEN","labels":[],"body":""}';;
      61) printf '%s\n' '{"number":61,"title":"Pause me","state":"OPEN","labels":[],"body":""}';;
      *) printf '';;
    esac;;
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
# the constraint itself is a projection (status ok), but the provider still counts
# as hard here: issue-49 sits on a 429 for anthropic, which is a level-2 trigger
# on its own. Nothing is interrupted anyway -- issue-50 is inside w3's allotment
# of 1, so there is no over-allotment builder to esc
is "provider hard (429 stall on anthropic)" "$(jq -r '.providers.anthropic.hard' <<<"$st")" true
is "provider status" "$(jq -r '.providers.anthropic.status' <<<"$st")" ok
is "nobody is over-allotment, so no esc" "$(lines "$T/keys.log")" 0

echo "# 7. mgr wait --no-quota-block on the stalled builder parks once, then reports the hold"
guard_alive
out=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" wait 49 --no-quota-block)
is "wait status (settled, still stalled)" "$(jq -r '.agent_status' <<<"$out")" quota-stalled
is "stall.provider" "$(jq -r '.stall.provider' <<<"$out")" anthropic
is "stall.guard" "$(jq -r '.stall.guard' <<<"$out")" running
is "waited --until working first" "$(head -1 "$T/waits.log")" "issue-49 --until working"
guard_gone

echo "# 7b. default mgr wait rides the 429 hold out until the guard reignites the builder"
cp "$SESS" "$T/sess49.bak"; : >"$T/waits.log"
# what a reignited builder looks like: the 429 turn is replaced by a clean one
printf '%s\n' '#!/usr/bin/env bash' "cp \"$SESS_OK\" \"$SESS\"" >"$T/on-resume.sh"
chmod +x "$T/on-resume.sh"
guard_alive
out=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" wait 49)
guard_gone
rm -f "$T/on-resume.sh"; cp "$T/sess49.bak" "$SESS"
is "wait returns the ordinary shape" "$(jq -r '.agent_status' <<<"$out")" blocked
is "no stall key" "$(jq -r 'has("stall")' <<<"$out")" false
is "report" "$(jq -r '.report' <<<"$out")" null
is "parked, then settled" "$(sed 's/[[:space:]]*$//' "$T/waits.log" | tr '\n' '|')" "issue-49 --until working|issue-49 settle|"

echo "# 8. guard stopped: wait returns immediately with guard=stopped; board does not throttle"
rm -f "$MGR_STATE_DIR/guard.pid"; : >"$T/waits.log"
out=$("$ROOT/bin/mgr" wait 49)
is "stall.guard" "$(jq -r '.stall.guard' <<<"$out")" stopped
is "no herdr wait issued" "$(wc -l <"$T/waits.log" | tr -d ' ')" 0
bd=$("$ROOT/bin/mgr" board --cap 3)
is "cap_effective without guard" "$(jq -r '.cap_effective' <<<"$bd")" 3
is "quota.guard" "$(jq -r '.quota.guard' <<<"$bd")" stopped

echo "# 9. priorities: this project (acme/proj, w3) is low, acme/shape (w9) is high; w3's cap is derived down to 1 and the quota constrains it to 0 -> paused"
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
# the 5h limit now reports `warning`, which is what makes the provider "hard" --
# only then does the guard esc a builder that is still working
usage_file warning 0.7 "$R2" >"$FAKE_USAGE"
st=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr-guard" tick)
is "provider hard" "$(jq -r '.providers.anthropic.hard' <<<"$st")" true
is "constrained" "$(jq -r '.constrained' <<<"$st")" true
is "allowed_total" "$(jq -r '.allowed_total' <<<"$st")" 1
is "w9 (prio 8) allotment" "$(jq -r '.managers["ws-w9"].allotment' <<<"$st")" 1
is "w3 (prio 2) allotment" "$(jq -r '.managers["ws-w3"].allotment' <<<"$st")" 0
is "top_priority" "$(jq -r '.top_priority' <<<"$st")" 8
is "top_cap" "$(jq -r '.top_cap' <<<"$st")" 3
# floor(3 * 2 / 8) = 0, lifted to the one-slot floor; w9 sets the scale and keeps its cap
is "w3 derived_cap" "$(jq -r '.managers["ws-w3"].derived_cap' <<<"$st")" 1
is "w9 derived_cap" "$(jq -r '.managers["ws-w9"].derived_cap' <<<"$st")" 3
is "w3 demand stays the registered 3" "$(jq -r '.managers["ws-w3"].demand' <<<"$st")" 3
is "w3 demand_effective" "$(jq -r '.managers["ws-w3"].demand_effective' <<<"$st")" 1
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
is "quota.derived_cap" "$(jq -r '.quota.derived_cap' <<<"$bd")" 1
# the quota bites harder than the derived cap here (allotment 0 < derived 1), so the
# board keeps reporting the provider reason
case "$(jq -r '.quota.reason' <<<"$bd")" in "projected 1.9 > 1 on anthropic:5h"*) ok "quota.reason is the provider reason";; *) bad "quota.reason: $(jq -r '.quota.reason' <<<"$bd")";; esac
is "quota.managers key order" "$(jq -c '.quota.managers[0] | keys_unsorted' <<<"$bd")" \
  '["manager_id","repo","cap","in_flight","derived_cap","allotment","live","priority","paused","paused_by_operator"]'
: >"$T/waits.log"
out=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" wait 50 --no-quota-block)
is "wait status" "$(jq -r '.agent_status' <<<"$out")" quota-paused
is "stall.cause" "$(jq -r '.stall.cause' <<<"$out")" paused
is "parked --until working first" "$(head -1 "$T/waits.log")" "issue-50 --until working"
guard_gone

echo "# 10b. default mgr wait rides the hold out until the guard lifts the pause"
cp "$MGR_STATE_DIR/state.json" "$T/state.bak"; : >"$T/waits.log"
# what the guard's resume does to its ledger: the paused entry for that pane goes
printf '%s\n' '#!/usr/bin/env bash' \
  "jq -c '.stalled |= map(select((.pane_id != \"w3:p3\") or (.cause != \"paused\")))' \"\$MGR_STATE_DIR/state.json\" >\"$T/state.new\" && mv \"$T/state.new\" \"\$MGR_STATE_DIR/state.json\"" \
  >"$T/on-resume.sh"
chmod +x "$T/on-resume.sh"
guard_alive
out=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" wait 50)
guard_gone
rm -f "$T/on-resume.sh"; cp "$T/state.bak" "$MGR_STATE_DIR/state.json"
is "wait returns the ordinary shape" "$(jq -r '.agent_status' <<<"$out")" idle
is "no stall key" "$(jq -r 'has("stall")' <<<"$out")" false
is "report" "$(jq -r '.report' <<<"$out")" null
is "parked, then settled" "$(sed 's/[[:space:]]*$//' "$T/waits.log" | tr '\n' '|')" "issue-50 --until working|issue-50 settle|"

echo "# 11. quota back: the derived cap still holds w3 to one slot, and no resume inside the 60s no_room_at cooldown"
: >"$MGR_STATE_DIR/samples.jsonl"; usage_file ok 0.1 "$R2" >"$FAKE_USAGE"
: >"$T/prompts.log"; : >"$T/keys.log"
# the cooldown is counted from the last tick w3 had no room, which is the tick of step 9
is "no_room_at ws-w3 is the constrained tick" "$(jq -r '.managers["ws-w3"].no_room_at' "$MGR_STATE_DIR/state.json")" "$NOW2"
# the 429 backoff is the guard's own bookkeeping (issue-49 was reignited at NOW1),
# so what the recovery tick may do about issue-49 is read out of the state first
nra=$(jq -r '[.stalled[] | select(.name=="issue-49") | .next_reignite_at] | first' "$MGR_STATE_DIR/state.json")
st=$(MGR_GUARD_NOW_MS=$((NOW2 + 30000)) "$ROOT/bin/mgr-guard" tick)   # 30s < 60s cooldown
is "constrained now false" "$(jq -r '.constrained' <<<"$st")" false
is "allowed_total back to the ceiling" "$(jq -r '.allowed_total' <<<"$st")" 6
is "w3 derived_cap unchanged by the quota" "$(jq -r '.managers["ws-w3"].derived_cap' <<<"$st")" 1
is "w3 demand_effective" "$(jq -r '.managers["ws-w3"].demand_effective' <<<"$st")" 1
# the provider is no longer the binding limit, but the derived cap is: 1, not the demand of 3
is "w3 allotment is the derived cap, not the demand" "$(jq -r '.managers["ws-w3"].allotment' <<<"$st")" 1
is "w9 allotment" "$(jq -r '.managers["ws-w9"].allotment' <<<"$st")" 2
p2=$(awk -F'\t' '$1=="w3:p2"' "$T/prompts.log" | wc -l | tr -d ' ')
if [ "$nra" != null ] && [ "$((NOW2 + 30000))" -ge "$nra" ]; then
  # w3's one slot is unoccupied (issue-49 stalled, issue-50 held), so the 429 entry is due
  is "429 reignite fires once its backoff is due" "$p2" 1
else
  is "429 reignite still inside its backoff" "$p2" 0
fi
is "no resume inside the cooldown" "$(awk -F'\t' '$1=="w3:p3"' "$T/prompts.log" | wc -l | tr -d ' ')" 0
is "paused entry survives the cooldown" "$(jq -r '[.stalled[] | select(.cause=="paused")] | length' <<<"$st")" 1
is "no_room_at unchanged" "$(jq -r '.managers["ws-w3"].no_room_at' <<<"$st")" "$NOW2"
is "no esc re-send once there is room" "$(lines "$T/keys.log")" 0

echo "# 12. board/launch: the derived cap, not the provider, is now the binding limit"
guard_alive
bd=$(MGR_GUARD_NOW_MS=$((NOW2 + 30000)) "$ROOT/bin/mgr" board --cap 3)
is "quota.derived_cap" "$(jq -r '.quota.derived_cap' <<<"$bd")" 1
is "quota.allotment" "$(jq -r '.quota.allotment' <<<"$bd")" 1
is "cap_effective" "$(jq -r '.cap_effective' <<<"$bd")" 1
is "quota.reason" "$(jq -r '.quota.reason' <<<"$bd")" 'priority 2 vs top 8 (cap 3) → cap 1'
set +e
err=$(MGR_GUARD_NOW_MS=$((NOW2 + 30000)) "$ROOT/bin/mgr" launch 51 --cap 3 2>&1 >/dev/null); rc=$?
set -e
is "launch exit" "$rc" 3
is "launch refusal names the derived cap" "$(jq -r '.error.message' <<<"$err")" \
  'no free slots (cap=3, cap_effective=1, quota: priority 2 vs top 8 (cap 3) → cap 1)'
guard_gone

echo "# 13. the reignited issue-49 takes the only slot, so issue-50 stays paused past the cooldown"
jq -c '(.result.agents[] | select(.name=="issue-49") | .agent_status) = "working"' "$AGENTS" >"$AGENTS.new" && mv "$AGENTS.new" "$AGENTS"
T13=$((NOW2 + 400000))
st=$(MGR_GUARD_NOW_MS=$T13 "$ROOT/bin/mgr-guard" tick)
is "issue-49 is back to work" "$(jq -r '.managers["ws-w3"].active_builders' <<<"$st")" 1
is "w3 allotment still 1" "$(jq -r '.managers["ws-w3"].allotment' <<<"$st")" 1
is "429 entry gone once it works again" "$(jq -r '[.stalled[] | select(.cause=="429")] | length' <<<"$st")" 0
is "no resume past the cooldown: no room" "$(awk -F'\t' '$1=="w3:p3"' "$T/prompts.log" | wc -l | tr -d ' ')" 0
is "paused entry survives" "$(jq -r '[.stalled[] | select(.cause=="paused")] | length' <<<"$st")" 1
is "w3 still paused" "$(jq -r '.managers["ws-w3"].paused' <<<"$st")" true
# the working builder fills w3's only slot, so this tick is a fresh no-room tick:
# the resume cooldown restarts from here
is "no_room_at ws-w3 is this tick" "$(jq -r '.managers["ws-w3"].no_room_at' <<<"$st")" "$T13"
is "no esc: the provider is ok again" "$(lines "$T/keys.log")" 0

echo "# 14. mgr priority 8 ties with acme/shape -> derived cap 3, and issue-50 resumes once step 13's cooldown expires"
"$ROOT/bin/mgr" priority 8 >/dev/null
st=$(MGR_GUARD_NOW_MS=$((T13 + 70000)) "$ROOT/bin/mgr-guard" tick)   # 70s > the 60s since the last no-room tick
is "top_priority" "$(jq -r '.top_priority' <<<"$st")" 8
is "top_cap (max cap of the tied top)" "$(jq -r '.top_cap' <<<"$st")" 3
is "w3 derived_cap" "$(jq -r '.managers["ws-w3"].derived_cap' <<<"$st")" 3
is "w3 allotment" "$(jq -r '.managers["ws-w3"].allotment' <<<"$st")" 3
resume=$(awk -F'\t' '$1=="w3:p3"{print $2}' "$T/prompts.log")
is "resume prompt sent once" "$(awk -F'\t' '$1=="w3:p3"' "$T/prompts.log" | wc -l | tr -d ' ')" 1
case "$resume" in "mgr-guard: this project's quota allotment is back (priority 8, allotment 3)."*) ok "resume text";; *) bad "resume text: $resume";; esac
# esc_sent was 1, so the resume names the interruption rather than a turn-boundary hold
case "$resume" in *"interrupted your previous turn"*) ok "resume text names the interrupt";; *) bad "resume text: $resume";; esac
is "paused entry removed" "$(jq -r '[.stalled[] | select(.cause=="paused")] | length' <<<"$st")" 0
is "resumed event" "$(jq -r '[.events[] | select(.kind=="resumed")] | length' <<<"$st")" 1
is "w3 no longer paused" "$(jq -r '.managers["ws-w3"].paused' <<<"$st")" false
is "still no esc after recovery" "$(lines "$T/keys.log")" 0

# ---------------------------------------------------------------------------
# Scenario B: the issue #4 incident, replayed end to end. Its own state dir,
# its own agents, its own clock, and the shipped defaults for the two knobs the
# incident hinged on (3 confirmations, 60 s resume cooldown).
echo "# 15. incident fixture: acme/shape (prio 5, cap 3, three working builders) vs acme/lore (prio 10, cap 6)"
export MGR_STATE_DIR="$T/state2"
export HERDR_WORKSPACE_ID=w9 HERDR_PANE_ID=w9:p1 HERDR_TAB_ID=w9:t1
mkdir -p "$MGR_STATE_DIR/managers"
: >"$MGR_STATE_DIR/samples.jsonl"; : >"$T/prompts.log"; : >"$T/keys.log"
I0=1788529271000
FRESET=$((I0 + 585000000))   # the 7d window resets in 162.5h, as in the incident
H5=$((I0 + 14400000))        # the 5h window resets in 4h
usage_fable() { # usage_fable <5h-status> <7d-used> <resets_at-jitter-ms>
  jq -nc --arg s "$1" --argjson u "$2" --argjson j "$3" --argjson h5 "$H5" --argjson fr "$FRESET" \
    '{generatedAt:0,reports:[{provider:"anthropic",fetchedAt:0,
      limits:[{id:"anthropic:5h",label:"Claude 5 Hour",status:$s,window:{resetsAt:$h5},amount:{usedFraction:0.23}},
              {id:"anthropic:7d:fable",label:"Fable Weekly",status:"ok",window:{resetsAt:($fr+$j)},
               amount:{usedFraction:$u}}]}]}'
}
fable_sample() { # fable_sample <t> <used> <resets_at-jitter-ms>
  jq -nc --argjson t "$1" --argjson u "$2" --argjson r "$((FRESET + $3))" \
    '{t:$t,provider:"anthropic",limit:"anthropic:7d:fable",used:$u,resets_at:$r,status:"ok"}'
}
# every tick of this scenario keeps the shipped confirmation/cooldown defaults
itick() { # itick <now> <5h-status> <7d-used> <resets_at-jitter-ms>
  usage_fable "$2" "$3" "$4" >"$FAKE_USAGE"
  MGR_GUARD_NOW_MS="$1" MGR_GUARD_CONFIRM_TICKS=3 MGR_GUARD_RESUME_COOLDOWN_S=60 \
    "$ROOT/bin/mgr-guard" tick
}
FQ='.providers.anthropic.limits[] | select(.id=="anthropic:7d:fable")'
# the same least-squares fit over the same in-window rows, rounded the same way:
# if the guard ever goes back to matching resets_at exactly, these diverge
fit_slope() { # fit_slope <limit-resets_at> <now>
  jq -Rnc --argjson L "$1" --argjson now "$2" '
    [inputs | (fromjson? // empty)
     | select((.provider == "anthropic") and (.limit == "anthropic:7d:fable"))
     | select((((.resets_at - $L)) | if . < 0 then (0 - .) else . end) <= 120000)
     | select(.t >= ($now - 1800000))] | sort_by(.t)
    | length as $n
    | ([.[] | .t / 3600000]) as $xs | ([.[] | .used]) as $ys
    | (($xs | add) / $n) as $mx | (($ys | add) / $n) as $my
    | ([range(0; $n) | ($xs[.] - $mx) * ($ys[.] - $my)] | add) as $sxy
    | ([$xs[] | (. - $mx) * (. - $mx)] | add) as $sxx
    | (($sxy / $sxx) * 100 | round) / 100' "$MGR_STATE_DIR/samples.jsonl"
}
# the incident's own rows: 0.22 -> 0.24 over 1045s, each with its own jittered
# resets_at. The first row's +402 is repeated by tick 1's report on purpose: that
# is the ms collision the old exact-equality filter fitted on, two points giving
# 0.07/h off a 1065 s gap instead of 0.05/h off the whole window
{ fable_sample $((I0 - 1065000)) 0.22 402
  fable_sample $((I0 - 1024000)) 0.23 -376
  fable_sample $((I0 - 963000))  0.23 338
  fable_sample $((I0 - 589000))  0.23 43
  fable_sample $((I0 - 521000))  0.24 -219
  fable_sample $((I0 - 20000))   0.24 282; } >>"$MGR_STATE_DIR/samples.jsonl"
jq -nc --arg s "$SESS_OK" '{result:{agents:[
  {name:"manager-shape",pane_id:"w9:p1",tab_id:"w9:t1",workspace_id:"w9",cwd:"/s",agent:"omp",agent_status:"idle"},
  {name:"issue-2",pane_id:"w9:p2",tab_id:"w9:t2",workspace_id:"w9",cwd:"/s-issue-2-a",agent:"omp",agent_status:"working",agent_session:{value:$s}},
  {name:"issue-4",pane_id:"w9:p3",tab_id:"w9:t3",workspace_id:"w9",cwd:"/s-issue-4-b",agent:"omp",agent_status:"working",agent_session:{value:$s}},
  {name:"issue-9",pane_id:"w9:p4",tab_id:"w9:t4",workspace_id:"w9",cwd:"/s-issue-9-c",agent:"omp",agent_status:"working",agent_session:{value:$s}},
  {name:"manager-lore",pane_id:"w7:p1",tab_id:"w7:t1",workspace_id:"w7",cwd:"/l",agent:"omp",agent_status:"idle"},
  {name:"issue-77",pane_id:"w7:p2",tab_id:"w7:t2",workspace_id:"w7",cwd:"/l-issue-77-d",agent:"omp",agent_status:"working",agent_session:{value:$s}}]}}' >"$AGENTS"
MGR_GUARD_NOW_MS=$I0 "$ROOT/bin/mgr-guard" register '{"manager_id":"ws-w9","workspace_id":"w9","pane_id":"w9:p1","repo":"acme/shape","primary":"/s","cap":3,"in_flight":3,"adopting":0,"ready":1,"demand":3}' >/dev/null
# lore's cap is 6 so that the priority-derived ceiling leaves shape its whole cap:
# floor(6 * 5 / 10) = 3. The incident's own priorities (5 vs 10) are what is under test
MGR_GUARD_NOW_MS=$I0 "$ROOT/bin/mgr-guard" register '{"manager_id":"ws-w7","workspace_id":"w7","pane_id":"w7:p1","repo":"acme/lore","primary":"/l","cap":6,"in_flight":1,"adopting":0,"ready":2,"demand":3}' >/dev/null
"$ROOT/bin/mgr-guard" priority acme/shape 5 >/dev/null
"$ROOT/bin/mgr-guard" priority acme/lore 10 >/dev/null
is "shape priority" "$(jq -r '."acme/shape"' "$MGR_STATE_DIR/priorities.json")" 5
is "lore priority" "$(jq -r '."acme/lore"' "$MGR_STATE_DIR/priorities.json")" 10

echo "# 16. tick 1: the whole jittered window is fitted, and the projection only watches"
st=$(itick $I0 ok 0.24 402)
sc=$(jq -r "$FQ | .sample_count" <<<"$st")
ge "sample_count (every in-window row)" "$sc" 7
is "not the two-point ms-collision artifact" "$(jq -n --argjson n "$sc" '$n > 2')" true
burn=$(jq -r "$FQ | .burn_per_hour" <<<"$st")
is "burn_per_hour > 0" "$(jq -n --argjson b "$burn" '$b > 0')" true
is "burn_per_hour is the least-squares slope of those rows" \
  "$burn" "$(fit_slope "$(jq -r "$FQ | .resets_at" <<<"$st")" "$I0")"
is "over_ticks" "$(jq -r "$FQ | .over_ticks" <<<"$st")" 1
is "allowed_total stays at the ceiling (3+6)" "$(jq -r '.allowed_total' <<<"$st")" 9
is "top_cap (lore's cap)" "$(jq -r '.top_cap' <<<"$st")" 6
is "shape derived_cap (floor(6 * 5 / 10))" "$(jq -r '.managers["ws-w9"].derived_cap' <<<"$st")" 3
is "shape demand_effective" "$(jq -r '.managers["ws-w9"].demand_effective' <<<"$st")" 3
is "constrained" "$(jq -r '.constrained' <<<"$st")" false
reason=$(jq -r '.providers.anthropic.reason' <<<"$st")
case "$reason" in "ok (watching: anthropic:7d:fable projected"*) ok "reason watches without acting";;
  *) bad "reason: $reason";; esac
is "provider not hard" "$(jq -r '.providers.anthropic.hard' <<<"$st")" false
is "no esc" "$(lines "$T/keys.log")" 0
is "no paused entries" "$(jq -r '[.stalled[] | select(.cause=="paused")] | length' <<<"$st")" 0
guard_alive
bd=$(MGR_GUARD_NOW_MS=$I0 "$ROOT/bin/mgr" board --cap 3)
is "cap_effective untouched" "$(jq -r '.cap_effective' <<<"$bd")" 3
is "shape allotment" "$(jq -r '.quota.allotment' <<<"$bd")" 3
set +e
err=$(MGR_GUARD_NOW_MS=$I0 "$ROOT/bin/mgr" launch 51 --cap 3 2>&1 >/dev/null); rc=$?
set -e
guard_gone
is "launch exit" "$rc" 3
# three in flight against cap 3 leaves no slot anyway -- but the refusal is the
# plain cap one, not a quota one: cap_effective is still the full cap
case "$err" in *"no free slots (cap=3)"*) ok "launch refused on the cap alone";; *) bad "launch refusal: $err";; esac
case "$err" in *"quota:"*) bad "launch refusal blames quota: $err";; *) ok "launch refusal does not blame quota";; esac

echo "# 17. tick 2: a second over-1 projection still only watches"
st=$(itick $((I0 + 20000)) ok 0.24 -376)
is "over_ticks" "$(jq -r "$FQ | .over_ticks" <<<"$st")" 2
is "allowed_total stays at the ceiling" "$(jq -r '.allowed_total' <<<"$st")" 9
is "constrained" "$(jq -r '.constrained' <<<"$st")" false
reason=$(jq -r '.providers.anthropic.reason' <<<"$st")
case "$reason" in "ok (watching: anthropic:7d:fable projected"*) ok "reason still watching";;
  *) bad "reason: $reason";; esac
is "no esc" "$(lines "$T/keys.log")" 0

echo "# 18. tick 3: the 1% step confirms the projection -> constrain, still no interrupt"
T3=$((I0 + 40000))
st=$(itick $T3 ok 0.25 338)
is "over_ticks" "$(jq -r "$FQ | .over_ticks" <<<"$st")" 3
burn=$(jq -r "$FQ | .burn_per_hour" <<<"$st")
allowed=$(jq -r '.allowed_total' <<<"$st")
want=$(jq -n --argjson a "$(jq -r '.providers.anthropic.active_builders' <<<"$st")" \
             --argjson b "$burn" --argjson u "$(jq -r "$FQ | .used" <<<"$st")" \
             --argjson r "$(jq -r "$FQ | .resets_at" <<<"$st")" --argjson now "$T3" \
  '(((($r - $now) / 3600000) * 100 | round) / 100) as $h
   | ([1, (($a * ((1 - $u) / ($b * $h))) | floor)] | max)')
is "allowed_total = max(1, floor(act*(1-used)/(burn*hours)))" "$allowed" "$want"
is "allowed_total below the ceiling" "$(jq -n --argjson a "$allowed" '$a < 9')" true
is "constrained" "$(jq -r '.constrained' <<<"$st")" true
reason=$(jq -r '.providers.anthropic.reason' <<<"$st")
case "$reason" in projected*) ok "reason acts on the projection";; *) bad "reason: $reason";; esac
ev=$(jq -c --argjson at "$T3" '[.events[] | select(.kind=="allowed_changed" and .at==$at)] | last' <<<"$st")
is "allowed_changed fit.limit" "$(jq -r '.fit.limit' <<<"$ev")" anthropic:7d:fable
is "allowed_changed fit.slope" "$(jq -r '.fit.slope' <<<"$ev")" "$burn"
ge "allowed_changed fit.samples" "$(jq -r '.fit.samples | length' <<<"$ev")" 9
is "fit samples carry t/used" "$(jq -r '.fit.samples[0] | keys | join(",")' <<<"$ev")" t,used
is "provider not hard" "$(jq -r '.providers.anthropic.hard' <<<"$st")" false
is "no esc under a projection-only constraint" "$(lines "$T/keys.log")" 0
is "no paused entries (all builders working)" "$(jq -r '[.stalled[] | select(.cause=="paused")] | length' <<<"$st")" 0
is "lore (prio 10) served before shape (prio 5)" \
  "$(jq -r '.managers["ws-w7"].allotment >= .managers["ws-w9"].allotment' <<<"$st")" true
guard_alive
bd=$(MGR_GUARD_NOW_MS=$T3 "$ROOT/bin/mgr" board --cap 3)
is "cap_effective is throttled" "$(jq -n --argjson c "$(jq -r '.cap_effective' <<<"$bd")" '$c < 3')" true
set +e
err=$(MGR_GUARD_NOW_MS=$T3 "$ROOT/bin/mgr" launch 51 --cap 3 2>&1 >/dev/null); rc=$?
set -e
guard_gone
is "launch exit" "$rc" 3
case "$err" in *"quota: projected"*) ok "launch refusal names the projection";; *) bad "launch refusal: $err";; esac

echo "# 19. tick 4: shape's highest issue goes idle and is held at its turn boundary"
jq -c '(.result.agents[] | select(.name=="issue-9") | .agent_status) = "idle"' "$AGENTS" >"$AGENTS.new" && mv "$AGENTS.new" "$AGENTS"
T4=$((I0 + 60000))
st=$(itick $T4 ok 0.25 43)
PE='[.stalled[] | select(.cause=="paused")]'
is "one paused entry" "$(jq -r "$PE | length" <<<"$st")" 1
is "held builder" "$(jq -r "$PE | first | .name" <<<"$st")" issue-9
is "held, not interrupted" "$(jq -r "$PE | first | .esc_sent" <<<"$st")" 0
is "paused event" "$(jq -r --argjson at "$T4" '[.events[] | select(.kind=="paused" and .at==$at)] | length' <<<"$st")" 1
is "still no esc" "$(lines "$T/keys.log")" 0
is "no_room_at ws-w9 is this tick" "$(jq -r '.managers["ws-w9"].no_room_at' <<<"$st")" "$T4"

echo "# 20. tick 5: the 5h limit turns warning -> level 2 escs the still-working ones"
T5=$((I0 + 80000))
st=$(itick $T5 warning 0.25 -219)
is "provider hard" "$(jq -r '.providers.anthropic.hard' <<<"$st")" true
is "esc order (highest issue first)" "$(tr '\n' '|' <"$T/keys.log")" "w9:p3 esc|w9:p2 esc|"
is "paused entries" "$(jq -r "$PE | length" <<<"$st")" 3
is "issue-4 esc_sent" "$(jq -r '[.stalled[] | select(.name=="issue-4")] | first | .esc_sent' <<<"$st")" 1
is "issue-2 esc_sent" "$(jq -r '[.stalled[] | select(.name=="issue-2")] | first | .esc_sent' <<<"$st")" 1
is "issue-9 is still a turn-boundary hold" "$(jq -r '[.stalled[] | select(.name=="issue-9")] | first | .esc_sent' <<<"$st")" 0
is "shape paused" "$(jq -r '.managers["ws-w9"].paused' <<<"$st")" true
is "lore untouched" "$(jq -r '.managers["ws-w7"].paused' <<<"$st")" false

echo "# 21. tick 6: a flat window restores the ceiling on the same tick and resumes everyone"
T6=$((T5 + 60000))
{ fable_sample $((T6 - 1000000)) 0.24 402
  fable_sample $((T6 - 800000))  0.24 -376
  fable_sample $((T6 - 600000))  0.24 338
  fable_sample $((T6 - 400000))  0.24 43
  fable_sample $((T6 - 200000))  0.24 -219
  fable_sample $((T6 - 20000))   0.24 282; } >"$MGR_STATE_DIR/samples.jsonl"
: >"$T/prompts.log"
st=$(itick $T6 ok 0.24 402)
is "burn_per_hour" "$(jq -r "$FQ | .burn_per_hour" <<<"$st")" 0
is "over_ticks" "$(jq -r "$FQ | .over_ticks" <<<"$st")" 0
is "allowed_total back to the ceiling immediately" "$(jq -r '.allowed_total' <<<"$st")" 9
is "constrained" "$(jq -r '.constrained' <<<"$st")" false
is "provider not hard" "$(jq -r '.providers.anthropic.hard' <<<"$st")" false
is "resume prompts, lowest issue first" "$(cut -f1 "$T/prompts.log" | tr '\n' '|')" "w9:p2|w9:p3|w9:p4|"
esc_text=$(awk -F'\t' '$1=="w9:p2"{print $2}' "$T/prompts.log")
case "$esc_text" in "mgr-guard: this project's quota allotment is back (priority 5, allotment 3)."*"interrupted your previous turn"*)
  ok "esc'd builder is told its turn was interrupted";; *) bad "resume text: $esc_text";; esac
held_text=$(awk -F'\t' '$1=="w9:p4"{print $2}' "$T/prompts.log")
case "$held_text" in *"held this session at the end of its previous turn"*)
  ok "held builder is told it was held at the turn boundary";; *) bad "resume text: $held_text";; esac
is "paused entries cleared" "$(jq -r "$PE | length" <<<"$st")" 0
is "resumed events" "$(jq -r --argjson at "$T6" '[.events[] | select(.kind=="resumed" and .at==$at)] | length' <<<"$st")" 3
is "shape no longer paused" "$(jq -r '.managers["ws-w9"].paused' <<<"$st")" false
is "no esc re-send after recovery" "$(lines "$T/keys.log")" 2

echo "# 22. tick 7: nothing left to do -- no keys, no holds, full cap"
T7=$((T5 + 120000))
st=$(itick $T7 ok 0.24 -376)
is "still no new esc" "$(lines "$T/keys.log")" 2
is "no paused entries" "$(jq -r "$PE | length" <<<"$st")" 0
is "no new resume prompts" "$(lines "$T/prompts.log")" 3
guard_alive
bd=$(MGR_GUARD_NOW_MS=$T7 "$ROOT/bin/mgr" board --cap 3)
guard_gone
is "cap_effective" "$(jq -r '.cap_effective' <<<"$bd")" 3
is "quota.constrained" "$(jq -r '.quota.constrained' <<<"$bd")" false

# ---------------------------------------------------------------------------
# Scenario C: the operator pause, end to end. Its own state dir, its own agents,
# its own clock (every mgr/guard call pins it, so the registration's seen_at and
# the tick agree), MGR_GUARD_NOTIFY=0 and the shipped 60 s resume cooldown.
echo "# 23. operator-pause fixture: acme/proj in w5, one working builder issue-60, quota fine"
export MGR_STATE_DIR="$T/state3"
export HERDR_WORKSPACE_ID=w5 HERDR_PANE_ID=w5:p1 HERDR_TAB_ID=w5:t1
mkdir -p "$MGR_STATE_DIR/managers"
: >"$T/prompts.log"; : >"$T/keys.log"; : >"$T/waits.log"
PC=1788544800000
usage_file ok 0.05 $((PC + 18000000)) >"$FAKE_USAGE"
jq -nc --arg s "$SESS_OK" '{result:{agents:[
  {name:"manager",pane_id:"w5:p1",tab_id:"w5:t1",workspace_id:"w5",cwd:"/p",agent:"omp",agent_status:"idle"},
  {name:"issue-60",pane_id:"w5:p2",tab_id:"w5:t2",workspace_id:"w5",cwd:"/p-issue-60-z",agent:"omp",agent_status:"working",agent_session:{value:$s}}]}}' >"$AGENTS"
bd=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" board --cap 3)
is "repo" "$(jq -r '.repo' <<<"$bd")" acme/proj
is "paused_by_operator" "$(jq -r '.paused_by_operator' <<<"$bd")" false
is "cap" "$(jq -r '.cap' <<<"$bd")" 3
is "registered cap" "$(jq -r '.cap' "$MGR_STATE_DIR/managers/ws-w5.json")" 3
is "registered demand (1 in flight + 2 ready)" "$(jq -r '.demand' "$MGR_STATE_DIR/managers/ws-w5.json")" 3

echo "# 24. mgr pause: cap 0 for this repo, and the registration follows without a board call"
out=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" pause)
is "mgr pause json" "$(jq -c . <<<"$out")" '{"repo":"acme/proj","paused":true,"cap":0,"previous_cap":3}'
is "paused.json" "$(jq -c . "$MGR_STATE_DIR/paused.json")" '{"acme/proj":true}'
is "registration cap after the pause" "$(jq -r '.cap' "$MGR_STATE_DIR/managers/ws-w5.json")" 0
is "registration demand after the pause" "$(jq -r '.demand' "$MGR_STATE_DIR/managers/ws-w5.json")" 0
out=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" pause)
is "mgr pause is idempotent (previous_cap is the configured one)" "$(jq -c . <<<"$out")" \
  '{"repo":"acme/proj","paused":true,"cap":0,"previous_cap":3}'

echo "# 25. board while paused: the pause outranks --cap 3"
bd=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" board --cap 3)
is "paused_by_operator" "$(jq -r '.paused_by_operator' <<<"$bd")" true
is "cap" "$(jq -r '.cap' <<<"$bd")" 0
is "cap_effective" "$(jq -r '.cap_effective' <<<"$bd")" 0
is "slots_free" "$(jq -r '.slots_free' <<<"$bd")" 0
is "config.cap still reports the configured cap" "$(jq -r '.config.cap' <<<"$bd")" 3
is "quota.reason" "$(jq -r '.quota.reason' <<<"$bd")" 'paused by the operator (mgr unpause lifts it)'

echo "# 26. mgr launch while paused: one sentence naming mgr unpause, --cap 3 does not lift it"
set +e
err=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" launch 61 --cap 3 2>&1 >/dev/null); rc=$?
set -e
is "launch exit" "$rc" 3
is "launch refusal" "$(jq -r '.error.message' <<<"$err")" \
  'this project is paused by the operator (cap 0); mgr unpause lifts it'

echo "# 27. the guard's tick: demand 0 -> allotment 0, and the working builder is interrupted although the provider is fine"
st=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr-guard" tick)
is "constrained" "$(jq -r '.constrained' <<<"$st")" false
is "provider status" "$(jq -r '.providers.anthropic.status' <<<"$st")" ok
is "provider not hard" "$(jq -r '.providers.anthropic.hard' <<<"$st")" false
is "ws-w5 allotment" "$(jq -r '.managers["ws-w5"].allotment' <<<"$st")" 0
is "ws-w5 paused_by_operator" "$(jq -r '.managers["ws-w5"].paused_by_operator' <<<"$st")" true
is "ws-w5 paused" "$(jq -r '.managers["ws-w5"].paused' <<<"$st")" true
is "esc sent to issue-60" "$(cat "$T/keys.log")" "w5:p2 esc"
is "held entry cause" "$(jq -r '[.stalled[] | select(.name=="issue-60")] | first | .cause' <<<"$st")" operator-paused
is "held entry esc_sent" "$(jq -r '[.stalled[] | select(.name=="issue-60")] | first | .esc_sent' <<<"$st")" 1
is "paused_repos" "$(jq -c '.paused_repos' <<<"$st")" '["acme/proj"]'
gs=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" guard status)
is "mgr guard status: managers[].paused_by_operator" "$(jq -r '.managers["ws-w5"].paused_by_operator' <<<"$gs")" true
is "mgr guard status: paused_repos" "$(jq -c '.paused_repos' <<<"$gs")" '["acme/proj"]'

echo "# 28. mgr wait and mgr board name the operator's hold"
jq -c '(.result.agents[] | select(.name=="issue-60") | .agent_status) = "idle"' "$AGENTS" >"$AGENTS.new" && mv "$AGENTS.new" "$AGENTS"
guard_alive
out=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" wait 60 --no-quota-block)
is "wait agent_status" "$(jq -r '.agent_status' <<<"$out")" quota-paused
is "wait stall.cause" "$(jq -r '.stall.cause' <<<"$out")" operator-paused
is "parked --until working first" "$(head -1 "$T/waits.log")" "issue-60 --until working"
bd=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" board --cap 3)
guard_gone
is "quota.paused" "$(jq -r '.quota.paused' <<<"$bd")" true
is "quota.paused_builders" "$(jq -c '.quota.paused_builders' <<<"$bd")" '[60]'
is "quota.stalled stays 429-only" "$(jq -c '.quota.stalled' <<<"$bd")" '[]'
is "in_flight 60 quota_paused" "$(jq -r '.in_flight[0].quota_paused' <<<"$bd")" true
is "quota.managers[].paused_by_operator" "$(jq -r '.quota.managers[0].paused_by_operator' <<<"$bd")" true

echo "# 29. mgr unpause (and its resume alias): the cap comes back, so does the registration"
out=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" unpause)
is "mgr unpause json" "$(jq -c . <<<"$out")" '{"repo":"acme/proj","paused":false,"cap":3}'
is "paused.json" "$(jq -c . "$MGR_STATE_DIR/paused.json")" '{}'
is "registration cap after the unpause" "$(jq -r '.cap' "$MGR_STATE_DIR/managers/ws-w5.json")" 3
is "registration demand after the unpause" "$(jq -r '.demand' "$MGR_STATE_DIR/managers/ws-w5.json")" 3
out=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" resume)
is "mgr resume is the same command, idempotent" "$(jq -c . <<<"$out")" '{"repo":"acme/proj","paused":false,"cap":3}'

echo "# 30. the next tick resumes the held builder on the same clock, cooldown or not"
: >"$T/prompts.log"
st=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr-guard" tick)
is "ws-w5 allotment" "$(jq -r '.managers["ws-w5"].allotment' <<<"$st")" 3
is "ws-w5 paused_by_operator" "$(jq -r '.managers["ws-w5"].paused_by_operator' <<<"$st")" false
is "paused_repos" "$(jq -c '.paused_repos' <<<"$st")" '[]'
is "one resume prompt" "$(awk -F'\t' '$1=="w5:p2"' "$T/prompts.log" | wc -l | tr -d ' ')" 1
resume=$(awk -F'\t' '$1=="w5:p2"{print $2}' "$T/prompts.log")
case "$resume" in "mgr-guard: the operator unpaused this project (priority 5, allotment 3). The quota guard interrupted your previous turn because the operator paused the project."*)
  ok "resume text names the operator's pause";; *) bad "resume text: $resume";; esac
is "held entry gone" "$(jq -r '[.stalled[] | select(.name=="issue-60")] | length' <<<"$st")" 0
is "operator_pause events" "$(jq -r '[.events[] | select(.kind=="operator_pause") | .detail] | join("|")' <<<"$st")" \
  'acme/proj: paused|acme/proj: unpaused'
is "no new esc" "$(cat "$T/keys.log")" "w5:p2 esc"

echo "# 31. board after the unpause: the full cap and the free slots are back"
bd=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" board --cap 3)
is "paused_by_operator" "$(jq -r '.paused_by_operator' <<<"$bd")" false
is "cap" "$(jq -r '.cap' <<<"$bd")" 3
is "slots_free" "$(jq -r '.slots_free' <<<"$bd")" 2
is "quota.paused" "$(jq -r '.quota.paused' <<<"$bd")" false

[ "$fail" = 0 ] && echo "e2e-quota: all assertions passed" || { echo "e2e-quota: FAILURES"; exit 1; }
