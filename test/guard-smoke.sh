#!/usr/bin/env bash
# guard-smoke.sh — self-contained smoke test for bin/mgr-guard.
# Fakes `omp` and `herdr` on PATH, pins the clock with MGR_GUARD_NOW_MS and
# keeps every byte of state in a temp dir. Never touches the live herdr session.
# Exits non-zero if any assertion fails.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/bin/mgr-guard"
[ -x "$GUARD" ] || { printf 'guard-smoke: %s is not executable\n' "$GUARD" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/guard-smoke.XXXXXX")"
cleanup() {
  [ -n "${DAEMON_STATE:-}" ] && MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" stop >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

FAILURES=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
assert_eq() { # assert_eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1 = $3"; else fail "$1: expected [$2], got [$3]"; fi
}
assert_jq() { # assert_jq <label> <json> <filter>
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then pass "$1"; else fail "$1 (jq: $3)"; fi
}
assert_json() { # assert_json <label> <text>
  if printf '%s' "$2" | jq . >/dev/null 2>&1; then pass "$1 is valid JSON"; else fail "$1 is not valid JSON: $2"; fi
}

# ------------------------------------------------------------------ fakes

BIN="$TMP/bin"; mkdir -p "$BIN"

cat >"$BIN/omp" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  usage)
    shift
    if [ "${1:-}" = invalidate ]; then printf '{"invalidated":true}\n'; exit 0; fi
    prov=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --provider|-p) prov="${2:-}"; shift 2;;
        *) shift;;
      esac
    done
    if [ -z "${FAKE_USAGE:-}" ] || [ ! -f "${FAKE_USAGE:-}" ]; then
      printf 'fake omp: no usage fixture\n' >&2; exit 1
    fi
    if [ -n "$prov" ]; then
      jq -c --arg p "$prov" '.reports |= map(select(.provider == $p))' "$FAKE_USAGE"
    else
      cat "$FAKE_USAGE"
    fi;;
  config)
    printf '%s\n' '{"modelRoles":{"value":{"default":"anthropic/claude-fable-5-1:high"}}}';;
  *) printf 'fake omp: unsupported: %s\n' "$*" >&2; exit 1;;
esac
FAKE

cat >"$BIN/herdr" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}/${2:-}" in
  agent/list)
    if [ -n "${FAKE_AGENTS:-}" ] && [ -f "${FAKE_AGENTS:-}" ]; then
      jq -c '{result:{agents:.}}' "$FAKE_AGENTS"
    else
      printf '{"result":{"agents":[]}}\n'
    fi;;
  agent/prompt)
    printf '%s\t%s\n' "${3:-}" "${4:-}" >>"${FAKE_PROMPTS:-/dev/null}"
    printf '{}\n';;
  notification/show)
    printf '%s\n' "${3:-}" >>"${FAKE_TOASTS:-/dev/null}"
    printf '{}\n';;
  *) printf 'fake herdr: unsupported: %s\n' "$*" >&2; exit 1;;
esac
FAKE

chmod +x "$BIN/omp" "$BIN/herdr"
PATH="$BIN:$PATH"; export PATH

# ------------------------------------------------------------------ fixtures

T0=1700000000000   # pinned "now" base, ms, divisible by 1000

iso_ms() { # iso_ms <ms>
  date -u -r $(( ${1} / 1000 )) +%Y-%m-%dT%H:%M:%S.000Z
}

mk_usage() { # mk_usage <file> <status> <used-fraction> <resets-at-ms>
  jq -n --arg st "$2" --argjson uf "$3" --argjson r "$4" '
    {generatedAt: 0,
     reports: [{provider: "anthropic", fetchedAt: 0,
       limits: [{id: "anthropic:5h", label: "Claude 5 Hour",
                 scope: {provider: "anthropic", windowId: "5h", shared: true},
                 window: {id: "5h", label: "5 hours", durationMs: 18000000, resetsAt: $r},
                 amount: {used: ($uf * 100), limit: 100, remaining: ((1 - $uf) * 100),
                          usedFraction: $uf, remainingFraction: (1 - $uf), unit: "percent"},
                 status: $st}],
       metadata: {}}]}' >"$1"
}

mk_agent() { # mk_agent <name|null> <pane> <ws> <status> <session>
  jq -nc --arg n "$1" --arg p "$2" --arg w "$3" --arg s "$4" --arg f "$5" '
    {agent: "omp", name: (if $n == "null" then null else $n end),
     pane_id: $p, tab_id: ($p | sub(":p"; ":t")), workspace_id: $w,
     cwd: "/tmp", agent_status: $s,
     agent_session: {agent: "omp", kind: "path", source: "herdr:omp",
                     value: (if $f == "" then null else $f end)}}'
}

agents_file() { # agents_file <file> <agent-json...>
  local out="$1"; shift
  printf '%s\n' "$@" | jq -sc . >"$out"
}

# ---- session fixtures
SESS_ANTHROPIC="$TMP/stall-anthropic.jsonl"
{
  jq -nc --arg ts "$(iso_ms $(( T0 - 60000 )))" \
    '{type:"message", timestamp:$ts, message:{role:"user", content:"go"}}'
  jq -nc --arg ts "$(iso_ms $T0)" '
    {type:"message", timestamp:$ts,
     message:{role:"assistant", provider:"anthropic", model:"claude-fable-5-1",
              stopReason:"error", errorStatus:429,
              errorMessage:"429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"This request would exceed your account'\''s rate limit. Please try again later.\"},\"request_id\":\"req_011CeiKwcU7RM6GVNPbKcq9N\"} retry-after-ms=976000"}}'
} >"$SESS_ANTHROPIC"

SESS_GOOGLE="$TMP/stall-google.jsonl"
jq -nc --arg ts "$(iso_ms $T0)" '
  {type:"message", timestamp:$ts,
   message:{role:"assistant", provider:"google-antigravity", model:"gemini-3-pro",
            stopReason:"error",
            errorMessage:"Cloud Code Assist API error (429): {\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"reason\":\"QUOTA_EXHAUSTED\"}}"}}' >"$SESS_GOOGLE"

SESS_CLEAN="$TMP/clean.jsonl"
{
  jq -nc --arg ts "$(iso_ms $T0)" '
    {type:"message", timestamp:$ts,
     message:{role:"assistant", provider:"anthropic", model:"claude-fable-5-1",
              stopReason:"error", errorStatus:429, errorMessage:"429 rate limit"}}'
  printf 'this line is not json at all\n'
  jq -nc --arg ts "$(iso_ms $(( T0 + 1000 )))" '
    {type:"message", timestamp:$ts,
     message:{role:"assistant", provider:"anthropic", model:"claude-fable-5-1",
              stopReason:"endTurn", content:"all done"}}'
} >"$SESS_CLEAN"

reg() { # reg <state-dir> <now-ms> <manager_id> <ws> <pane> <cap> <in_flight> <adopting> <ready> <demand>
  local sd="$1" now="$2"
  MGR_STATE_DIR="$sd" MGR_GUARD_NOW_MS="$now" "$GUARD" register "$(jq -nc \
    --arg id "$3" --arg ws "$4" --arg pane "$5" \
    --argjson cap "$6" --argjson inf "$7" --argjson ad "$8" --argjson rd "$9" --argjson dm "${10}" '
    {manager_id:$id, workspace_id:$ws, pane_id:$pane, repo:"acme/widgets",
     primary:"/Users/x/code/widgets", cap:$cap, in_flight:$inf, adopting:$ad,
     ready:$rd, demand:$dm}')"
}

printf '== help / usage ==\n'
HELP="$("$GUARD" --help)"
for c in start stop status tick run register stall; do
  case "$HELP" in *"mgr-guard $c"*) pass "--help lists $c";; *) fail "--help is missing $c";; esac
done
"$GUARD" nonsense >/dev/null 2>&1; assert_eq "unknown subcommand exit code" 2 "$?"

printf '\n== (e) stall rule ==\n'
S_A="$(MGR_STATE_DIR="$TMP/s-e" "$GUARD" stall "$SESS_ANTHROPIC")"
assert_json "stall (anthropic)" "$S_A"
assert_jq "stall anthropic provider/retry/model" "$S_A" \
  '.provider == "anthropic" and .retry_after_ms == 976000 and .model == "claude-fable-5-1" and .since == '"$T0"
S_G="$(MGR_STATE_DIR="$TMP/s-e" "$GUARD" stall "$SESS_GOOGLE")"
assert_jq "stall google (no errorStatus, RESOURCE_EXHAUSTED)" "$S_G" \
  '.provider == "google-antigravity" and .retry_after_ms == null and (.error | test("RESOURCE_EXHAUSTED"))'
S_C="$(MGR_STATE_DIR="$TMP/s-e" "$GUARD" stall "$SESS_CLEAN")"
assert_eq "stall on clean last message" "null" "$S_C"
MGR_STATE_DIR="$TMP/s-e" "$GUARD" stall "$TMP/nope.jsonl" >/dev/null 2>&1
assert_eq "stall on missing file exit code" 4 "$?"

printf '\n== register validation ==\n'
BAD_OUT="$(MGR_STATE_DIR="$TMP/s-reg" "$GUARD" register '{"manager_id":"ws-w9"}' 2>&1)"
assert_eq "register missing keys exit code" 2 "$?"
assert_jq "register missing keys error shape" "$BAD_OUT" '.error.code == 2 and (.error.message | test("missing keys"))'

printf '\n== (a) ok usage, two managers, ceiling 6 ==\n'
SD_A="$TMP/s-a"
mk_usage "$TMP/usage-ok.json" ok 0.10 $(( T0 + 7200000 ))
agents_file "$TMP/agents-a.json" \
  "$(mk_agent manager       w3:p1 w3 idle    '')" \
  "$(mk_agent manager-shape w1:p1 w1 working '')"
export FAKE_AGENTS="$TMP/agents-a.json" FAKE_USAGE="$TMP/usage-ok.json"
export FAKE_PROMPTS="$TMP/prompts-a.log" FAKE_TOASTS="$TMP/toasts-a.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"
R1="$(reg "$SD_A" "$T0" ws-w3 w3 w3:p1 3 2 0 4 3)"
assert_jq "register writes seen_at" "$R1" '.seen_at == '"$T0"' and .manager_id == "ws-w3"'
reg "$SD_A" "$T0" ws-w1 w1 w1:p1 3 1 0 0 1 >/dev/null
ST_A="$(MGR_STATE_DIR="$SD_A" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_json "tick output" "$ST_A"
assert_jq "(a) allowed_total 6"   "$ST_A" '.allowed_total == 6'
assert_jq "(a) ceiling 6"         "$ST_A" '.providers.anthropic.ceiling == 6'
assert_jq "(a) reason ok"         "$ST_A" '.providers.anthropic.reason == "ok"'
assert_jq "(a) allotment ws-w3=3" "$ST_A" '.managers["ws-w3"].allotment == 3'
assert_jq "(a) allotment ws-w1=1" "$ST_A" '.managers["ws-w1"].allotment == 1'
assert_jq "(a) both live"         "$ST_A" '[.managers[] | select(.live)] | length == 2'
assert_jq "(a) no stalls"         "$ST_A" '(.stalled | length) == 0'
assert_jq "(a) allowed_changed event" "$ST_A" '[.events[] | select(.kind == "allowed_changed")] | length == 1'
STATUS_A="$(MGR_STATE_DIR="$SD_A" "$GUARD" status)"
assert_json "status output" "$STATUS_A"
assert_jq "status guard=stopped, pid null" "$STATUS_A" '.guard == "stopped" and .pid == null and .allowed_total == 6'

printf '\n== (b) rising burn over three ticks -> projected throttle ==\n'
SD_B="$TMP/s-b"
RESET_B=$(( T0 + 7200000 ))
agents_file "$TMP/agents-b.json" \
  "$(mk_agent manager       w3:p1 w3 idle '')" \
  "$(mk_agent manager-shape w1:p1 w1 idle '')" \
  "$(mk_agent issue-1 w3:p2 w3 working '')" \
  "$(mk_agent issue-2 w3:p3 w3 working '')" \
  "$(mk_agent issue-3 w1:p2 w1 working '')" \
  "$(mk_agent adopt-w1-p3 w1:p3 w1 idle '')"
export FAKE_AGENTS="$TMP/agents-b.json"
reg "$SD_B" "$T0" ws-w3 w3 w3:p1 3 2 0 2 3 >/dev/null
reg "$SD_B" "$T0" ws-w1 w1 w1:p1 3 2 0 2 3 >/dev/null
i=0
for step in "0 0.50" "600000 0.65" "1200000 0.80"; do
  set -- $step
  mk_usage "$TMP/usage-b.json" ok "$2" "$RESET_B"
  export FAKE_USAGE="$TMP/usage-b.json"
  ST_B="$(MGR_STATE_DIR="$SD_B" MGR_GUARD_NOW_MS=$(( T0 + $1 )) "$GUARD" tick)"
  i=$((i + 1))
  printf '     tick %d: allowed=%s burn=%s proj=%s\n' "$i" \
    "$(jq -r '.allowed_total' <<<"$ST_B")" \
    "$(jq -r '.providers.anthropic.limits[0].burn_per_hour' <<<"$ST_B")" \
    "$(jq -r '.providers.anthropic.limits[0].projected_at_reset' <<<"$ST_B")"
done
assert_jq "(b) burn_per_hour 0.9"       "$ST_B" '.providers.anthropic.limits[0].burn_per_hour == 0.9'
assert_jq "(b) projected 2.3, no fit"   "$ST_B" '.providers.anthropic.limits[0].projected_at_reset == 2.3 and (.providers.anthropic.limits[0].fits | not)'
assert_jq "(b) active_builders 4"       "$ST_B" '.providers.anthropic.active_builders == 4'
assert_jq "(b) allowed_total 1"         "$ST_B" '.allowed_total == 1'
assert_jq "(b) reason starts projected" "$ST_B" '.providers.anthropic.reason | startswith("projected")'
assert_jq "(b) binding limit"           "$ST_B" '.providers.anthropic.binding_limit == "anthropic:5h"'
assert_jq "(b) water-filling 1 unit"    "$ST_B" '([.managers[].allotment] | add) == 1'

printf '\n== (c) exhausted -> allowed_total 0, no reignition ==\n'
SD_CD="$TMP/s-cd"
agents_file "$TMP/agents-cd.json" \
  "$(mk_agent manager w3:p1 w3 idle '')" \
  "$(mk_agent issue-9 w3:p9 w3 blocked "$SESS_ANTHROPIC")"
export FAKE_AGENTS="$TMP/agents-cd.json"
export FAKE_PROMPTS="$TMP/prompts-cd.log" FAKE_TOASTS="$TMP/toasts-cd.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"
NOW_C=$(( T0 + 1000 ))
mk_usage "$TMP/usage-exhausted.json" exhausted 1 $(( NOW_C + 3600000 ))
export FAKE_USAGE="$TMP/usage-exhausted.json"
reg "$SD_CD" "$NOW_C" ws-w3 w3 w3:p1 3 1 0 0 1 >/dev/null
ST_C="$(MGR_STATE_DIR="$SD_CD" MGR_GUARD_NOW_MS="$NOW_C" "$GUARD" tick)"
assert_jq "(c) allowed_total 0"        "$ST_C" '.allowed_total == 0'
assert_jq "(c) status exhausted"       "$ST_C" '.providers.anthropic.status == "exhausted"'
assert_jq "(c) reason exhausted"       "$ST_C" '.providers.anthropic.reason | startswith("exhausted: anthropic:5h resets at")'
assert_jq "(c) recovers_at set"        "$ST_C" '.providers.anthropic.recovers_at == '"$(( NOW_C + 3600000 ))"
assert_jq "(c) exhausted event"        "$ST_C" '[.events[] | select(.kind == "exhausted")] | length == 1'
assert_jq "(c) stall recorded"         "$ST_C" '(.stalled | length) == 1 and .stalled[0].pane_id == "w3:p9" and .stalled[0].attempts == 0'
assert_jq "(c) next_reignite_at"       "$ST_C" '.stalled[0].next_reignite_at == '"$(( T0 + 900000 ))"
assert_jq "(c) allotment 0"            "$ST_C" '.managers["ws-w3"].allotment == 0'
assert_eq "(c) prompts sent" 0 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"

printf '\n== (d) quota back -> exactly one reignition ==\n'
NOW_D=$(( T0 + 900001 ))
mk_usage "$TMP/usage-back.json" ok 0.20 $(( NOW_D + 3600000 ))
export FAKE_USAGE="$TMP/usage-back.json"
reg "$SD_CD" "$NOW_D" ws-w3 w3 w3:p1 3 1 0 0 1 >/dev/null
ST_D="$(MGR_STATE_DIR="$SD_CD" MGR_GUARD_NOW_MS="$NOW_D" "$GUARD" tick)"
assert_eq "(d) exactly one prompt" 1 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
assert_eq "(d) prompt targets pane" "w3:p9" "$(cut -f1 <"$FAKE_PROMPTS")"
if grep -q 'mgr-guard: provider quota for anthropic is available again (anthropic:5h at 20%)' "$FAKE_PROMPTS"; then
  pass "(d) reignite text"
else
  fail "(d) reignite text: $(cut -f2 <"$FAKE_PROMPTS")"
fi
assert_jq "(d) attempts 1"        "$ST_D" '.stalled[0].attempts == 1'
assert_jq "(d) last_reignite_at"  "$ST_D" '.stalled[0].last_reignite_at == '"$NOW_D"
assert_jq "(d) backoff 15m"       "$ST_D" '.stalled[0].next_reignite_at == '"$(( NOW_D + 900000 ))"
assert_jq "(d) reignite event"    "$ST_D" '[.events[] | select(.kind == "reignite")] | length == 1'
assert_jq "(d) recovered event"   "$ST_D" '[.events[] | select(.kind == "recovered")] | length == 1'
assert_jq "(d) allowed_total 3"   "$ST_D" '.allowed_total == 3'
if [ -s "$FAKE_TOASTS" ]; then pass "(d) toast emitted"; else fail "(d) no toast emitted"; fi
ST_D2="$(MGR_STATE_DIR="$SD_CD" MGR_GUARD_NOW_MS=$(( NOW_D + 1000 )) "$GUARD" tick)"
assert_eq "(d) no second prompt before backoff" 1 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
assert_jq "(d) attempts stay 1" "$ST_D2" '.stalled[0].attempts == 1'

printf '\n== (f) dead manager registration is dropped ==\n'
SD_F="$TMP/s-f"
agents_file "$TMP/agents-f.json" "$(mk_agent manager w3:p1 w3 idle '')"
export FAKE_AGENTS="$TMP/agents-f.json" FAKE_USAGE="$TMP/usage-ok.json"
reg "$SD_F" "$T0" ws-w3 w3 w3:p1 3 0 0 1 1 >/dev/null
reg "$SD_F" "$T0" ws-w7 w7 w7:p1 3 0 0 1 1 >/dev/null
ST_F="$(MGR_STATE_DIR="$SD_F" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(f) manager_dropped event" "$ST_F" '[.events[] | select(.kind == "manager_dropped" and (.detail | test("ws-w7")))] | length == 1'
assert_jq "(f) only live manager kept" "$ST_F" '(.managers | keys) == ["ws-w3"]'
if [ -f "$SD_F/managers/ws-w7.json" ]; then fail "(f) ws-w7.json still on disk"; else pass "(f) ws-w7.json deleted"; fi
if [ -f "$SD_F/managers/ws-w3.json" ]; then pass "(f) ws-w3.json kept"; else fail "(f) ws-w3.json deleted"; fi

printf '\n== daemon lifecycle (start/status/stop, fake PATH) ==\n'
DAEMON_STATE="$TMP/s-daemon"
NOW_REAL=$(( $(date +%s) * 1000 ))
mk_usage "$TMP/usage-daemon.json" ok 0.05 $(( NOW_REAL + 7200000 ))
export FAKE_USAGE="$TMP/usage-daemon.json" FAKE_AGENTS="$TMP/agents-a.json"
reg "$DAEMON_STATE" "$NOW_REAL" ws-w3 w3 w3:p1 3 0 0 1 1 >/dev/null
START="$(MGR_STATE_DIR="$DAEMON_STATE" MGR_GUARD_INTERVAL=3600 "$GUARD" start)"
assert_json "start output" "$START"
assert_jq "start started=true, running" "$START" '.started == true and .running == true and (.pid | type) == "number"'
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$DAEMON_STATE/state.json" ] && break
  sleep 0.5
done
START2="$(MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" start)"
assert_jq "start is idempotent" "$START2" '.started == false and .running == true'
STATUS_D="$(MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" status)"
assert_jq "status guard=running" "$STATUS_D" '.guard == "running" and (.pid | type) == "number" and .interval_s == 3600'
STOP="$(MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" stop)"
assert_jq "stop reports stopped" "$STOP" '.stopped == true and (.pid | type) == "number"'
STOP2="$(MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" stop)"
assert_jq "stop is idempotent" "$STOP2" '.stopped == false and .pid == null'
assert_jq "status after stop" "$(MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" status)" '.guard == "stopped"'
DAEMON_STATE=""

printf '\n== degraded providers (omp/herdr unusable) ==\n'
SD_X="$TMP/s-x"
export FAKE_USAGE="$TMP/does-not-exist.json"
reg "$SD_X" "$T0" ws-w3 w3 w3:p1 3 0 0 1 1 >/dev/null
ST_X="$(MGR_STATE_DIR="$SD_X" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_json "tick with failing omp" "$ST_X"
assert_jq "degraded provider is unknown" "$ST_X" \
  '.providers.anthropic.status == "unknown" and (.providers.anthropic.reason | startswith("unknown:")) and .allowed_total == 3'
unset FAKE_AGENTS
SD_Y="$TMP/s-y"
export FAKE_USAGE="$TMP/usage-ok.json"
ST_Y="$(MGR_STATE_DIR="$SD_Y" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "no agents, no managers -> ceiling 1" "$ST_Y" '.allowed_total == 1 and (.managers | length) == 0'

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'guard-smoke: all assertions passed\n'
  exit 0
fi
printf 'guard-smoke: %d assertion(s) failed\n' "$FAILURES"
exit 1
