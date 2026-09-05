#!/usr/bin/env bash
# End-to-end: real bin/mgr + real bin/mgr-guard, fake omp/herdr/gh/git.
# The guard has exactly two jobs here: reignite a 429-stalled pane once the quota
# renews, and keep a burn projection the board surfaces. Nothing throttles.
# Scenario A: an exhausted window with a stalled builder (issue-49) and a working
# one (issue-50), two registered managers. The tick names the exhausted limit and
# the pane holding a 429 but prompts nobody; `mgr board` reports the guard, the
# cap alone (no cap_effective), the stall, the projection and its delta, and files
# the projection beside the registration; `mgr launch` refuses on the cap alone
# and its internal board leaves that file alone.
# Scenario B (issue #13): a failed usage fetch inside an exhausted window holds
# the last verdict and prompts nobody; the reset with a positive reading reignites
# the pane exactly once, naming the limit whose window closed; and a second
# mini-flow reignites off `recovers_at` alone when the fetch never comes back.
# Scenario C: the burn fit over a whole window — 0.6/h with 2 h to reset at 70%
# projects 1.9x, which is the board's `quota.reason`, `quota.changed` and delta.
# Scenario D: `mgr wait` on a quota hold — quota-stalled with the guard running
# (after one `--until working` park), waited *through* by default, and answered
# immediately when the guard is stopped.
# Scenario E (issue #7): the operator's pause is a launch gate `mgr` owns alone —
# cap 0 on the board, `mgr launch` refused, the registration follows, the guard
# neither prompts nor interrupts the running builder, `mgr unpause` restores it,
# and `mgr priority` is gone.
# Exit non-zero on any failed assertion.
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
ge()   { if [ "$2" -ge "$3" ]; then ok "$1 = $2 (>= $3)"; else bad "$1: got '$2' want >= $3"; fi; }
lines() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }
mt()   { if stat --version >/dev/null 2>&1; then stat -c %Y "$1"; else stat -f %m "$1"; fi; }
iso()  { jq -nr --argjson m "$1" '($m / 1000 | floor | todate)'; }
hhmm() { jq -nr --argjson m "$1" '($m / 1000 | floor | todate)[11:16] + "Z"'; }

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
usage_file() { # usage_file <5h-status> <5h-used> <resets_at>
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

# `omp usage` fails while $T/usage.fail exists: that is the #13 regression fixture
cat >"$FAKE/omp" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "usage invalidate") exit 0;;
  "usage --json"|"usage --json"*) [ -f "$T/usage.fail" ] && exit 1; cat "\$FAKE_USAGE";;
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
  # lets a test make that revival actually happen (a reignited session)
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
      w9) printf '%s\n' '[{"number":2,"title":"Bubble layout","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":51,"title":"Next thing","labels":[],"body":""}]';;
      # scenario E's workspace: one in-flight builder (60) and two ready issues
      w5) printf '%s\n' '[{"number":60,"title":"Paused work","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":61,"title":"Pause me","labels":[],"body":""},{"number":62,"title":"And me","labels":[],"body":""}]';;
      *)  printf '%s\n' '[{"number":49,"title":"Add progress tracking","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":50,"title":"Wait screen","labels":[{"name":"mgr:in-flight"}],"body":""},{"number":51,"title":"Next thing","labels":[],"body":""},{"number":52,"title":"Another","labels":[],"body":""}]';;
    esac;;
  # every launchable issue carries exactly one size: label — `mgr launch` refuses
  # without one, and these scenarios are about the cap and the pause
  "issue view") case "$3" in
      51) printf '%s\n' '{"number":51,"title":"Next thing","state":"OPEN","labels":[{"name":"size:small"}],"body":""}';;
      61) printf '%s\n' '{"number":61,"title":"Pause me","state":"OPEN","labels":[{"name":"size:medium"}],"body":""}';;
      *) printf '';;
    esac;;
  "label create"|"issue edit"|"issue comment") exit 0;;
  *) exit 1;;
esac
EOF
# The operator's pause is the only mgr state that lives in git: the primary's
# .git/config under mgr.paused. `cfg_get_all` reads it with
# `git -C <primary> config --local --get-all mgr.<key>`, which exits 1 on an
# unset key, so the store is one file per key under $T.
cat >"$FAKE/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"worktree list --porcelain"*) printf 'worktree /w\nHEAD abc\nbranch refs/heads/main\n\n'; exit 0;;
  *"rev-parse --show-toplevel"*) printf '/w\n'; exit 0;;
  *"branch --show-current"*) printf 'main\n'; exit 0;;
esac
op=""; key=""; val=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --get-all|--get)     op=get;   key="\${2:-}"; shift; shift;;
    --replace-all|--add) op=set;   key="\${2:-}"; val="\${3:-}"; shift; shift;;
    --unset-all|--unset) op=unset; key="\${2:-}"; shift; shift;;
    *) shift;;
  esac
done
f="$T/gitcfg.\$key"
case "\$op" in
  get)   [ -f "\$f" ] || exit 1; cat "\$f";;
  set)   printf '%s\n' "\$val" >"\$f";;
  unset) rm -f "\$f";;
esac
exit 0
EOF
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
export HERDR_WORKSPACE_ID=w3 HERDR_PANE_ID=w3:p1 HERDR_TAB_ID=w3:t1
# every launch needs a model house for its package overlay; these scenarios are
# about the cap and the pause, so it is fixed here rather than per case
export MGR_HOUSE=anthropic

NOW0=1788522000000   # 5h window resets 10 min later
RESET=$((NOW0 + 600000))
LR="$MGR_STATE_DIR/managers/ws-w3.last_report.json"

echo "# 1. exhausted window: the tick names the limit and the stalled pane, and prompts nobody"
export FAKE_USAGE="$T/usage.json"; usage_file exhausted 1 "$RESET" >"$FAKE_USAGE"
"$ROOT/bin/mgr-guard" register '{"manager_id":"ws-w9","workspace_id":"w9","pane_id":"w9:p1","repo":"acme/shape","primary":"/s","cap":3,"in_flight":0,"adopting":0,"ready":2}' >/dev/null
st=$(MGR_GUARD_NOW_MS=$NOW0 "$ROOT/bin/mgr-guard" tick)
is "providers.anthropic.status" "$(jq -r '.providers.anthropic.status' <<<"$st")" exhausted
is "providers.anthropic.recovers_at" "$(jq -r '.providers.anthropic.recovers_at' <<<"$st")" "$RESET"
is "providers.anthropic.exhausted_limit" "$(jq -r '.providers.anthropic.exhausted_limit' <<<"$st")" anthropic:5h
is "stalled length" "$(jq -r '.stalled | length' <<<"$st")" 1
is "stalled[0].name" "$(jq -r '.stalled[0].name' <<<"$st")" issue-49
is "stalled[0].recovers_at" "$(jq -r '.stalled[0].recovers_at' <<<"$st")" "$RESET"
is "stalled[0].limit" "$(jq -r '.stalled[0].limit' <<<"$st")" anthropic:5h
is "no prompt while exhausted" "$(lines "$T/prompts.log")" 0
is "no allowed_total/constrained anywhere in the ledger" \
  "$(jq -r '[paths | map(tostring) | join(".")]
            | map(select(test("allowed_total|constrained|allotment|derived_cap|priority|demand")))
            | length' <<<"$st")" 0

echo "# 2. mgr board (real mgr, real guard): the cap alone, the stall, the projection"
# make the guard look alive: status checks guard.pid + tick freshness
guard_alive
bd=$(MGR_GUARD_NOW_MS=$NOW0 "$ROOT/bin/mgr" board --cap 3)
is "quota.guard" "$(jq -r '.quota.guard' <<<"$bd")" running
is "cap" "$(jq -r '.cap' <<<"$bd")" 3
is "no cap_effective" "$(jq -r 'has("cap_effective")' <<<"$bd")" false
is "slots_free (cap 3 - 2 in flight)" "$(jq -r '.slots_free' <<<"$bd")" 1
is "quota.stalled" "$(jq -c '.quota.stalled' <<<"$bd")" '[49]'
is "in_flight 49 quota_stalled" "$(jq -r '.in_flight[] | select(.number==49) | .quota_stalled' <<<"$bd")" true
is "in_flight 49 has no quota_paused" "$(jq -r '.in_flight[] | select(.number==49) | has("quota_paused")' <<<"$bd")" false
is "quota keys are the watered-down set" "$(jq -c '.quota | keys_unsorted' <<<"$bd")" \
  '["guard","last_exit_at","last_exit_reason","provider","status","limits","reason","stalled","managers","changed","delta"]'
is "quota.limits[] fields" "$(jq -c '.quota.limits[0] | keys_unsorted' <<<"$bd")" \
  '["id","used","burn_per_hour","projected_at_reset","resets_at","fits"]'
is "quota.limits covers both limits" "$(jq -c '[.quota.limits[].id]' <<<"$bd")" '["anthropic:5h","anthropic:7d"]'
is "quota.limits[1] fields too" "$(jq -c '.quota.limits[1] | keys_unsorted' <<<"$bd")" \
  '["id","used","burn_per_hour","projected_at_reset","resets_at","fits"]'
is "quota.reason is the guard's reason, verbatim" "$(jq -r '.quota.reason' <<<"$bd")" \
  "$(jq -r '.providers.anthropic.reason' <<<"$st")"
is "quota.managers[] fields" "$(jq -c '.quota.managers[0] | keys_unsorted' <<<"$bd")" \
  '["manager_id","repo","provider","cap","in_flight","live","pane_alive","seen_at"]'
is "quota.changed on the first projection" "$(jq -r '.quota.changed' <<<"$bd")" true
is "quota.delta" "$(jq -r '.quota.delta' <<<"$bd")" 'first projection'
is "last_report recorded" "$([ -f "$LR" ] && echo yes || echo no)" yes
is "last_report shape" "$(jq -c 'keys_unsorted' "$LR")" '["at","provider","limits"]'
is "last_report.provider" "$(jq -r '.provider' "$LR")" anthropic
is "last_report.limits[] fields" "$(jq -c '.limits[0] | keys_unsorted' "$LR")" \
  '["id","projected_at_reset","fits"]'
is "last_report.at is a number" "$(jq -r '.at | type' "$LR")" number

echo "# 3. a second identical board: nothing moved, so there is nothing to say"
bd=$(MGR_GUARD_NOW_MS=$NOW0 "$ROOT/bin/mgr" board --cap 3)
is "quota.changed" "$(jq -r '.quota.changed' <<<"$bd")" false
is "quota.delta" "$(jq -r '.quota.delta' <<<"$bd")" null

echo "# 4. the board's registration is what the next tick attributes the stall to"
st=$(MGR_GUARD_NOW_MS=$NOW0 "$ROOT/bin/mgr-guard" tick)
is "stalled[0].manager_id" "$(jq -r '.stalled[0].manager_id' <<<"$st")" ws-w3
is "still no prompt" "$(lines "$T/prompts.log")" 0
is "registered ws-w3" "$(jq -r '.manager_id' "$MGR_STATE_DIR/managers/ws-w3.json")" ws-w3
is "registration cap" "$(jq -r '.cap' "$MGR_STATE_DIR/managers/ws-w3.json")" 3
is "registration has no demand" "$(jq -r 'has("demand")' "$MGR_STATE_DIR/managers/ws-w3.json")" false
is "registration keys" "$(jq -c 'keys_unsorted' "$MGR_STATE_DIR/managers/ws-w3.json")" \
  '["manager_id","workspace_id","pane_id","repo","primary","house","provider","cap","paused_by_operator","in_flight","adopting","ready","seen_at"]'
# the whole point of #32: the guard learns which subscription to sample from the
# manager's own registration, not from the machine's omp default
is "registration carries the manager's house" \
  "$(jq -r '.house' "$MGR_STATE_DIR/managers/ws-w3.json")" anthropic
is "registration carries the provider that house burns" \
  "$(jq -r '.provider' "$MGR_STATE_DIR/managers/ws-w3.json")" anthropic
is "the provider polled is the registered one" \
  "$(jq -r '.providers | keys | join(",")' <<<"$st")" anthropic
is "the guard skips the board's report file" "$(jq -r '.managers | keys | join(",")' <<<"$st")" ws-w3,ws-w9

echo "# 5. mgr launch is refused on the cap alone, and its internal board records nothing"
touch -t 202001010101 "$LR"
lr_md5=$(md5sum <"$LR" | cut -d' ' -f1); lr_mt=$(mt "$LR")
set +e
err=$(MGR_GUARD_NOW_MS=$NOW0 "$ROOT/bin/mgr" launch 51 --cap 2 2>&1 >/dev/null); rc=$?
set -e
is "launch exit" "$rc" 3
is "launch refusal" "$(jq -r '.error.message' <<<"$err")" 'no free slots (cap=2)'
case "$err" in *quota*|*cap_effective*) bad "launch refusal mentions quota: $err";; *) ok "launch refusal never mentions quota";; esac
is "last_report content untouched by the internal board" "$(md5sum <"$LR" | cut -d' ' -f1)" "$lr_md5"
is "last_report mtime untouched by the internal board" "$(mt "$LR")" "$lr_mt"
guard_gone

echo "# 6. issue #13: a failed usage fetch inside the exhausted window holds the last verdict"
: >"$T/usage.fail"
NOWH=$((NOW0 + 120000))
st=$(MGR_GUARD_NOW_MS=$NOWH "$ROOT/bin/mgr-guard" tick)
is "status is held at exhausted" "$(jq -r '.providers.anthropic.status' <<<"$st")" exhausted
is "ok" "$(jq -r '.providers.anthropic.ok' <<<"$st")" false
is "usage_fetch_failures" "$(jq -r '.providers.anthropic.usage_fetch_failures' <<<"$st")" 1
is "recovers_at survives the failed fetch" "$(jq -r '.providers.anthropic.recovers_at' <<<"$st")" "$RESET"
is "reason" "$(jq -r '.providers.anthropic.reason' <<<"$st")" \
  "unknown: holding last verdict (exhausted until $(iso "$RESET"))"
is "no prompt on a held verdict (#13)" "$(lines "$T/prompts.log")" 0

echo "# 7. the window resets with a positive reading: exactly one reignite, naming that limit"
rm -f "$T/usage.fail"
NOW1=$((RESET + 60000))
usage_file ok 0.02 $((RESET + 18000000)) >"$FAKE_USAGE"
st=$(MGR_GUARD_NOW_MS=$NOW1 "$ROOT/bin/mgr-guard" tick)
is "status" "$(jq -r '.providers.anthropic.status' <<<"$st")" ok
is "usage_fetch_failures reset" "$(jq -r '.providers.anthropic.usage_fetch_failures' <<<"$st")" 0
is "recovered event" "$(jq -r '[.events[] | select(.kind=="recovered")] | length' <<<"$st")" 1
is "reignite event" "$(jq -r '[.events[] | select(.kind=="reignite")] | length' <<<"$st")" 1
is "one prompt" "$(lines "$T/prompts.log")" 1
is "prompt target" "$(cut -f1 "$T/prompts.log")" w3:p2
prompt=$(cut -f2 "$T/prompts.log")
# the 7d limit sits at 20% and the 5h one at 2%: the prompt names the window that
# actually closed (the guard's exhausted_limit), not the fullest one
case "$prompt" in "mgr-guard: anthropic:5h reset at $(iso "$RESET"), now at 2%."*) ok "reignite text names the reset limit and the reading";;
  *) bad "reignite text: $prompt";; esac
case "$prompt" in *"available again"*) bad "reignite text claims availability: $prompt";; *) ok "reignite text never says 'available again'";; esac
case "$prompt" in *"resume exactly where you stopped"*) ok "reignite text tells the builder to resume";; *) bad "reignite text: $prompt";; esac
is "attempts" "$(jq -r '.stalled[0].attempts' <<<"$st")" 1
is "next_reignite_at is 15 min out" "$(jq -r '.stalled[0].next_reignite_at' <<<"$st")" "$((NOW1 + 900000))"

echo "# 8. the next tick is inside the backoff: no second prompt"
st=$(MGR_GUARD_NOW_MS=$((NOW1 + 60000)) "$ROOT/bin/mgr-guard" tick)
is "still one prompt" "$(lines "$T/prompts.log")" 1
is "attempts unchanged" "$(jq -r '.stalled[0].attempts' <<<"$st")" 1

echo "# 9. the recovers_at path: only failed fetches, but the reset we waited for has passed"
MAIN_STATE="$MGR_STATE_DIR"
export MGR_STATE_DIR="$T/state-recovers"
: >"$T/prompts.log"
MB0=1788600000000; R3=$((MB0 + 600000))
usage_file exhausted 1 "$R3" >"$FAKE_USAGE"
st=$(MGR_GUARD_NOW_MS=$MB0 "$ROOT/bin/mgr-guard" tick)
is "exhausted, waiting for the reset" "$(jq -r '.providers.anthropic.status' <<<"$st")" exhausted
is "no prompt yet" "$(lines "$T/prompts.log")" 0
: >"$T/usage.fail"
st=$(MGR_GUARD_NOW_MS=$((R3 + 1000)) "$ROOT/bin/mgr-guard" tick)
rm -f "$T/usage.fail"
is "the hold expires into unknown" "$(jq -r '.providers.anthropic.status' <<<"$st")" unknown
is "one prompt off recovers_at alone" "$(lines "$T/prompts.log")" 1
prompt=$(cut -f2 "$T/prompts.log")
case "$prompt" in "mgr-guard: anthropic:5h reset at $(iso "$R3") has passed (no fresh usage reading)."*)
  ok "recovers_at reignite text";; *) bad "recovers_at reignite text: $prompt";; esac
export MGR_STATE_DIR="$MAIN_STATE"

echo "# 10. the burn fit over the window: 0.6/h with 2 h to reset at 70% projects 1.9x"
NOW2=$((NOW1 + 3600000)); R2=$((NOW2 + 7200000))   # 2h to reset
: >"$MGR_STATE_DIR/samples.jsonl"
for i in 0 1 2; do
  t=$((NOW2 - 1200000 + i * 600000)); u=$(jq -n "0.5 + $i * 0.1")
  jq -nc --argjson t "$t" --argjson u "$u" --argjson r "$R2" '{t:$t,provider:"anthropic",limit:"anthropic:5h",used:$u,resets_at:$r,status:"ok"}' >>"$MGR_STATE_DIR/samples.jsonl"
done
usage_file ok 0.7 "$R2" >"$FAKE_USAGE"
st=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr-guard" tick)
L0='.providers.anthropic.limits[0]'
is "burn_per_hour" "$(jq -r "$L0.burn_per_hour" <<<"$st")" 0.6
is "hours_to_reset" "$(jq -r "$L0.hours_to_reset" <<<"$st")" 2
is "projected_at_reset" "$(jq -r "$L0.projected_at_reset" <<<"$st")" 1.9
is "fits" "$(jq -r "$L0.fits" <<<"$st")" false
ge "samples stay in the ledger" "$(jq -r "$L0.samples | length" <<<"$st")" 3
is "sample_count matches" "$(jq -r "$L0.sample_count" <<<"$st")" "$(jq -r "$L0.samples | length" <<<"$st")"
is "reason" "$(jq -r '.providers.anthropic.reason' <<<"$st")" \
  "anthropic:5h at 70% burning 0.6/h → 1.9× the window by $(hhmm "$R2")"
# the quota is healthy and the pane's backoff has expired, so this same tick
# reignites issue-49 a second time -- the guard's only action, ever
is "second reignite attempt" "$(jq -r '.stalled[0].attempts' <<<"$st")" 2

echo "# 11. the board surfaces that projection and says how it moved"
was=$(jq -r '[.limits[] | select(.id=="anthropic:5h") | .projected_at_reset] | first' "$LR")
want="anthropic:5h $(jq -nr --argjson w "$was" '($w * 100 | round) / 100 | tostring')× → 1.9× (now over)"
guard_alive
bd=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" board --cap 3)
is "quota.changed" "$(jq -r '.quota.changed' <<<"$bd")" true
is "quota.delta" "$(jq -r '.quota.delta' <<<"$bd")" "$want"
is "quota.reason is the guard's" "$(jq -r '.quota.reason' <<<"$bd")" \
  "$(jq -r '.providers.anthropic.reason' <<<"$st")"
is "quota.limits[0].projected_at_reset" "$(jq -r '.quota.limits[0].projected_at_reset' <<<"$bd")" 1.9
is "quota.limits[0].fits" "$(jq -r '.quota.limits[0].fits' <<<"$bd")" false
is "no keys were ever sent" "$(lines "$T/keys.log")" 0

echo "# 12. mgr wait --no-quota-block: one park on the revival, then the hold is the answer"
: >"$T/waits.log"
out=$(MGR_GUARD_NOW_MS=$NOW2 "$ROOT/bin/mgr" wait 49 --no-quota-block)
is "agent_status" "$(jq -r '.agent_status' <<<"$out")" quota-stalled
is "stall keys" "$(jq -c '.stall | keys_unsorted' <<<"$out")" \
  '["provider","model","error","since","retry_after_ms","resets_at","guard"]'
is "stall.provider" "$(jq -r '.stall.provider' <<<"$out")" anthropic
is "stall.error is non-empty" "$(jq -r '.stall.error | length > 0' <<<"$out")" true
is "stall.resets_at is a number" "$(jq -r '.stall.resets_at | type' <<<"$out")" number
is "stall.guard" "$(jq -r '.stall.guard' <<<"$out")" running
is "no cause key" "$(jq -r '.stall | has("cause")' <<<"$out")" false
is "parked --until working first" "$(head -1 "$T/waits.log")" "issue-49 --until working"
guard_gone

echo "# 13. default mgr wait rides the hold out until the guard reignites the builder"
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

echo "# 14. guard stopped: wait answers immediately, and the board still reports the plain cap"
rm -f "$MGR_STATE_DIR/guard.pid"; : >"$T/waits.log"
out=$("$ROOT/bin/mgr" wait 49)
is "agent_status" "$(jq -r '.agent_status' <<<"$out")" quota-stalled
is "stall.guard" "$(jq -r '.stall.guard' <<<"$out")" stopped
is "no herdr wait issued" "$(lines "$T/waits.log")" 0
bd=$("$ROOT/bin/mgr" board --cap 3)
is "quota.guard" "$(jq -r '.quota.guard' <<<"$bd")" stopped
is "cap" "$(jq -r '.cap' <<<"$bd")" 3
is "slots_free is the cap alone" "$(jq -r '.slots_free' <<<"$bd")" 1

# ---------------------------------------------------------------------------
# Scenario E: the operator's pause, end to end. Its own state dir, its own
# agents, its own clock (every mgr/guard call pins it, so the registration's
# seen_at and the tick agree), and a healthy provider throughout.
echo "# 15. operator-pause fixture: acme/proj in w5, one working builder issue-60, quota fine"
export MGR_STATE_DIR="$T/state-pause"
export HERDR_WORKSPACE_ID=w5 HERDR_PANE_ID=w5:p1 HERDR_TAB_ID=w5:t1
mkdir -p "$MGR_STATE_DIR/managers"
: >"$T/prompts.log"; : >"$T/waits.log"
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
MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr-guard" tick >/dev/null
is "the provider is healthy" "$(jq -r '.providers.anthropic.reason' "$MGR_STATE_DIR/state.json")" fits

echo "# 16. mgr pause: cap 0 for this repo, stored in the primary's git config"
out=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" pause)
is "mgr pause json" "$(jq -c . <<<"$out")" '{"repo":"acme/proj","paused":true,"cap":0,"previous_cap":3}'
is "the pause is in the git store" "$(cat "$T/gitcfg.mgr.paused")" true
is "registration cap after the pause" "$(jq -r '.cap' "$MGR_STATE_DIR/managers/ws-w5.json")" 0
is "registration paused_by_operator after the pause" \
  "$(jq -r '.paused_by_operator' "$MGR_STATE_DIR/managers/ws-w5.json")" true
out=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" pause)
is "mgr pause is idempotent" "$(jq -c . <<<"$out")" \
  '{"repo":"acme/proj","paused":true,"cap":0,"previous_cap":3}'

echo "# 17. board while paused: the pause outranks --cap 3 and says nothing about the quota"
bd=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" board --cap 3)
is "paused_by_operator" "$(jq -r '.paused_by_operator' <<<"$bd")" true
is "cap" "$(jq -r '.cap' <<<"$bd")" 0
is "slots_free" "$(jq -r '.slots_free' <<<"$bd")" 0
is "config.cap still reports the configured cap" "$(jq -r '.config.cap' <<<"$bd")" 3
is "quota.reason is unaffected by the pause" "$(jq -r '.quota.reason' <<<"$bd")" fits
is "quota has no paused key" "$(jq -r '.quota | has("paused")' <<<"$bd")" false

echo "# 18. mgr launch while paused: one sentence naming mgr unpause, --cap 3 does not lift it"
set +e
err=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" launch 61 --cap 3 2>&1 >/dev/null); rc=$?
set -e
is "launch exit" "$rc" 3
is "launch refusal" "$(jq -r '.error.message' <<<"$err")" \
  'this project is paused by the operator (cap 0); mgr unpause lifts it'

echo "# 19. the guard's next tick: the pause is none of its business"
st=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr-guard" tick)
is "provider status" "$(jq -r '.providers.anthropic.status' <<<"$st")" ok
is "nothing is stalled" "$(jq -r '.stalled | length' <<<"$st")" 0
is "no prompt to the working builder" "$(lines "$T/prompts.log")" 0
is "no keys to the working builder" "$(lines "$T/keys.log")" 0
is "the guard knows nothing of paused repos" "$(jq -r 'has("paused_repos")' <<<"$st")" false
is "registration the guard sees is cap 0" "$(jq -r '.managers["ws-w5"].cap' <<<"$st")" 0
gs=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" guard status)
is "mgr guard status passes the ledger through" "$(jq -r '.managers["ws-w5"].manager_id' <<<"$gs")" ws-w5
is "mgr guard status has no pause of its own" "$(jq -r 'has("paused_repos")' <<<"$gs")" false

echo "# 20. mgr unpause: the cap and the free slots come back, and mgr priority is gone"
out=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" unpause)
is "mgr unpause json" "$(jq -c . <<<"$out")" '{"repo":"acme/proj","paused":false,"cap":3}'
is "the git store is cleared" "$([ -f "$T/gitcfg.mgr.paused" ] && echo present || echo gone)" gone
is "registration cap after the unpause" "$(jq -r '.cap' "$MGR_STATE_DIR/managers/ws-w5.json")" 3
is "registration paused_by_operator after the unpause" \
  "$(jq -r '.paused_by_operator' "$MGR_STATE_DIR/managers/ws-w5.json")" false
bd=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" board --cap 3)
is "paused_by_operator" "$(jq -r '.paused_by_operator' <<<"$bd")" false
is "cap" "$(jq -r '.cap' <<<"$bd")" 3
is "slots_free" "$(jq -r '.slots_free' <<<"$bd")" 2
set +e
err=$(MGR_GUARD_NOW_MS=$PC "$ROOT/bin/mgr" priority 2 2>&1 >/dev/null); rc=$?
set -e
is "mgr priority exit" "$rc" 2
case "$err" in *"unknown subcommand: priority"*) ok "mgr priority is gone";; *) bad "mgr priority: $err";; esac

echo "# 21. nothing was ever interrupted: send-keys was never called in the whole run"
is "keys.log" "$(lines "$T/keys.log")" 0

[ "$fail" = 0 ] && echo "e2e-quota: all assertions passed" || { echo "e2e-quota: FAILURES"; exit 1; }
