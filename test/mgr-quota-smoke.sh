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
[{"number":7,"title":"Another thing","labels":[{"name":"size:small"}],"body":""},
 {"number":49,"title":"Do the thing","labels":[{"name":"mgr:in-flight"},{"name":"size:medium"}],"body":""}]
EOF
cat >"$fix/issue-7.json" <<'EOF'
{"number":7,"title":"Another thing","state":"OPEN","labels":[{"name":"size:small"}],"body":""}
EOF
cat >"$fix/issue-49.json" <<'EOF'
{"number":49,"title":"Do the thing","state":"OPEN","labels":[{"name":"mgr:in-flight"},{"name":"size:medium"}],"body":""}
EOF
# issue 9: an adoptee for the execution-record tests below — never bound (no
# launch stamp), size:small, merged via a report whose pr the PR-lookup can
# never resolve (its fixture is removed before that test runs).
cat >"$fix/issue-9.json" <<'EOF'
{"number":9,"title":"Adopted thing","state":"OPEN","labels":[{"name":"size:small"}],"body":""}
EOF

# issue 7's comment thread: the builder's merged report, with the createdAt the
# comment-fallback throughput row measures against (the PR-sourced path in the
# "10" tests below uses a separate fixture and lands 1h later than this).
cat >"$fix/comments-7.json" <<'EOF'
{"comments":[
  {"body":"manager: bound · tab w9:t2 · agent issue-7","createdAt":"2026-09-04T12:00:00Z"},
  {"body":"manager-report: status=merged sha=abc pr=https://github.com/owner/name/pull/70 review=sweep review_verdict=\"2 fixed\" checks=run.sh,shellcheck escalations=0 delegated_planning=sketch pre_existing_red=1 final_size=medium",
   "createdAt":"2026-09-04T13:00:00Z"}]}
EOF

# issue 9's report: no pr fixture will exist for it, so merged_at must fall
# back to this comment's own createdAt.
cat >"$fix/comments-9.json" <<'EOF'
{"comments":[
  {"body":"manager-report: status=merged sha=def pr=https://github.com/owner/name/pull/91 review=none review_verdict=skipped checks=run.sh escalations=1 delegated_planning=plan pre_existing_red=0 final_size=small",
   "createdAt":"2026-09-04T15:00:00Z"}]}
EOF

sess="$tmp/session-49.jsonl"
: >"$sess"
# the manager's own session: the last assistant message is where `mgr house`
# reads the provider and model that answered it
msess="$tmp/session-manager.jsonl"
cat >"$msess" <<'EOF'
{"type":"message","timestamp":"2026-09-04T11:59:00Z","message":{"role":"user","content":"hi"}}
{"type":"message","timestamp":"2026-09-04T11:59:30Z","message":{"role":"assistant","provider":"anthropic","model":"claude-fable-5-1","stopReason":"end_turn"}}
EOF

# issue 7's builder session: known turns/tokens/subagents so the execution
# record's derived metrics can be asserted exactly. Three assistant turns
# (two claude-fable-5-1, one claude-smol that hit a 429), one user message
# (not a turn), a model change, a resize, and one garbage line.
bsess="$tmp/session-7.jsonl"
cat >"$bsess" <<'EOF'
{"type":"message","timestamp":"2026-09-04T12:00:01.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-fable-5-1","stopReason":"end_turn","duration":100,"usage":{"input":100,"output":10,"cacheRead":5,"cacheWrite":1,"totalTokens":116,"cost":{"total":0.1}}}}
{"type":"message","timestamp":"2026-09-04T12:00:02.000Z","message":{"role":"user","content":"go on"}}
{"type":"message","timestamp":"2026-09-04T12:00:03.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-fable-5-1","stopReason":"end_turn","duration":200,"usage":{"input":200,"output":20,"cacheRead":5,"cacheWrite":1,"totalTokens":226,"cost":{"total":0.2}}}}
{"type":"model_change","timestamp":"2026-09-04T12:00:04.000Z"}
{"type":"message","timestamp":"2026-09-04T12:00:05.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-smol","stopReason":"error","errorStatus":429,"errorMessage":"rate limit","duration":300,"usage":{"input":300,"output":30,"cacheRead":5,"cacheWrite":1,"totalTokens":336,"cost":{"total":0.3}}}}
{"type":"title_change","trigger":"replan","timestamp":"2026-09-04T12:00:06.000Z"}
not json garbage {{{
EOF
mkdir -p "$tmp/session-7"
cat >"$tmp/session-7/Scout1.jsonl" <<'EOF'
{"type":"session_init","agent":"scout","modelRole":"scout","resolvedModel":"anthropic/claude-x"}
{"type":"message","timestamp":"2026-09-04T12:00:10.000Z","message":{"role":"assistant","content":"ok"}}
EOF
cat >"$tmp/session-7/Scout2.jsonl" <<'EOF'
{"type":"session_init","agent":"scout","modelRole":"scout","resolvedModel":"anthropic/claude-x"}
{"type":"message","timestamp":"2026-09-04T12:00:11.000Z","message":{"role":"assistant","content":"ok"}}
EOF
cat >"$tmp/session-7/Sketch1.jsonl" <<'EOF'
{"type":"session_init","agent":"sketch","modelRole":"sketch","resolvedModel":"anthropic/claude-x"}
{"type":"message","timestamp":"2026-09-04T12:00:12.000Z","message":{"role":"assistant","content":"ok"}}
EOF

jq -n --arg cwd "$repo" --arg sess "$sess" --arg msess "$msess" '
  {result:{agents:[
    {name:"issue-49",pane_id:"w9:p2",tab_id:"w9:t2",workspace_id:"w9",cwd:$cwd,
     agent:"omp",agent_status:"blocked",agent_session:{value:$sess}},
    {name:"manager",pane_id:"w9:p1",tab_id:"w9:t1",workspace_id:"w9",cwd:$cwd,
     agent:"omp",agent_status:"working",agent_session:{value:$msess}}
  ]}}' >"$fix/agents.json"
jq '{result:{agent:(.result.agents[0])}}' "$fix/agents.json" >"$fix/agent-issue-49.json"

# guard running: two subscriptions sampled in the same tick — anthropic (the
# 5h one does not fit) and openai-codex — and two registered managers, one on
# each, so every quota reading has a wrong provider to be confused with. Plus
# issue-49 stalled on a 429 waiting for the guard to reignite it. This is
# state.json v2 plus the {guard,pid} wrapper `mgr-guard status` adds.
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
              "fits":true,"hours_to_reset":10.5,"sample_count":3,"samples":[]}]},
  "openai-codex":{"status":"warning","ok":true,"fetched_at":1788523750000,
   "usage_fetch_failures":0,"recovers_at":null,
   "reason":"openai-codex:5h at 71% burning 0.2/h → 1.13× the window by 17:13Z",
   "limits":[{"id":"openai-codex:5h","label":"Codex 5 Hour","status":"warning","used":0.71,
              "resets_at":1788530000000,"burn_per_hour":0.2,"projected_at_reset":1.13,
              "fits":false,"hours_to_reset":2.1,"sample_count":2,"samples":[]}]}},
 "managers":{"ws-w9":{"manager_id":"ws-w9","workspace_id":"w9","pane_id":"w9:p1",
   "repo":"owner/name","primary":"/tmp/repo","house":"anthropic","provider":"anthropic",
   "cap":3,"in_flight":1,"adopting":0,"ready":1,
   "seen_at":1788523750609,"pane_alive":true,"live":true},
  "ws-w8":{"manager_id":"ws-w8","workspace_id":"w8","pane_id":"w8:p1",
   "repo":"other/shape","primary":"/tmp/shape","house":"openai","provider":"openai-codex",
   "cap":1,"in_flight":0,"adopting":0,"ready":0,
   "seen_at":1788523750609,"pane_alive":true,"live":true}},
 "stalled":[{"pane_id":"w9:p2","name":"issue-49","workspace_id":"w9","session":"/x.jsonl",
   "provider":"anthropic","model":"claude-fable-5-1","error":"429 rate_limit_error",
   "since":1788520000000,"retry_after_ms":976000,"recovers_at":null,"manager_id":"ws-w9",
   "attempts":1,"last_reignite_at":null,"next_reignite_at":1788521000000}],
 "events":[]}
EOF

# ------------------------------------------------- overview fixtures (real guard)
#
# A hand-written ledger for `mgr-guard overview`: the clock is pinned at
# 2026-09-04 12:00:00Z, the anthropic 5h limit exhausts 30 min later and resets
# at 14:00Z (a 1h30 stall window every projection has to step over), and three
# live managers share the machine — `owner/name` (this board's own repo, on
# anthropic) with a measured 1h median, two slots and eleven queued issues,
# `other/shape` (also anthropic) with a machine-median guess, one free slot and
# nothing ready, so it starves now while its single blocked issue still
# projects, and `zed/paused` on openai-codex with no cap and nothing queued —
# it is here to be *excluded* from the anthropic managers' quota line. The
# openai-codex 5h limit fits, so it adds no stall window and no ETA of its own.
ovstate="$tmp/ovstate"
mkdir -p "$ovstate"
pin=1788523200000        # 2026-09-04T12:00:00Z
real_guard="$here/../bin/mgr-guard"

jq -n --argjson N "$pin" '
  def issues($from; $to): [range($from; $to + 1) | {number:., title:"ready \(.)", blocked_by:[]}];
  {version:2, tick_at:$N, interval_s:60, builder_provider:"anthropic",
   providers:{anthropic:{status:"warning", ok:true, fetched_at:$N,
     usage_fetch_failures:0, recovers_at:null,
     reason:"anthropic:5h at 80% burning 0.4/h → 2.2× the window by 14:00Z",
     limits:[{id:"anthropic:5h", label:"Claude 5 Hour", status:"warning", used:0.8,
              resets_at:($N + 7200000), burn_per_hour:0.4, projected_at_reset:2.2,
              fits:false, hours_to_reset:2, sample_count:3, samples:[]},
             {id:"anthropic:week", label:"Claude Week", status:"ok", used:0.2,
              resets_at:1788771600000, burn_per_hour:0.02, projected_at_reset:12.6,
              fits:true, hours_to_reset:93, sample_count:3, samples:[]}]},
     "openai-codex":{status:"ok", ok:true, fetched_at:$N,
       usage_fetch_failures:0, recovers_at:null,
       reason:"openai-codex:5h at 30% burning 0.1/h → 0.5× the window by 14:00Z",
       limits:[{id:"openai-codex:5h", label:"Codex 5 Hour", status:"ok", used:0.3,
                resets_at:($N + 7200000), burn_per_hour:0.1, projected_at_reset:0.5,
                fits:true, hours_to_reset:2, sample_count:3, samples:[]}]}},
   managers:{
     "ws-w9":{manager_id:"ws-w9", workspace_id:"w9", pane_id:"w9:p1", repo:"owner/name",
       primary:"/tmp/repo", house:"anthropic", provider:"anthropic",
       cap:2, in_flight:1, adopting:0, ready:10,
       seen_at:$N, pane_alive:true, live:true,
       backlog:{ready:issues(7; 16),
                blocked:[{number:17, title:"needs 7", blocked_by:[7]}],
                in_flight:[{number:49, title:"Do the thing", launched_at:($N - 2700000)}],
                awaiting_approval:[], cap:2, slots_free:1,
                counts:{ready:10, blocked:1, in_flight:1, awaiting_approval:0, open:12}},
       backlog_at:$N, backlog_error:null,
       throughput:{n:5, median_s:3600, p80_s:4200, last_10_mean_s:3700,
                   estimated:false, source:"repo"}},
     "ws-w8":{manager_id:"ws-w8", workspace_id:"w8", pane_id:"w8:p1", repo:"other/shape",
       primary:"/tmp/shape", house:"anthropic", provider:"anthropic",
       cap:1, in_flight:0, adopting:0, ready:0,
       seen_at:$N, pane_alive:true, live:true,
       backlog:{ready:[],
                blocked:[{number:101, title:"waits on a foreign issue", blocked_by:[999]}],
                in_flight:[], awaiting_approval:[], cap:1, slots_free:1,
                counts:{ready:0, blocked:1, in_flight:0, awaiting_approval:0, open:1}},
       backlog_at:$N, backlog_error:null,
       throughput:{n:1, median_s:1500, p80_s:1500, last_10_mean_s:1500,
                   estimated:true, source:"machine"}},
     "ws-w6":{manager_id:"ws-w6", workspace_id:"w6", pane_id:"w6:p1", repo:"zed/paused",
       primary:"/tmp/zed", house:"openai", provider:"openai-codex",
       cap:0, in_flight:0, adopting:0, ready:0,
       seen_at:$N, pane_alive:true, live:true,
       backlog:{ready:[], blocked:[], in_flight:[], awaiting_approval:[],
                cap:0, slots_free:0,
                counts:{ready:0, blocked:0, in_flight:0, awaiting_approval:0, open:0}},
       backlog_at:$N, backlog_error:null,
       throughput:{n:0, median_s:1500, p80_s:1500, last_10_mean_s:1500,
                   estimated:true, source:"machine"}},
     "ws-dead":{manager_id:"ws-dead", workspace_id:"w7", pane_id:"w7:p1",
       repo:"gone/repo", primary:"/tmp/gone", cap:4, in_flight:0, adopting:0, ready:0,
       seen_at:($N - 900000), pane_alive:false, live:false}},
   stalled:[], events:[]}' >"$ovstate/state.json"

# the same machine with a small backlog: four queued issues, so the default
# limit of 10 hides nothing
ovsmall="$tmp/ovsmall"; mkdir -p "$ovsmall"
jq '.managers["ws-w9"].ready = 2
  | .managers["ws-w9"].backlog.ready =
      [{number:7, title:"ready 7", blocked_by:[]}, {number:8, title:"ready 8", blocked_by:[]}]
  | .managers["ws-w9"].backlog.counts.ready = 2
  | .managers["ws-w9"].backlog.counts.open = 4' \
  "$ovstate/state.json" >"$ovsmall/state.json"

# and with 34 ready issues, so even `--limit 30` cannot fit the list in three
# physical lines
ovmany="$tmp/ovmany"; mkdir -p "$ovmany"
jq '.managers["ws-w9"].ready = 34
  | .managers["ws-w9"].backlog.ready =
      [range(7; 41) | {number:., title:"ready \(.)", blocked_by:[]}]
  | .managers["ws-w9"].backlog.counts.ready = 34
  | .managers["ws-w9"].backlog.counts.open = 36' \
  "$ovstate/state.json" >"$ovmany/state.json"

# and with this repo registered but empty: nothing running, nothing queued, so
# the block has nothing to list and must say so instead of printing blanks
ovidle="$tmp/ovidle"; mkdir -p "$ovidle"
jq '.managers["ws-w9"].ready = 0
  | .managers["ws-w9"].in_flight = 0
  | .managers["ws-w9"].backlog.ready = []
  | .managers["ws-w9"].backlog.blocked = []
  | .managers["ws-w9"].backlog.in_flight = []
  | .managers["ws-w9"].backlog.slots_free = 2
  | .managers["ws-w9"].backlog.counts =
      {ready:0, blocked:0, in_flight:0, awaiting_approval:0, open:0}' \
  "$ovstate/state.json" >"$ovidle/state.json"

# the same machine with nothing stalling anywhere: the anthropic 5h limit fits
# too, so no provider has a window and every ETA is plain work time. This is
# the control the foreign-stall ledger below is compared against — its block is
# what an anthropic manager reads when the machine holds no stall at all.
ovnostall="$tmp/ovnostall"; mkdir -p "$ovnostall"
jq '.providers.anthropic.status = "ok"
  | .providers.anthropic.limits[0].fits = true
  | .providers.anthropic.limits[0].projected_at_reset = 0.9
  | .providers.anthropic.reason =
      "anthropic:5h at 80% burning 0.4/h → 0.9× the window by 14:00Z"' \
  "$ovstate/state.json" >"$ovnostall/state.json"

# ... and the same machine again with the *other* subscription stalling: the
# openai-codex 5h limit is at 80% burning 0.4/h, so it runs out 30 min in and
# reopens at the 14:00Z reset, while both anthropic limits still fit. It is the
# only stalling limit on the machine, so it is also the machine-wide record —
# and `owner/name` and `other/shape` burn anthropic and can never wait it out.
ovforeign="$tmp/ovforeign"; mkdir -p "$ovforeign"
jq '.providers["openai-codex"].status = "warning"
  | .providers["openai-codex"].limits[0].used = 0.8
  | .providers["openai-codex"].limits[0].burn_per_hour = 0.4
  | .providers["openai-codex"].limits[0].projected_at_reset = 2.2
  | .providers["openai-codex"].limits[0].fits = false
  | .providers["openai-codex"].reason =
      "openai-codex:5h at 80% burning 0.4/h → 2.2× the window by 14:00Z"' \
  "$ovnostall/state.json" >"$ovforeign/state.json"

# and once more with this repo's own manager registered on openai-codex: same
# stall, but now it is the caller's own subscription that holds it
ovcodex="$tmp/ovcodex"; mkdir -p "$ovcodex"
jq '.managers["ws-w9"].house = "openai"
  | .managers["ws-w9"].provider = "openai-codex"' \
  "$ovforeign/state.json" >"$ovcodex/state.json"

# and once more with the caller's own provider held rather than sampled: the
# daemon could not poll anthropic this tick, so the ledger carries the
# exhausted verdict it is holding until the reset with no fresh limits at
# all. The rendered quota line must still read the plain no-reading
# sentence — an empty limits list is never a stale percentage (acceptance
# box 10; bin/mgr-guard:262-265 is what actually writes this shape).
ovheld="$tmp/ovheld"; mkdir -p "$ovheld"
jq '.providers.anthropic.status="exhausted" | .providers.anthropic.ok=false
    | .providers.anthropic.recovers_at=1788530400000
    | .providers.anthropic.exhausted_limit="anthropic:5h"
    | .providers.anthropic.reason=
        "unknown: not polled this tick, holding last verdict (exhausted until 2026-09-04T14:00:00Z)"
    | .providers.anthropic.limits=[]' \
  "$ovstate/state.json" >"$ovheld/state.json"

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

# a live guard, still running, but this tick could not poll the caller's
# provider at all: the daemon holds last verdict with an empty limits list,
# the same shape bin/mgr-guard:262-265 writes, so a manager on it does not
# misread an empty list as a fresh zero-usage reading
jq '.providers.anthropic.status="exhausted" | .providers.anthropic.ok=false
    | .providers.anthropic.recovers_at=1788531111000
    | .providers.anthropic.exhausted_limit="anthropic:5h"
    | .providers.anthropic.reason=
        "unknown: not polled this tick, holding last verdict (exhausted until 2026-09-04T14:11:51Z)"
    | .providers.anthropic.limits=[]' \
  "$fix/guard-running.json" >"$fix/guard-held.json"

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
        # `--json comments` is answered from a per-issue fixture, and `-q` is
        # applied for real: `mgr` reads the report body through it, and the
        # throughput row needs the raw comment JSON with its createdAt
        case " $* " in
          *" comments "*)
            f="$MGR_TEST_FIX/comments-${3:-}.json"
            [ -f "$f" ] || { printf '\n'; exit 0; }
            q=""; prev=""
            for a in "$@"; do
              [ "$prev" = "-q" ] && q="$a"
              prev="$a"
            done
            if [ -n "$q" ]; then jq -r "$q" "$f"; else cat "$f"; fi
            exit 0;;
        esac
        f="$MGR_TEST_FIX/issue-${3:-}.json"
        [ -f "$f" ] || exit 1
        cat "$f";;
      edit|close) exit 0;;
      comment)
        bf=""; prev=""
        for a in "$@"; do
          [ "$prev" = "--body-file" ] && bf="$a"
          prev="$a"
        done
        [ -n "$bf" ] && cp "$bf" "$MGR_TEST_FIX/comment-${3:-}.md"
        exit 0;;
      *) exit 1;;
    esac;;
  pr) case "${2:-}" in
        view) f="$MGR_TEST_FIX/pr-mergedat.txt"; [ -f "$f" ] || exit 1; cat "$f";;
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
  "agent rename") exit 0;;
  "tab rename") exit 0;;
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
  overview)
    # the real guard answers the overview cases; this fake only proves the
    # board tolerates a guard that cannot (exit 2, like an old binary)
    [ -n "${MGR_TEST_OVERVIEW:-}" ] || exit 2
    printf '%s\n' "$MGR_TEST_OVERVIEW";;
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
export MGR_TEST_OVERVIEW=              # set per case; empty = the guard cannot answer
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
assert_jq() { # assert_jq <label> <json> <filter>
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n       filter: %s\n       json:   %s\n' "$1" "$3" "$2"
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
# the overview sits immediately after quota, and a guard that cannot answer it
# is a null field — never a failed board
check 'overview follows quota' true \
  "$(jq -r '(keys_unsorted|index("quota")) as $i
            | keys_unsorted[$i+1] == "overview"' <<<"$out")"
check 'overview when the guard cannot answer' null \
  "$(jq -r '.overview' <<<"$out")"
check 'board overview passthrough' '{"at":1,"burn":{"limits":[]}}' \
  "$(MGR_TEST_OVERVIEW='{"at":1,"burn":{"limits":[]}}' "$MGR" board --cap 3 \
     | jq -c '.overview')"
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
# every issue row carries the size its label says, or null when it has none
check 'in_flight row size'  medium "$(jq -r '.in_flight[0].size' <<<"$out")"
check 'ready row size'       small "$(jq -r '.ready[0].size' <<<"$out")"
check 'in_flight quota_stalled' true "$(jq -r '.in_flight[0].quota_stalled' <<<"$out")"
# every registered manager, with the provider it burns: attribution across
# subscriptions is what makes a mixed fleet readable
check 'quota.managers' \
  '[{"manager_id":"ws-w8","repo":"other/shape","provider":"openai-codex","cap":1,"in_flight":0,"live":true,"pane_alive":true,"seen_at":1788523750609},{"manager_id":"ws-w9","repo":"owner/name","provider":"anthropic","cap":3,"in_flight":1,"live":true,"pane_alive":true,"seen_at":1788523750609}]' \
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
  '["manager_id","workspace_id","pane_id","repo","primary","house","provider","cap","paused_by_operator","in_flight","adopting","ready"]' \
  "$(jq -sc 'last|keys_unsorted' "$MGR_TEST_REGISTER")"
check 'heartbeat has no demand' false \
  "$(jq -rs 'last|has("demand")' "$MGR_TEST_REGISTER")"
check 'heartbeat manager_id' ws-w9 "$(jq -rs 'last|.manager_id' "$MGR_TEST_REGISTER")"
check 'heartbeat counts' '3/1/0/1' \
  "$(jq -rs 'last|"\(.cap)/\(.in_flight)/\(.adopting)/\(.ready)"' "$MGR_TEST_REGISTER")"
check 'heartbeat paused_by_operator' false \
  "$(jq -rs 'last|.paused_by_operator' "$MGR_TEST_REGISTER")"
check 'heartbeat pane_id'   w9:p1 "$(jq -rs 'last|.pane_id' "$MGR_TEST_REGISTER")"
check 'heartbeat repo' owner/name "$(jq -rs 'last|.repo' "$MGR_TEST_REGISTER")"
# the guard's poll set is built from these two: a registration that names no
# provider is a manager the guard cannot sample for
check 'heartbeat house and provider' 'anthropic/anthropic' \
  "$(jq -rs 'last|"\(.house)/\(.provider)"' "$MGR_TEST_REGISTER")"

printf '\n# 1d. quota.* is the caller-provider view, never the machine default\n'
# the fixture guard sampled both subscriptions this tick, and the machine
# default is anthropic — so an openai-codex reading reaching an anthropic
# manager's board (or the reverse) is a scoping bug, not a fixture accident
check 'the fixture guard holds two providers' '["anthropic","openai-codex"]' \
  "$(jq -c '.providers|keys' "$fix/guard-running.json")"
check "this manager's board names no other provider's limit" '[]' \
  "$(jq -c '[.quota.limits[].id | select(startswith("anthropic:") | not)]' <<<"$out")"
check 'quota.managers attributes each manager to its own provider' \
  'ws-w8=openai-codex ws-w9=anthropic' \
  "$(jq -r '[.quota.managers[] | "\(.manager_id)=\(.provider)"] | join(" ")' <<<"$out")"

# MGR_HOUSE drives the real provider_of_house: the house's package file names
# the provider a launch under it burns, and that is the subscription reported
: >"$MGR_TEST_REGISTER"
ob=$(MGR_HOUSE=openai "$MGR" board --cap 3)
check 'an openai manager resolves its package provider' openai-codex \
  "$(jq -r '.quota.provider' <<<"$ob")"
check 'and reads that provider status' warning "$(jq -r '.quota.status' <<<"$ob")"
check 'and only its own limits' '["openai-codex:5h"]' \
  "$(jq -c '[.quota.limits[].id]' <<<"$ob")"
check 'and that provider reason, verbatim' \
  'openai-codex:5h at 71% burning 0.2/h → 1.13× the window by 17:13Z' \
  "$(jq -r '.quota.reason' <<<"$ob")"
check 'its heartbeat carries the same pair' 'openai/openai-codex' \
  "$(jq -rs 'last|"\(.house)/\(.provider)"' "$MGR_TEST_REGISTER")"

gb=$(MGR_HOUSE=gemini "$MGR" board --cap 3)
check 'a gemini manager resolves its package provider' google-antigravity \
  "$(jq -r '.quota.provider' <<<"$gb")"
# the guard never polled it: no reading is the honest answer, not another
# subscription's numbers
check 'a provider the guard never sampled reads empty' 'null/[]/null' \
  "$(jq -r '"\(.quota.status)/\(.quota.limits|tojson)/\(.quota.reason)"' <<<"$gb")"

# a pane whose session has no assistant message, with nothing configured and
# no MGR_HOUSE: nothing can name this caller's house, so it claims no
# subscription at all rather than the machine's
: >"$MGR_TEST_REGISTER"
nb=$(HERDR_PANE_ID=w9:p2 "$MGR" board --cap 3)
check 'an unresolvable caller has no house' null "$(jq -r '.house' <<<"$nb")"
check 'and no provider' null "$(jq -r '.quota.provider' <<<"$nb")"
check 'and no reading of anyone else' 'null/[]/null' \
  "$(jq -r '"\(.quota.status)/\(.quota.limits|tojson)/\(.quota.reason)"' <<<"$nb")"
check 'the guard still sees every manager' 2 \
  "$(jq -r '.quota.managers|length' <<<"$nb")"
check 'and the heartbeat still fires, with both fields null' 'null/null' \
  "$(jq -rs 'last|"\(.house)/\(.provider)"' "$MGR_TEST_REGISTER")"
check 'and it is still a registration' 1 \
  "$(jq -s 'length' "$MGR_TEST_REGISTER")"

printf '\n# 1e. a held verdict reaches the manager, with no limits to misread\n'
# the poll set dropped this tick but the hold is still active: status,
# exhausted_limit and the held sentence pass straight through to the
# manager that burns it, and limits stays the empty list the daemon wrote —
# never a stale percentage a consumer could mistake for a fresh reading
hb=$(MGR_TEST_GUARD="$fix/guard-held.json" "$MGR" board --cap 3)
check 'a held verdict reaches the manager: status' exhausted \
  "$(jq -r '.quota.status' <<<"$hb")"
check 'a held verdict reaches the manager: reason, verbatim' \
  'unknown: not polled this tick, holding last verdict (exhausted until 2026-09-04T14:11:51Z)' \
  "$(jq -r '.quota.reason' <<<"$hb")"
check 'a held verdict carries no limits to misread' '[]' \
  "$(jq -c '.quota.limits' <<<"$hb")"

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
# the caller's provider comes from its own house, not from the guard: a guard
# with nothing sampled (and a null builder_provider) still gets named the
# subscription this manager burns, with no reading attached to it
check 'quota.provider'    anthropic "$(jq -r '.quota.provider' <<<"$out")"
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

# a size: label that is not one of the four: the workflow file it names does not
# exist, so the launch is refused before anything is created
cat >"$fix/issue-8.json" <<'JSON'
{"number":8,"title":"Odd size","state":"OPEN","labels":[{"name":"size:xl"}],"body":""}
JSON
: >"$MGR_TEST_LOG"
err=$("$MGR" launch 8 --cap 3 2>&1 >/dev/null); rc=$?
check 'unknown size exit'       3 "$rc"
check 'unknown size code'       3 "$(jq -r '.error.code' <<<"$err")"
check 'unknown size message' true \
  "$(jq -r '.error.message | test("unknown size")' <<<"$err")"
check 'unknown size message names the four' true \
  "$(jq -r '.error.message | test("tiny\\|small\\|medium\\|large")' <<<"$err")"
check 'an unknown size created no tab' 0 \
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

printf '\n# 3d2. a limit the provider stopped reporting is news too\n'
export MGR_TEST_GUARD="$fix/guard-nudged.json"
out=$("$MGR" board --cap 3)
check 'gone limit: changed'    true "$(jq -r '.quota.changed' <<<"$out")"
check 'gone limit: delta' 'anthropic:opus 0.8× (gone)' \
  "$(jq -r '.quota.delta' <<<"$out")"
check 'the report is back to two limits' 2 "$(jq -r '.limits|length' "$report")"

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
check 'pause re-registers paused_by_operator' true \
  "$(jq -rs 'last|.paused_by_operator' "$MGR_TEST_REGISTER")"
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
cp "$MGR" "$root/bin/mgr-lib.sh" "$pkg/bin/"      # mgr plus the library it sources
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
check 'paths workflows' "$real_pkg/workflows" "$(jq -r '.workflows' <<<"$out")"
check 'paths omp'       "$real_pkg/omp"       "$(jq -r '.omp' <<<"$out")"
check 'paths keys' '["root","skill_md","builder_md","workflows","omp","mgr"]' \
  "$(jq -c 'keys_unsorted' <<<"$out")"
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

# a checkout without its library is an install defect, said as JSON
mkdir -p "$tmp/nolib/bin"
cp "$MGR" "$tmp/nolib/bin/mgr"
err=$("$tmp/nolib/bin/mgr" --version 2>&1 >/dev/null); rc=$?
check 'mgr without mgr-lib.sh exits 4' 4 "$rc"
check 'mgr without mgr-lib.sh says where it looked' true \
  "$(jq -r '.error.message | startswith("mgr-lib.sh not found at")' <<<"$err")"

# a checkout without package.json cannot answer --version
mkdir -p "$tmp/nopkg/bin"
cp "$MGR" "$root/bin/mgr-lib.sh" "$tmp/nopkg/bin/"
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

# ------------------------------------- 7b. package / setup / house

printf '\n# 7b. package and setup exec the sibling installer; house reads the session\n'
# the installer as shipped next to mgr: it echoes its argv and the MGR_ROOT it
# was handed, which is how it finds omp/ through a symlinked checkout
cat >"$pkg/bin/mgr-package" <<'EOF'
#!/usr/bin/env bash
printf '{"argv":"%s","root":"%s"}\n' "$*" "${MGR_ROOT:-}"
EOF
chmod +x "$pkg/bin/mgr-package"
check 'package execs the installer with the subcommand first' \
  "$(jq -nc --arg r "$real_pkg" '{argv:"package --list",root:$r}')" \
  "$("$link" package --list)"
check 'setup execs the same installer' \
  "$(jq -nc --arg r "$real_pkg" '{argv:"setup",root:$r}')" \
  "$("$link" setup)"
err=$("$tmp/nopkg/bin/mgr" package 2>&1 >/dev/null); rc=$?
check 'package without the installer exits 4' 4 "$rc"
check 'package without the installer says where it looked' true \
  "$(jq -r --arg p "$(cd "$tmp/nopkg" && pwd -P)/bin/mgr-package" \
     '.error.message == ("mgr-package not found at " + $p)' <<<"$err")"
err=$("$tmp/nopkg/bin/mgr" setup 2>&1 >/dev/null); rc=$?
check 'setup without the installer exits 4' 4 "$rc"
check 'usage lists mgr package' 1 "$("$MGR" --help | grep -c '^ *mgr package')"
check 'usage lists mgr setup'   1 "$("$MGR" --help | grep -c '^ *mgr setup')"
check 'usage lists mgr house'   1 "$("$MGR" --help | grep -c '^ *mgr house')"

# the manager's own pane, its session's last assistant message, its house
check 'house' '{"provider":"anthropic","model":"claude-fable-5-1","house":"anthropic"}' \
  "$("$MGR" house)"
check 'house without a pane is all nulls' '{"provider":null,"model":null,"house":null}' \
  "$(env -u HERDR_PANE_ID "$MGR" house)"
# with nothing configured, the manager's own session is what the board reports
# and what a launch would overlay
check 'board house from this session' anthropic \
  "$("$MGR" board --cap 3 | jq -r '.house')"
check 'MGR_HOUSE overrides it on the board' gemini \
  "$(MGR_HOUSE=gemini "$MGR" board --cap 3 | jq -r '.house')"
check 'house on a pane whose session has no assistant message' \
  '{"provider":null,"model":null,"house":null}' \
  "$(HERDR_PANE_ID=w9:p2 "$MGR" house)"
# every provider prefix the house map knows, and one it does not
msess_orig=$(cat "$msess")
for p in openai-codex:openai codex-cli:openai gemini-cli:gemini google-vertex:gemini \
         anthropic-bedrock:anthropic mistral:; do
  prov="${p%%:*}"; want="${p#*:}"
  jq -nc --arg prov "$prov" \
    '{type:"message",timestamp:"2026-09-04T11:59:30Z",
      message:{role:"assistant",provider:$prov,model:"m"}}' >"$msess"
  check "house maps $prov" \
    "$(jq -nc --arg prov "$prov" --arg w "$want" \
       '{provider:$prov,model:"m",house:(if $w=="" then null else $w end)}')" \
    "$("$MGR" house)"
done
printf '%s\n' "$msess_orig" >"$msess"
check 'house usage' 'usage: mgr house' \
  "$(jq -r '.error.message' <<<"$("$MGR" house extra 2>&1 >/dev/null)")"

# ------------------------------------- 8. the per-command manager heartbeat

printf '\n# 8. every command stamps the manager heartbeat before it dispatches\n'
export MGR_TEST_STALL="$tmp/no-stall.json"   # absent -> nothing is stalled
export MGR_TEST_ON_RESUME=
: >"$MGR_TEST_LOG"
"$MGR" board --cap 3 >/dev/null
# the board asks the guard for the overview it embeds, after its own status read
check 'board touches before its own guard calls' 'touch status overview register' \
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

# --------------------------------------- 9. the overview: machine-wide record,
#                                            caller-scoped block

# These cases run against the REAL mgr-guard: the projection is the thing under
# test, so a fake would prove nothing. The clock is pinned and the workspace and
# pane are unset, so `mgr` never touches or re-registers anything and the
# hand-written ledger is read exactly as written. TZ unset is the deterministic
# rendering (UTC with a Z suffix); the TZ case only proves the suffix rule,
# since the local zone of the machine running the test is not ours to pick.
# OV_HOUSE is which manager is asking — anthropic unless a case says otherwise,
# and empty for a caller whose house nothing can name.
[ -x "$real_guard" ] || { printf 'not executable: %s\n' "$real_guard" >&2; exit 1; }

ov() { # ov <state-dir> [args...] — mgr overview on the real guard, pinned clock
  local dir="$1"; shift
  env -u HERDR_WORKSPACE_ID -u HERDR_PANE_ID -u TZ \
    MGR_GUARD_BIN="$real_guard" MGR_STATE_DIR="$dir" MGR_GUARD_NOW_MS="$pin" \
    MGR_HOUSE="${OV_HOUSE-anthropic}" \
    "$MGR" overview "$@"
}

nextlines() { # the continuation lines of the `next` block, one per line
  printf '%s\n' "$1" | sed -n 's/^         //p'
}

printf '\n# 9. mgr overview --json: burn, backlog and the projected timeline\n'
ovj=$(ov "$ovstate" --json); rc=$?
check 'overview exit'             0 "$rc"
check 'stdout is one json doc'    1 "$(jq -s 'length' <<<"$ovj")"
check 'overview keys' '["at","burn","backlog","timeline"]' \
  "$(jq -c 'keys_unsorted' <<<"$ovj")"
check 'at is the pinned clock' "$pin" "$(jq -r '.at' <<<"$ovj")"
# the 5h limit does not fit: it runs out 30 min in and the window closes at the
# reset — every projected minute after that has to step over it
check 'stall_window' \
  "{\"from\":$((pin + 1800000)),\"to\":$((pin + 7200000)),\"limit\":\"anthropic:5h\"}" \
  "$(jq -c '.burn.stall_window' <<<"$ovj")"
check 'exhaust_at of the limit that does not fit' $((pin + 1800000)) \
  "$(jq -r '.burn.limits[0].exhaust_at' <<<"$ovj")"
check 'a limit that fits never exhausts' null \
  "$(jq -r '.burn.limits[1].exhaust_at' <<<"$ovj")"
check 'backlog.totals' \
  '{"ready":10,"blocked":2,"in_flight":1,"awaiting_approval":0,"cap":3,"idle_slots":1,"open":13}' \
  "$(jq -c '.backlog.totals' <<<"$ovj")"
# the dead manager is in the ledger and in nothing else
check 'only live managers participate' \
  '["other/shape","owner/name","zed/paused"]' \
  "$(jq -c '[.backlog.managers[].repo]' <<<"$ovj")"
# each row names the subscription that manager burns, so a mixed fleet can be
# attributed without guessing from the repo
check 'every manager row carries its own provider' \
  'other/shape=anthropic owner/name=anthropic zed/paused=openai-codex' \
  "$(jq -r '[.backlog.managers[] | "\(.repo)=\(.provider)"] | join(" ")' <<<"$ovj")"
# --json is the machine-wide record: nothing here is scoped to the caller, so
# every provider the guard sampled is still in it
check 'the record carries every sampled provider' '["anthropic","openai-codex"]' \
  "$(jq -c '[.burn.limits[].provider] | unique' <<<"$ovj")"
check 'and every sampled limit' \
  '["anthropic:5h","anthropic:week","openai-codex:5h"]' \
  "$(jq -c '[.burn.limits[].id] | sort' <<<"$ovj")"
# ... and it is the guard's own document, not a re-rendering of it
check 'mgr overview --json is the guard overview verbatim' \
  "$(env MGR_STATE_DIR="$ovstate" MGR_GUARD_NOW_MS="$pin" \
     "$real_guard" overview --limit 10 | jq -c .)" \
  "$ovj"
check 'a manager with free slots and nothing ready starves now' \
  "true/$pin" \
  "$(jq -r '.backlog.managers[0] | "\(.starving)/\(.starves_at)"' <<<"$ovj")"
check 'a manager with a queue starves when the queue runs out' \
  "false/$((pin + 24300000))" \
  "$(jq -r '.backlog.managers[1] | "\(.starving)/\(.starves_at)"' <<<"$ovj")"
check 'per-manager drain times' "$((pin + 1500000))/$((pin + 27000000))" \
  "$(jq -r '[.backlog.managers[].backlog_drains_at] | "\(.[0])/\(.[1])"' <<<"$ovj")"
check 'machine-wide drains_at is the last of them' $((pin + 27000000)) \
  "$(jq -r '.timeline.drains_at' <<<"$ovj")"
check 'last_eta matches drains_at' true \
  "$(jq -r '.timeline.last_eta == .timeline.drains_at' <<<"$ovj")"
# elapsed + a quarter median beats the median itself for #49: it has been
# running 45 min against a 1h measurement, so it lands 15 min from now
check 'in-flight eta' "in_flight/$((pin + 900000))" \
  "$(jq -r '.timeline.shown[0] | "\(.state)/\(.eta)"' <<<"$ovj")"
check 'the first queued issue is the other repo' 'other/shape/101/blocked/[999]' \
  "$(jq -r '.timeline.shown[1] | "\(.repo)/\(.number)/\(.state)/\(.blocked_by|tostring)"' <<<"$ovj")"
# #7 starts now, but an hour of work over a window that opens in 30 min lands
# 30 min past the reset
check 'work time steps over the stall window' $((pin + 9000000)) \
  "$(jq -r '[.timeline.shown[] | select(.number == 7) | .eta][0]' <<<"$ovj")"
check 'shown is every in-flight issue plus the limit' 11 \
  "$(jq -r '.timeline.shown | length' <<<"$ovj")"
check 'beyond summarises the rest' \
  "{\"count\":2,\"blocked\":1,\"last_eta\":$((pin + 27000000)),\"drains_at\":$((pin + 27000000))}" \
  "$(jq -c '.timeline.beyond' <<<"$ovj")"

printf '\n# 9b. the rendered block, byte for byte\n'
# The anthropic manager's own view. `quota` is its subscription alone — the
# openai-codex limit the guard also sampled has no business here — and the
# `shared with` count is the other projects on *that* subscription, so
# `other/shape` counts and `zed/paused` (openai-codex) does not. `work` and
# `next` are this repo's alone: `other/shape` owns issue #101 and a drain time
# of its own, and neither may appear anywhere in the text.
cat >"$fix/expect-overview.txt" <<'EOF'
quota    5-hour 80% used, runs out in ~30m, resets in 2h00 (14:00Z) · weekly 20% used · shared with 1 other project
work     1 of 2 builders running, 10 ready, 1 blocked · out of work in 6h45 (18:45Z) · queue clear in 7h30 (19:30Z)
next     #49 running, 15m left · #7 in 2h30 (after the 5-hour reset) · #8 in 2h45 · #9 in 3h30 · #10 in 3h45
         #11 in 4h30 · #12 in 4h45 · #13 in 5h30 · #14 in 5h45 · #15 in 6h30 · +2 more
EOF
blk=$(ov "$ovstate"); rc=$?
check 'overview exit'             0 "$rc"
check 'the rendered block' "$(cat "$fix/expect-overview.txt")" "$blk"
check 'four lines, no trailing blank' 4 "$(printf '%s\n' "$blk" | wc -l | tr -d ' ')"
check 'every line starts with its padded label' \
  'quota    |work     |next     |         |' \
  "$(printf '%s\n' "$blk" | cut -c1-9 | sed 's/$/|/' | tr -d '\n')"
check 'no line is wider than 120 columns' 0 \
  "$(printf '%s\n' "$blk" | jq -R 'select(length > 120)' | wc -l | tr -d ' ')"
check 'the other manager explains the shared quota and nothing else' 1 \
  "$(printf '%s\n' "$blk" | grep -c 'shared with 1 other project' || true)"
check 'no other repo, issue or drain time in the text' 0 \
  "$(printf '%s\n' "$blk" | grep -c -e shape -e '#101' -e '#999' -e '12:25' || true)"
check 'none of the old notation either' 0 \
  "$(printf '%s\n' "$blk" | grep -c -e '×' -e '⊘' -e '/h' -e '—' || true)"
check 'the caller sees no other subscription in its quota line' 0 \
  "$(printf '%s\n' "$blk" | sed -n '/^quota/p' \
     | grep -c -e '30% used' -e codex || true)"

printf '\n# 9b2. the same ledger, read by a manager on the other subscription\n'
# same machine, same repo, different house: only the limit its own package
# burns, and only the projects sharing that one
blko=$(OV_HOUSE=openai ov "$ovstate")
check 'the openai quota line is its own limit alone' \
  'quota    5-hour 30% used, on pace until reset in 2h00 (14:00Z) · shared with 1 other project' \
  "$(printf '%s\n' "$blko" | sed -n '/^quota/p')"
check "and none of anthropic's numbers" 0 \
  "$(printf '%s\n' "$blko" | sed -n '/^quota/p' \
     | grep -c -e '80% used' -e '20% used' -e 'runs out' || true)"
# work/next are repo-scoped, not provider-scoped: the same repo, so unchanged
check 'work and next are untouched by the house' \
  "$(printf '%s\n' "$blk" | sed -n '/^quota/!p')" \
  "$(printf '%s\n' "$blko" | sed -n '/^quota/!p')"

# a house the guard has not sampled: the honest answer is that there is no
# reading for this manager, never the numbers of a subscription it cannot spend
blkg=$(OV_HOUSE=gemini ov "$ovstate")
check 'an unsampled provider gets the no-reading line, verbatim' \
  'quota    no quota reading yet' \
  "$(printf '%s\n' "$blkg" | sed -n '/^quota/p')"
check 'and no percentage from anyone else' 0 \
  "$(printf '%s\n' "$blkg" | sed -n '/^quota/p' | grep -c '% used' || true)"
check 'the rest of the block still renders' \
  "$(printf '%s\n' "$blk" | sed -n '/^quota/!p')" \
  "$(printf '%s\n' "$blkg" | sed -n '/^quota/!p')"

# and a caller whose house nothing can name — no pane, nothing configured. It
# is not a manager on any subscription, and the readings do exist, so it keeps
# the machine-wide line (documented fallback) rather than being told there is
# nothing to see. Every sampled limit is on it, worst first, and at this width
# the `shared with` tail no longer fits — the pre-existing wrapping rule, and
# the reason two indistinguishable `5-hour` entries are a fallback and not the
# manager's view.
blkn=$(OV_HOUSE='' ov "$ovstate")
check 'an unresolvable caller keeps the unfiltered line' \
  'quota    5-hour 80% used, runs out in ~30m, resets in 2h00 (14:00Z) · 5-hour 30% used · weekly 20% used' \
  "$(printf '%s\n' "$blkn" | sed -n '/^quota/p')"
check 'which is every provider the guard sampled' 2 \
  "$(printf '%s\n' "$blkn" | sed -n '/^quota/p' | grep -o '5-hour' | wc -l | tr -d ' ')"
check 'and still inside 120 columns' 0 \
  "$(printf '%s\n' "$blkn" | jq -R 'select(length > 120)' | wc -l | tr -d ' ')"

printf '\n# 9b3. a stall on a subscription this manager cannot spend on\n'
# The whole point of a per-provider window. On `ovforeign` the openai-codex 5h
# limit is the machine's only stalling limit; `owner/name` burns anthropic, so
# that window is not a wait it can ever serve — the reset is not its reset and
# the minutes lost to it are not its minutes. Its block must therefore read
# exactly as it does on `ovnostall`, where nothing stalls at all: same ETAs,
# and no reset named anywhere. (Before the per-provider window the machine-wide
# one drove every simulation: this same block read `out of work in 6h45` and
# `#7 in 2h30 (after the 5-hour reset)` — the foreign limit's 90 minutes and
# the foreign limit's name, on an anthropic manager's screen.)
blkq=$(ov "$ovnostall"); rc=$?
check 'control overview exit'     0 "$rc"
blkf=$(ov "$ovforeign"); rc=$?
check 'overview exit with a foreign stall' 0 "$rc"
check "a foreign stall leaves the caller's block byte-identical" "$blkq" "$blkf"
# ... and identical to a block that is itself unstalled, spelled out, so the
# pair cannot pass by being bent the same wrong way twice
check 'which is the unstalled projection' \
  'next     #49 running, 15m left · #7 in 1h00 · #8 in 1h15 · #9 in 2h00 · #10 in 2h15 · #11 in 3h00 · #12 in 3h15' \
  "$(printf '%s\n' "$blkf" | sed -n '/^next/p')"
check 'and its unstalled work line' \
  'work     1 of 2 builders running, 10 ready, 1 blocked · out of work in 5h15 (17:15Z) · queue clear in 6h00 (18:00Z)' \
  "$(printf '%s\n' "$blkf" | sed -n '/^work/p')"
check "no reset the caller cannot wait out is named" 0 \
  "$(printf '%s\n' "$blkf" | grep -c 'after the' || true)"
check "and the foreign limit is nowhere in the block" 0 \
  "$(printf '%s\n' "$blkf" | grep -c -e 'runs out' -e codex || true)"

# the same ledger read by an openai house: the quota line is that
# subscription's, because that is what the caller burns — but `work` and `next`
# stay the registered row's, which is still on anthropic. The window follows the
# registration, never the env.
blkfo=$(OV_HOUSE=openai ov "$ovforeign")
check "the openai house reads its own limit running out" \
  'quota    5-hour 80% used, runs out in ~30m, resets in 2h00 (14:00Z) · shared with 1 other project' \
  "$(printf '%s\n' "$blkfo" | sed -n '/^quota/p')"
check 'while the rows keep the projection of the provider they registered' \
  "$(printf '%s\n' "$blkf" | sed -n '/^quota/!p')" \
  "$(printf '%s\n' "$blkfo" | sed -n '/^quota/!p')"

# and the same stall on the ledger where this repo's manager *is* the one
# burning openai-codex: the window reaches the manager it belongs to, so the
# ETAs step over it and the reset is named. Nothing is being suppressed.
blkc=$(OV_HOUSE=openai ov "$ovcodex")
check 'the manager that owns the stall reads it on its quota line' \
  'quota    5-hour 80% used, runs out in ~30m, resets in 2h00 (14:00Z) · shared with 1 other project' \
  "$(printf '%s\n' "$blkc" | sed -n '/^quota/p')"
check 'and its next line names the reset it is waiting for' 1 \
  "$(printf '%s\n' "$blkc" | grep -c '#7 in 2h30 (after the 5-hour reset)' || true)"
# the window is the same 30-min-to-14:00Z shape the anthropic ledger holds, so
# the projection it produces must be the same to the byte — a stall costs the
# manager it binds exactly as much, whichever subscription it sits on
check 'the stalled projection matches the anthropic one, minute for minute' \
  "$(printf '%s\n' "$blk" | sed -n '/^quota/!p')" \
  "$(printf '%s\n' "$blkc" | sed -n '/^quota/!p')"

# the record stays machine-wide: `burn.stall_window` is the earliest-exhausting
# limit on the machine whoever asks, and each manager row carries the window of
# its own provider beside it
ovjf=$(ov "$ovforeign" --json)
check 'burn.stall_window is still the machine-wide earliest' \
  "{\"from\":$((pin + 1800000)),\"to\":$((pin + 7200000)),\"limit\":\"openai-codex:5h\"}" \
  "$(jq -c '.burn.stall_window' <<<"$ovjf")"
check "and it names a limit no anthropic manager's row does" \
  'other/shape=anthropic/null owner/name=anthropic/null zed/paused=openai-codex/openai-codex:5h' \
  "$(jq -r '[.backlog.managers[]
             | "\(.repo)=\(.provider)/\(if .stall_window == null then "null" else .stall_window.limit end)"]
            | join(" ")' <<<"$ovjf")"
check "the row that does carries the window itself" \
  "{\"from\":$((pin + 1800000)),\"to\":$((pin + 7200000)),\"limit\":\"openai-codex:5h\"}" \
  "$(jq -c '.backlog.managers[] | select(.repo == "zed/paused") | .stall_window' <<<"$ovjf")"
check 'stall_window sits right after the provider it belongs to' 'provider,stall_window' \
  "$(jq -r '.backlog.managers[0] | keys_unsorted as $k
            | ($k | index("provider")) as $i | $k[$i:$i+2] | join(",")' <<<"$ovjf")"
# the rule points the other way on the ledger where anthropic is the one
# stalling: same document, opposite attribution
check 'each row gets its own provider window on the anthropic-stalling ledger' \
  'other/shape=anthropic:5h owner/name=anthropic:5h zed/paused=null' \
  "$(jq -r '[.backlog.managers[]
             | "\(.repo)=\(if .stall_window == null then "null" else .stall_window.limit end)"]
            | join(" ")' <<<"$ovj")"
# and a machine with no stalling limit at all has no window to hand anyone
check 'no stalling limit, no window anywhere (key present, value null)' 'true true' \
  "$(ov "$ovnostall" --json \
     | jq -r '(.burn | has("stall_window") and .stall_window == null) as $b
              | ([.backlog.managers[]
                  | has("stall_window") and .stall_window == null] | all) as $m
              | "\($b) \($m)"')"

printf '\n# 9c. Z only when TZ is unset\n'
blktz=$(env -u HERDR_WORKSPACE_ID -u HERDR_PANE_ID TZ=UTC \
  MGR_GUARD_BIN="$real_guard" MGR_STATE_DIR="$ovstate" MGR_GUARD_NOW_MS="$pin" \
  MGR_HOUSE=anthropic "$MGR" overview)
check 'a set TZ drops the Z suffix' 0 \
  "$(printf '%s\n' "$blktz" | grep -c '[0-9][0-9]:[0-9][0-9]Z' || true)"
check 'an unset TZ keeps it' 1 \
  "$(printf '%s\n' "$blk" | grep -c 'resets in 2h00 (14:00Z)' || true)"
check 'the same three labelled lines in either zone' 'quota|work|next' \
  "$(printf '%s\n' "$blktz" | sed -n 's/^\([a-z][a-z]*\) .*/\1/p' | tr '\n' '|' \
     | sed 's/|$//')"

printf '\n# 9d. --limit 3: three queued shown, the rest counted\n'
ovj3=$(ov "$ovstate" --json --limit 3)
check 'shown is the in-flight issue plus three' 4 \
  "$(jq -r '.timeline.shown | length' <<<"$ovj3")"
check 'beyond counts every hidden issue' 9 \
  "$(jq -r '.timeline.beyond.count' <<<"$ovj3")"
check 'and how many of those are blocked' 1 \
  "$(jq -r '.timeline.beyond.blocked' <<<"$ovj3")"
# the machine-wide cap is applied before the text is filtered to this repo, so
# the sibling project eats one of the three slots; `+N more` still counts this
# repo's own remainder — all eleven of its queued issues less the two listed
blk3=$(ov "$ovstate" --limit 3)
check 'the next line, capped and counted' \
  'next     #49 running, 15m left · #7 in 2h30 (after the 5-hour reset) · #8 in 2h45 · +9 more' \
  "$(printf '%s\n' "$blk3" | sed -n '/^next/p')"
check 'three lines at this limit' 3 "$(printf '%s\n' "$blk3" | wc -l | tr -d ' ')"

printf '\n# 9e. a short queue: everything listed, nothing left to count\n'
ovjs=$(ov "$ovsmall" --json)
check 'beyond is null' null "$(jq -r '.timeline.beyond' <<<"$ovjs")"
check 'shown is the whole machine' 5 "$(jq -r '.timeline.shown | length' <<<"$ovjs")"
blks=$(ov "$ovsmall")
check 'three lines, no continuation' 3 "$(printf '%s\n' "$blks" | wc -l | tr -d ' ')"
check 'no remainder marker' 0 "$(printf '%s\n' "$blks" | grep -c 'more' || true)"
check 'a blocked issue names its blocker in words' 1 \
  "$(printf '%s\n' "$blks" | grep -c '#17 in 3h30 (needs #7)' || true)"

printf '\n# 9f. a queue too long for two lines ends in a count\n'
blkm=$(ov "$ovmany" --limit 30)
check 'next spills onto exactly one continuation line' 1 \
  "$(nextlines "$blkm" | wc -l | tr -d ' ')"
check 'the continuation ends with the remainder' 1 \
  "$(nextlines "$blkm" | grep -c ' · +24 more$' || true)"
check 'four lines at most' 4 "$(printf '%s\n' "$blkm" | wc -l | tr -d ' ')"
check 'and still nothing over 120 columns' 0 \
  "$(printf '%s\n' "$blkm" | jq -R 'select(length > 120)' | wc -l | tr -d ' ')"

printf '\n# 9g. mgr board embeds the very same document\n'
ovb=$(env -u HERDR_WORKSPACE_ID -u HERDR_PANE_ID -u TZ \
  MGR_GUARD_BIN="$real_guard" MGR_STATE_DIR="$ovstate" MGR_GUARD_NOW_MS="$pin" \
  "$MGR" board --cap 3 | jq -c '.overview')
check 'board.overview equals mgr overview --json' "$ovj" "$ovb"

printf '\n# 9h. usage, validation, and a guard that cannot answer\n'
err=$(ov "$ovstate" --limit x 2>&1 >/dev/null); rc=$?
check 'a bad limit exits 2'       2 "$rc"
check 'a bad limit says why' 'limit must be a non-negative integer: x' \
  "$(jq -r '.error.message' <<<"$err")"
err=$(ov "$ovstate" --bogus 2>&1 >/dev/null); rc=$?
check 'an unknown flag exits 2'   2 "$rc"
check 'overview usage message' 'usage: mgr overview [--json] [--limit N]' \
  "$(jq -r '.error.message' <<<"$err")"
err=$("$MGR" overview 2>&1 >/dev/null); rc=$?
check 'no guard answer exits 1'   1 "$rc"
check 'and says which call failed' 'mgr-guard overview failed' \
  "$(jq -r '.error.message' <<<"$err")"
check 'usage lists overview' 1 \
  "$("$MGR" --help | grep -c 'mgr overview \[--json\] \[--limit N\]')"
check 'usage lists MGR_GUARD_BACKLOG_INTERVAL_S' 1 \
  "$("$MGR" --help | grep -c 'MGR_GUARD_BACKLOG_INTERVAL_S')"
check 'usage lists MGR_DEFAULT_TASK_S' 1 \
  "$("$MGR" --help | grep -c 'MGR_DEFAULT_TASK_S')"

printf '\n# 9i. a machine with no ledger at all still answers\n'
mkdir -p "$tmp/ovempty"
blke=$(ov "$tmp/ovempty"); rc=$?
check 'empty overview exit'       0 "$rc"
check 'the empty block' \
  'quota    no quota reading yet|work     this repo is not registered with the guard' \
  "$(printf '%s\n' "$blke" | tr '\n' '|' | sed 's/|$//')"

printf '\n# 9j. this repo idle: one plain line, and no next line at all\n'
blki=$(ov "$ovidle")
check 'two lines' 2 "$(printf '%s\n' "$blki" | wc -l | tr -d ' ')"
check 'the work line says it plainly' 'work     nothing running, nothing queued' \
  "$(printf '%s\n' "$blki" | sed -n '/^work/p')"
check 'no placeholder dashes anywhere' 0 \
  "$(printf '%s\n' "$blki" | grep -c '—' || true)"
check 'the shared quota is still reported' 1 \
  "$(printf '%s\n' "$blki" | grep -c 'shared with 1 other project' || true)"

printf '\n# 9k. a held verdict never renders as a stale percentage\n'
# the daemon could not poll anthropic this tick and is holding an exhausted
# verdict with no limits at all; the manager on it must see the plain
# no-reading sentence, not zero usage read out of an empty list
blkh=$(ov "$ovheld")
check 'a held verdict renders as no quota reading, verbatim' \
  'quota    no quota reading yet' \
  "$(printf '%s\n' "$blkh" | sed -n '/^quota/p')"
check 'and never a percentage of any kind' 0 \
  "$(printf '%s\n' "$blkh" | sed -n '/^quota/p' | grep -c '% used' || true)"

# ------------------------------- 10. launch stamps and throughput rows

printf '\n# 10. a stamp per builder, a throughput row per merged issue\n'
launches="$tmp/state/launches/owner__name.json"
thru="$tmp/state/throughput/owner__name.jsonl"
out=$(HERDR_PANE_ID=w9:p2 HERDR_TAB_ID=w9:t2 MGR_GUARD_NOW_MS="$pin" \
  "$MGR" bind 7 2>/dev/null); rc=$?
check 'bind exit'                 0 "$rc"
check 'bind number'              7 "$(jq -r '.number' <<<"$out")"
check 'the launch stamp landed' "7/$pin/small" \
  "$(jq -r '."7" | "\(.number)/\(.launched_at)/\(.launched_size)"' "$launches")"

# issue 7 is resized after launch: the label at retire reads medium, and the
# record must keep the small it was launched as beside it
cat >"$fix/issue-7.json" <<'EOF'
{"number":7,"title":"Another thing","state":"OPEN","labels":[{"name":"size:medium"}],"body":""}
EOF

# issue 7 goes live only now; §10b below binds 7 again with this agent live,
# which is safe only because the injected pane_id (w9:p2) equals
# HERDR_PANE_ID, so cmd_bind's already-live gate is a no-op.
# The PR mergedAt lands 1h after the report comment's own createdAt, so
# asserting merged_at_source=="pr" can never be satisfied by the comment
# fallback path by accident.
jq --arg cwd "$repo" --arg sess "$bsess" \
  '.result.agents += [{name:"issue-7",pane_id:"w9:p2",tab_id:"w9:t2",workspace_id:"w9",cwd:$cwd,
     agent:"omp",agent_status:"blocked",agent_session:{value:$sess}}]' \
  "$fix/agents.json" >"$fix/agents.json.next" && mv "$fix/agents.json.next" "$fix/agents.json"
date -u -r $((pin / 1000 + 7200)) +%Y-%m-%dT%H:%M:%SZ >"$fix/pr-mergedat.txt"

: >"$MGR_TEST_LOG"
out=$(MGR_GUARD_NOW_MS="$pin" "$MGR" retire 7 2>/dev/null); rc=$?
check 'retire exit #7'               0 "$rc"
check 'retire reports the row #7'  true "$(jq -r '.throughput_appended' <<<"$out")"
check 'execution recorded #7'      true "$(jq -r '.execution_recorded' <<<"$out")"
row=$(jq -sc '.[0]' "$thru")
assert_jq 'the five original ledger keys, measured from the PR mergedAt' "$row" \
  "{repo,number,launched_at,merged_at,duration_s} == {repo:\"owner/name\",number:7,launched_at:$pin,merged_at:$((pin + 7200000)),duration_s:7200}"
check 'exactly one row'           1 "$(jq -s 'length' "$thru")"
check 'the stamp was consumed'   '{}' "$(jq -c '.' "$launches")"

assert_jq 'merged_at came from the pr, not the comment' "$row" '.merged_at_source == "pr"'
assert_jq 'schema is 1'                                 "$row" '.schema == 1'
assert_jq 'size from the size: label at retire'         "$row" '.size == "medium"'
assert_jq 'launched_size from the launch stamp'         "$row" '.launched_size == "small"'
assert_jq 'pr from the report'                          "$row" '.pr == "https://github.com/owner/name/pull/70"'
assert_jq 'sha from the report'                         "$row" '.sha == "abc"'
assert_jq 'report.review'                               "$row" '.report.review == "sweep"'
assert_jq 'report.review_verdict'                       "$row" '.report.review_verdict == "2 fixed"'
assert_jq 'report.checks'                               "$row" '.report.checks == ["run.sh","shellcheck"]'
assert_jq 'report.escalations'                          "$row" '.report.escalations == 0'
assert_jq 'report.pre_existing_red'                     "$row" '.report.pre_existing_red == 1'
assert_jq 'report.final_size'                           "$row" '.report.final_size == "medium"'
assert_jq 'session.read'                                "$row" '.session.read == true'
assert_jq 'session.turns'                               "$row" '.session.turns == 3'
assert_jq 'session.tokens'                              "$row" \
  '.session.tokens == {input:600,output:60,cache_read:15,cache_write:3,total:678}'
assert_jq 'session.cost_usd'                            "$row" '(.session.cost_usd - 0.6 | fabs) < 1e-9'
assert_jq 'session.models'                              "$row" \
  '.session.models == {"claude-fable-5-1":2,"claude-smol":1}'
assert_jq 'session.stop_reasons'                        "$row" '.session.stop_reasons == {end_turn:2,error:1}'
assert_jq 'session.rate_limit_hits'                     "$row" '.session.rate_limit_hits == 1'
assert_jq 'session.model_changes'                       "$row" '.session.model_changes == 1'
assert_jq 'session.resizes'                             "$row" '.session.resizes == 1'
assert_jq 'session.subagents'                           "$row" \
  '.session.subagents == {count:3,agents:{scout:2,sketch:1},roles:{scout:2,sketch:1},models:{"anthropic/claude-x":3}}'
assert_jq 'report.delegated_planning'                   "$row" '.report.delegated_planning == "sketch"'
assert_jq 'session.active_ms'                           "$row" '.session.active_ms == 600'

comment_line=$(grep -n '^gh issue comment 7 --body-file' "$MGR_TEST_LOG" | head -1 | cut -d: -f1)
label_line=$(grep -n '^gh issue edit 7 --remove-label' "$MGR_TEST_LOG" | head -1 | cut -d: -f1)
check 'the execution comment posted'      1 "$([ -n "$comment_line" ] && printf 1 || printf 0)"
check 'posted before the labels came off' true \
  "$([ -n "$comment_line" ] && [ -n "$label_line" ] && [ "$comment_line" -lt "$label_line" ] && printf true || printf false)"

comment7="$MGR_TEST_FIX/comment-7.md"
check 'comment-7 header line' \
  'execution: #7 · small→medium · 7200s · 3 turns · 678 tokens · $0.6 · review sweep/2 fixed · merged_at from pr' \
  "$(sed -n '1p' "$comment7")"
assert_jq 'comment-7 fenced json equals the ledger row' \
  "$(sed -n '/^```json$/,/^```$/p' "$comment7" | sed '1d;$d' | jq -Sc .)" \
  ". == $(jq -Sc . <<<"$row")"

# a builder that never reported merged: the stamp is dropped, no row is written
HERDR_PANE_ID=w9:p2 HERDR_TAB_ID=w9:t2 MGR_GUARD_NOW_MS="$pin" \
  "$MGR" bind 49 >/dev/null 2>&1
check 'the stamp for #49 landed' "$pin/medium" \
  "$(jq -r '."49" | "\(.launched_at)/\(.launched_size)"' "$launches")"
out=$(MGR_GUARD_NOW_MS="$pin" "$MGR" retire 49 2>/dev/null)
check 'no report, no row'       false "$(jq -r '.throughput_appended' <<<"$out")"
check 'the stamp is dropped anyway' '{}' "$(jq -c '.' "$launches")"
check 'the throughput file is untouched' 1 "$(jq -s 'length' "$thru")"

# a bind on an issue with no usable size: label (issue 8 carries size:xl)
# stamps the moment and a null size — never a guessed one
HERDR_PANE_ID=w9:p2 HERDR_TAB_ID=w9:t2 MGR_GUARD_NOW_MS="$pin" \
  "$MGR" bind 8 >/dev/null 2>&1
check 'an unusable size: label stamps null' "$pin/null" \
  "$(jq -r '."8" | "\(.launched_at)/\(.launched_size)"' "$launches")"
rm -f "$launches"

# a second retire of the same landing (same number and sha) is a no-op
out=$(MGR_GUARD_NOW_MS="$pin" "$MGR" retire 7 2>/dev/null)
check 'a second retire appends nothing #7' false "$(jq -r '.throughput_appended' <<<"$out")"
check 'a second retire posts nothing #7'   false "$(jq -r '.execution_recorded' <<<"$out")"
check 'still one row #7'                   1     "$(jq -s 'length' "$thru")"

printf '\n# 10a. an adopted builder gets a record too: no stamp, no pr, unreadable session\n'
rm -f "$fix/pr-mergedat.txt"
# issue 9 goes live only now: its builder session pointer names a file that is
# never created, so the record must degrade to session.read=false, never skip
# the row. Adding it earlier would change every in_flight count above.
jq --arg cwd "$repo" --arg missing "$tmp/session-9-missing.jsonl" \
  '.result.agents += [{name:"issue-9",pane_id:"w9:p4",tab_id:"w9:t4",workspace_id:"w9",cwd:$cwd,
     agent:"omp",agent_status:"blocked",agent_session:{value:$missing}}]' \
  "$fix/agents.json" >"$fix/agents.json.next" && mv "$fix/agents.json.next" "$fix/agents.json"
out=$(MGR_GUARD_NOW_MS="$pin" "$MGR" retire 9 2>/dev/null); rc=$?
check 'retire exit #9'               0 "$rc"
check 'retire reports the row #9'  true "$(jq -r '.throughput_appended' <<<"$out")"
check 'execution recorded #9'      true "$(jq -r '.execution_recorded' <<<"$out")"
row9=$(jq -sc '.[-1]' "$thru")
assert_jq 'no launch stamp -> launched_at is null'            "$row9" '.launched_at == null'
assert_jq 'no launch stamp -> launched_size is null'          "$row9" '.launched_size == null'
assert_jq 'no launch stamp -> duration_s is null'             "$row9" '.duration_s == null'
assert_jq 'no pr reading -> merged_at came from the comment'  "$row9" '.merged_at_source == "comment"'
assert_jq 'the report still comes through for an adoptee'     "$row9" '.report.review == "none"'
# issue-9's agent_session.value names a file that was never created: this
# folds the "unreadable session" case in alongside the adoptee/comment-
# fallback one — the record degrades to session.read=false, never skips.
assert_jq 'unreadable session: read is false'                 "$row9" '.session.read == false'
assert_jq 'unreadable session: turns is null'                 "$row9" '.session.turns == null'
assert_jq 'unreadable session: subagent count is null'        "$row9" '.session.subagents.count == null'

comment9="$MGR_TEST_FIX/comment-9.md"
check 'comment-9 header line' \
  'execution: #9 · ?→small · ?s · ? turns · ? tokens · $? · review none/skipped · merged_at from comment' \
  "$(sed -n '1p' "$comment9")"
assert_jq 'comment-9 fenced json equals the ledger row' \
  "$(sed -n '/^```json$/,/^```$/p' "$comment9" | sed '1d;$d' | jq -Sc .)" \
  ". == $(jq -Sc . <<<"$row9")"

# a stamp written before launched_size existed ({number, launched_at} only)
# keeps its launched_at and reads launched_size as null: a fresh sha so the
# ledger's dedupe lets the row through
sed 's/sha=def/sha=ghi/' "$fix/comments-9.json" >"$fix/comments-9.json.next" \
  && mv "$fix/comments-9.json.next" "$fix/comments-9.json"
jq -nc --argjson at "$pin" '{"9":{number:9,launched_at:$at}}' >"$launches"
out=$(MGR_GUARD_NOW_MS="$pin" "$MGR" retire 9 2>/dev/null)
check 'retire reports the row #9 (legacy stamp)' true "$(jq -r '.throughput_appended' <<<"$out")"
row9l=$(jq -sc '.[-1]' "$thru")
assert_jq 'legacy stamp -> launched_at kept'      "$row9l" ".launched_at == $pin"
assert_jq 'legacy stamp -> duration_s measured'   "$row9l" '.duration_s == 10800'
assert_jq 'legacy stamp -> launched_size is null' "$row9l" '.launched_size == null'
check 'comment-9 header line (legacy stamp)' \
  'execution: #9 · ?→small · 10800s · ? turns · ? tokens · $? · review none/skipped · merged_at from comment' \
  "$(sed -n '1p' "$comment9")"
check 'the legacy stamp was consumed' '{}' "$(jq -c '.' "$launches")"

# ---------------------------- 10b. two builders binding at the same time

printf '\n# 10b. concurrent stamps: the launches file is locked, not clobbered\n'
rm -f "$launches"
HERDR_PANE_ID=w9:p2 HERDR_TAB_ID=w9:t2 MGR_GUARD_NOW_MS="$pin" \
  "$MGR" bind 7 >/dev/null 2>&1 &
HERDR_PANE_ID=w9:p2 HERDR_TAB_ID=w9:t2 MGR_GUARD_NOW_MS="$pin" \
  "$MGR" bind 49 >/dev/null 2>&1 &
wait
check 'neither stamp was lost' '["49","7"]' "$(jq -c 'keys' "$launches")"
check 'both carry the pinned clock' "$pin/$pin" \
  "$(jq -r '"\(."7".launched_at)/\(."49".launched_at)"' "$launches")"
check 'the lock is released' 0 \
  "$([ -d "$tmp/state/launches/owner__name.lock" ] && printf 1 || printf 0)"

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'all checks passed\n'; exit 0; fi
printf '%d check(s) failed\n' "$fails"; exit 1
