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
  agent/send-keys)
    printf '%s %s\n' "${3:-}" "${4:-}" >>"${FAKE_KEYS:-/dev/null}"
    printf '{}\n';;
  notification/show)
    body=""
    while [ $# -gt 0 ]; do
      case "$1" in --body) body="${2:-}"; shift 2;; *) shift;; esac
    done
    printf '%s\n' "$body" >>"${FAKE_TOASTS:-/dev/null}"
    printf '{}\n';;
  *) printf 'fake herdr: unsupported: %s\n' "$*" >&2; exit 1;;
esac
FAKE

chmod +x "$BIN/omp" "$BIN/herdr"
PATH="$BIN:$PATH"; export PATH
# most scenarios pin a single-tick projection; (o) and (p) override this in line
MGR_GUARD_CONFIRM_TICKS=1; export MGR_GUARD_CONFIRM_TICKS

# ------------------------------------------------------------------ fixtures

T0=1700000000000   # pinned "now" base, ms, divisible by 1000

iso_ms() { # iso_ms <ms>
  local s=$(( ${1} / 1000 ))
  # GNU date renders an epoch with -d @N; BSD/macOS date uses -r N
  if date --version >/dev/null 2>&1; then
    date -u -d "@$s" +%Y-%m-%dT%H:%M:%S.000Z
  else
    date -u -r "$s" +%Y-%m-%dT%H:%M:%S.000Z
  fi
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

reg() { # reg <state-dir> <now-ms> <manager_id> <ws> <pane> <cap> <in_flight> <adopting> <ready> <demand> [repo]
  local sd="$1" now="$2" repo="${11:-acme/widgets}"
  MGR_STATE_DIR="$sd" MGR_GUARD_NOW_MS="$now" "$GUARD" register "$(jq -nc \
    --arg id "$3" --arg ws "$4" --arg pane "$5" --arg repo "$repo" \
    --argjson cap "$6" --argjson inf "$7" --argjson ad "$8" --argjson rd "$9" --argjson dm "${10}" '
    {manager_id:$id, workspace_id:$ws, pane_id:$pane, repo:$repo,
     primary:"/Users/x/code/widgets", cap:$cap, in_flight:$inf, adopting:$ad,
     ready:$rd, demand:$dm}')"
}

arm() { # arm <state-dir> <now-ms> <used-prev> <used-now> [status]: seed one prior sample + the usage fixture
  local sd="$1" now="$2" prev="$3" cur="$4" status="${5:-ok}" reset usage
  reset=$(( now + 7200000 ))
  mkdir -p "$sd"
  jq -nc --argjson t "$(( now - 1800000 ))" --argjson u "$prev" --argjson r "$reset" \
    '{t:$t, provider:"anthropic", limit:"anthropic:5h", used:$u, resets_at:$r, status:"ok"}' \
    >"$sd/samples.jsonl"
  usage="$TMP/usage-armed-$(basename "$sd").json"
  mk_usage "$usage" "$status" "$cur" "$reset"
  export FAKE_USAGE="$usage"
}

printf '== help / usage ==\n'
HELP="$("$GUARD" --help)"
for c in start stop status tick run register stall priority; do
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
export FAKE_KEYS="$TMP/keys-b.log"; : >"$FAKE_KEYS"
reg "$SD_B" "$T0" ws-w3 w3 w3:p1 3 2 0 2 3 >/dev/null
reg "$SD_B" "$T0" ws-w1 w1 w1:p1 3 2 0 2 3 >/dev/null
i=0
ST_B2=""
for step in "0 0.50" "600000 0.65" "1200000 0.80"; do
  set -- $step
  mk_usage "$TMP/usage-b.json" warning "$2" "$RESET_B"
  export FAKE_USAGE="$TMP/usage-b.json"
  ST_B="$(MGR_STATE_DIR="$SD_B" MGR_GUARD_NOW_MS=$(( T0 + $1 )) "$GUARD" tick)"
  i=$((i + 1))
  [ "$i" = 2 ] && ST_B2="$ST_B"
  printf '     tick %d: allowed=%s burn=%s proj=%s\n' "$i" \
    "$(jq -r '.allowed_total' <<<"$ST_B")" \
    "$(jq -r '.providers.anthropic.limits[0].burn_per_hour' <<<"$ST_B")" \
    "$(jq -r '.providers.anthropic.limits[0].projected_at_reset' <<<"$ST_B")"
done
assert_jq "(b) burn_per_hour 0.9"       "$ST_B" '.providers.anthropic.limits[0].burn_per_hour == 0.9'
assert_jq "(b) projected 2.3, no fit"   "$ST_B" '.providers.anthropic.limits[0].projected_at_reset == 2.3 and (.providers.anthropic.limits[0].fits | not)'
assert_jq "(b) active_builders 4 on the throttling tick" "$ST_B2" '.providers.anthropic.active_builders == 4'
assert_jq "(b) throttle is constrained"  "$ST_B2" '.constrained == true and .demand_total == 6'
assert_jq "(b) over-allotment builders paused, the idle adoptee only held" "$ST_B2" \
  '.managers["ws-w1"].allotment == 0 and .managers["ws-w3"].allotment == 1
   and ([.stalled[] | select(.cause == "paused") | .pane_id] | sort) == ["w1:p2","w1:p3","w3:p3"]
   and ([.stalled[] | select(.pane_id == "w1:p3")] | first | .esc_sent) == 0
   and .managers["ws-w1"].paused == true and .managers["ws-w3"].paused == true'
assert_eq "(b) esc order: highest issue number first per manager" "w1:p2 esc
w3:p3 esc" "$(sed -n '1,2p' "$FAKE_KEYS")"
assert_jq "(b) paused builders leave active_builders" "$ST_B" '.providers.anthropic.active_builders == 1'
assert_jq "(b) esc re-sent while they keep working, the held adoptee is left alone" "$ST_B" \
  '([.stalled[] | select(.cause == "paused") | .esc_sent] | sort) == [0,2,2]'
assert_eq "(b) four esc lines in total" 4 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
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

printf '\n== (g) priority CLI round-trip ==\n'
SD_G="$TMP/s-g"
PG0="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority)"
assert_jq "(g) empty map, default 5" "$PG0" '.priorities == {} and .default == 5'
PG1="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority acme/app)"
assert_jq "(g) unknown repo -> 5, not explicit" "$PG1" '.repo == "acme/app" and .priority == 5 and .explicit == false'
PG2="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority acme/app 8)"
assert_jq "(g) set 8" "$PG2" '.repo == "acme/app" and .priority == 8 and .explicit == true'
PG3="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority acme/site 0)"
assert_jq "(g) set 0 (pause a project)" "$PG3" '.priority == 0 and .explicit == true'
PG4="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority)"
assert_jq "(g) map has both repos" "$PG4" '.priorities == {"acme/app":8,"acme/site":0}'
assert_jq "(g) priorities.json on disk" "$(cat "$SD_G/priorities.json")" '.["acme/app"] == 8'
PG5="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority acme/app --clear)"
assert_jq "(g) --clear -> back to 5" "$PG5" '.repo == "acme/app" and .priority == 5 and .explicit == false'
PG6="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority --clear acme/site)"
assert_jq "(g) --clear before the repo works" "$PG6" '.priority == 5 and .explicit == false'
PG7="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority)"
assert_jq "(g) map empty again" "$PG7" '.priorities == {}'
BADP="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority acme/app -1 2>&1)"
assert_eq "(g) N=-1 exit code" 2 "$?"
assert_jq "(g) N=-1 error shape" "$BADP" '.error.code == 2'
BADP2="$(MGR_STATE_DIR="$SD_G" "$GUARD" priority acme/app abc 2>&1)"
assert_eq "(g) N=abc exit code" 2 "$?"
assert_jq "(g) N=abc error shape" "$BADP2" '.error.code == 2 and (.error.message | test("integer"))'
MGR_STATE_DIR="$SD_G" "$GUARD" priority "" 3 >/dev/null 2>&1
assert_eq "(g) empty repo exit code" 2 "$?"

# ---- shared fixture for (h)-(j): three projects, priorities 8 / 7 / 6.
# The priorities are close together on purpose: with cap 3 at the top the derived
# cap ceiling (floor(3 * p / 8), min 1) is 3 / 2 / 2, so it never bites here and
# these sections keep testing the provider throttle alone. (n) covers the ceiling.
prios() { # prios <state-dir>
  MGR_STATE_DIR="$1" "$GUARD" priority acme/a 8 >/dev/null
  MGR_STATE_DIR="$1" "$GUARD" priority acme/b 7 >/dev/null
  MGR_STATE_DIR="$1" "$GUARD" priority acme/c 6 >/dev/null
}
regs3() { # regs3 <state-dir> <now> <demand-a> <demand-b> <demand-c>
  reg "$1" "$2" ws-wA wA wA:p1 3 0 0 "$3" "$3" acme/a >/dev/null
  reg "$1" "$2" ws-wB wB wB:p1 3 0 0 "$4" "$4" acme/b >/dev/null
  reg "$1" "$2" ws-wC wC wC:p1 3 0 0 "$5" "$5" acme/c >/dev/null
}
agents3() { # agents3 <file> <status-of-wC-builders>
  agents_file "$1" \
    "$(mk_agent manager   wA:p1 wA idle '')" \
    "$(mk_agent manager-b wB:p1 wB idle '')" \
    "$(mk_agent manager-c wC:p1 wC idle '')" \
    "$(mk_agent issue-1 wA:p2 wA idle '')" \
    "$(mk_agent issue-2 wA:p3 wA idle '')" \
    "$(mk_agent issue-3 wA:p4 wA idle '')" \
    "$(mk_agent issue-4 wB:p2 wB idle '')" \
    "$(mk_agent issue-5 wB:p3 wB idle '')" \
    "$(mk_agent issue-6 wB:p4 wB idle '')" \
    "$(mk_agent issue-7 wC:p7 wC "$2" '')" \
    "$(mk_agent issue-9 wC:p9 wC "$2" '')"
}

printf '\n== (h) tiered allotment: strict priority order when constrained ==\n'
SD_H="$TMP/s-h"
agents3 "$TMP/agents-h.json" idle
export FAKE_AGENTS="$TMP/agents-h.json"
export FAKE_PROMPTS="$TMP/prompts-h.log" FAKE_TOASTS="$TMP/toasts-h.log" FAKE_KEYS="$TMP/keys-h.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"; : >"$FAKE_KEYS"
regs3 "$SD_H" "$T0" 3 2 2
prios "$SD_H"
arm "$SD_H" "$T0" 0.25 0.25          # no burn -> allowed_total = ceiling 9
ST_H0="$(MGR_STATE_DIR="$SD_H" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(h) unconstrained allowed_total 9" "$ST_H0" '.allowed_total == 9'
assert_jq "(h) demand_total 7"                "$ST_H0" '.demand_total == 7'
assert_jq "(h) constrained false"             "$ST_H0" '.constrained == false'
assert_jq "(h) unconstrained: everyone gets demand" "$ST_H0" \
  '.managers["ws-wA"].allotment == 3 and .managers["ws-wB"].allotment == 2 and .managers["ws-wC"].allotment == 2'
assert_jq "(h) priorities in state"           "$ST_H0" '.priorities == {"acme/a":8,"acme/b":7,"acme/c":6}'
assert_jq "(h) manager priorities annotated"  "$ST_H0" \
  '.managers["ws-wA"].priority == 8 and .managers["ws-wB"].priority == 7 and .managers["ws-wC"].priority == 6'
assert_jq "(h) derived caps do not bite here" "$ST_H0" \
  '[.managers["ws-wA"], .managers["ws-wB"], .managers["ws-wC"]]
   | map([.derived_cap, .demand_effective]) == [[3,3],[2,2],[2,2]]'
assert_jq "(h) nobody paused"                 "$ST_H0" '[.managers[] | select(.paused)] | length == 0'
assert_jq "(h) no internal fields leak into state" "$ST_H0" \
  '([.managers[] | select(has("builders") or has("all_builders"))] | length) == 0
   and ([.providers.anthropic.limits[] | select(has("samples") or has("hours_to_reset"))] | length) == 0
   and .managers["ws-wA"].no_room_at != null'
assert_jq "(h) priority_changed events"       "$ST_H0" \
  '[.events[] | select(.kind == "priority_changed") | .detail] as $d
   | ($d | length) == 3 and ($d | index("acme/a: 5 -> 8") != null)
     and ($d | index("acme/b: 5 -> 7") != null) and ($d | index("acme/c: 5 -> 6") != null)'
if grep -q 'priority_changed: acme/a: 5 -> 8' "$FAKE_TOASTS"; then pass "(h) priority_changed toast"; else fail "(h) no priority_changed toast"; fi
assert_eq "(h) no esc sent" 0 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
arm "$SD_H" $(( T0 + 1800000 )) 0.25 0.50     # burn 0.5/h, 2h to reset -> allowed_total 4
ST_H1="$(MGR_STATE_DIR="$SD_H" MGR_GUARD_NOW_MS=$(( T0 + 1800000 )) "$GUARD" tick)"
assert_jq "(h) active_builders 8"     "$ST_H1" '.providers.anthropic.active_builders == 8'
assert_jq "(h) allowed_total 4"       "$ST_H1" '.allowed_total == 4'
assert_jq "(h) constrained true"      "$ST_H1" '.constrained == true'
assert_jq "(h) tier 8 gets demand 3"  "$ST_H1" '.managers["ws-wA"].allotment == 3'
assert_jq "(h) tier 7 gets leftover 1" "$ST_H1" '.managers["ws-wB"].allotment == 1'
assert_jq "(h) tier 6 gets nothing"   "$ST_H1" '.managers["ws-wC"].allotment == 0'
assert_jq "(h) no new priority_changed" "$ST_H1" '[.events[] | select(.kind == "priority_changed" and .at == '"$(( T0 + 1800000 ))"')] | length == 0'

printf '\n== (i) hard pause of the lowest tier ==\n'
SD_I="$TMP/s-i"
agents3 "$TMP/agents-i-working.json" working
agents3 "$TMP/agents-i-idle.json" idle
export FAKE_AGENTS="$TMP/agents-i-working.json"
export FAKE_PROMPTS="$TMP/prompts-i.log" FAKE_TOASTS="$TMP/toasts-i.log" FAKE_KEYS="$TMP/keys-i.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"; : >"$FAKE_KEYS"
regs3 "$SD_I" "$T0" 3 2 2
prios "$SD_I"
arm "$SD_I" "$T0" 0.25 0.50 warning
ST_I1="$(MGR_STATE_DIR="$SD_I" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(i) constrained, ws-wC allotment 0" "$ST_I1" '.constrained == true and .managers["ws-wC"].allotment == 0'
assert_jq "(i) ws-wC active_builders 2"        "$ST_I1" '.managers["ws-wC"].active_builders == 2'
assert_eq "(i) exactly two esc lines" 2 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
assert_eq "(i) both esc, panes in order" "wC:p9 esc
wC:p7 esc" "$(cat "$FAKE_KEYS")"
assert_jq "(i) two esc'd entries in wC, two idle wB builders held instead" "$ST_I1" \
  '([.stalled[] | select(.cause == "paused") | .pane_id] | sort) == ["wB:p3","wB:p4","wC:p7","wC:p9"]
   and ([.stalled[] | select(.workspace_id == "wB") | .esc_sent] | unique) == [0]
   and ([.stalled[] | select(.workspace_id == "wC") | .esc_sent] | unique) == [1]
   and .providers.anthropic.hard == true'
assert_jq "(i) paused entry shape" "$ST_I1" \
  '[.stalled[] | select(.pane_id == "wC:p9")] | first
   | .cause == "paused" and .name == "issue-9" and .workspace_id == "wC" and .manager_id == "ws-wC"
     and .esc_sent == 1 and .paused_at == '"$T0"' and .since == '"$T0"'
     and .provider == "anthropic" and .model == null and .error == null
     and .attempts == 0 and .next_reignite_at == null'
assert_jq "(i) ws-wC marked paused"   "$ST_I1" '.managers["ws-wC"].paused == true and .managers["ws-wA"].paused == false'
assert_jq "(i) paused events"         "$ST_I1" \
  '[.events[] | select(.kind == "paused") | .detail] as $d
   | ($d | length) == 4
     and ([$d[] | select(test("wC:p9 issue-9 \\(ws-wC priority 6, allotment 0\\)"))] | length) == 1'
if grep -q 'paused: wC:p9' "$FAKE_TOASTS"; then pass "(i) paused toast"; else fail "(i) no paused toast"; fi
assert_eq "(i) no prompts on a pause" 0 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
# still working on the next tick -> esc again (2/3)
arm "$SD_I" $(( T0 + 600000 )) 0.25 0.50 warning
ST_I2="$(MGR_STATE_DIR="$SD_I" MGR_GUARD_NOW_MS=$(( T0 + 600000 )) "$GUARD" tick)"
assert_jq "(i) ws-wB held builders stay at esc_sent 0" "$ST_I2" \
  '([.stalled[] | select(.workspace_id == "wB") | .esc_sent] | unique) == [0]'
assert_eq "(i) esc re-sent" 4 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
assert_jq "(i) esc_sent 2"        "$ST_I2" \
  '[.stalled[] | select(.workspace_id == "wC") | .esc_sent] == [2,2]'
assert_jq "(i) paused_at unchanged" "$ST_I2" '[.stalled[] | select(.pane_id == "wC:p9")] | first | .paused_at == '"$T0"
assert_jq "(i) paused builders leave provider active_builders" "$ST_I2" '.providers.anthropic.active_builders == 4'
assert_jq "(i) no second paused event for a builder already held" "$ST_I2" \
  '[.events[] | select(.kind == "paused" and .at == '"$(( T0 + 600000 ))"') | .detail]
   | ([.[] | select(test("wC:"))] | length) == 0'
# idle now -> nothing to send
export FAKE_AGENTS="$TMP/agents-i-idle.json"
arm "$SD_I" $(( T0 + 900000 )) 0.25 0.50 warning
ST_I3="$(MGR_STATE_DIR="$SD_I" MGR_GUARD_NOW_MS=$(( T0 + 900000 )) "$GUARD" tick)"
assert_eq "(i) no esc for an idle paused builder" 4 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
assert_jq "(i) esc_sent stays 2" "$ST_I3" '[.stalled[] | select(.workspace_id == "wC") | .esc_sent] == [2,2]'
assert_jq "(i) entries survive"  "$ST_I3" \
  '([.stalled[] | select(.cause == "paused") | .pane_id] | sort) == ["wA:p3","wA:p4","wB:p2","wB:p3","wB:p4","wC:p7","wC:p9"]'
assert_eq "(i) still no prompts" 0 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"

printf '\n== (j) resume when the allotment comes back ==\n'
NOW_J=$(( T0 + 1200000 ))
arm "$SD_I" "$NOW_J" 0.10 0.10        # no burn -> allowed_total = ceiling 9, unconstrained
ST_J="$(MGR_STATE_DIR="$SD_I" MGR_GUARD_NOW_MS="$NOW_J" "$GUARD" tick)"
assert_jq "(j) unconstrained again" "$ST_J" '.allowed_total == 9 and .constrained == false and .managers["ws-wC"].allotment == 2'
assert_eq "(j) every held builder its manager has room for is resumed" 6 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
assert_eq "(j) lowest issue number first, per manager" "wA:p3
wA:p4
wB:p2
wB:p3
wC:p7
wC:p9" "$(cut -f1 <"$FAKE_PROMPTS" | sort)"
if grep -q "mgr-guard: this project's quota allotment is back (priority 6, allotment 2)." "$FAKE_PROMPTS"; then
  pass "(j) resume text"
else
  fail "(j) resume text: $(cut -f2 <"$FAKE_PROMPTS" | head -1)"
fi
if grep -q 'The quota guard interrupted your previous turn' "$FAKE_PROMPTS"; then
  pass "(j) resume text explains the interruption"
else
  fail "(j) resume text is missing the explanation"
fi
assert_jq "(j) esc'd entries removed, only the still over-allotment hold stays" "$ST_J" \
  '[.stalled[] | .pane_id] == ["wB:p4"]'
assert_jq "(j) resumed events"    "$ST_J" \
  '[.events[] | select(.kind == "resumed") | .detail] as $d
   | ($d | length) == 6
     and ([$d[] | select(test("wC:p7 issue-7 \\(ws-wC allotment 2\\)"))] | length) == 1'
assert_jq "(j) manager no longer paused" "$ST_J" '.managers["ws-wC"].paused == false'
assert_eq "(j) no further esc" 4 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
if grep -q 'resumed: wC:p7' "$FAKE_TOASTS"; then pass "(j) resumed toast"; else fail "(j) no resumed toast"; fi
# the cooldown really is enforced
SD_J2="$TMP/s-j2"
export FAKE_AGENTS="$TMP/agents-i-working.json" FAKE_KEYS="$TMP/keys-j2.log" FAKE_PROMPTS="$TMP/prompts-j2.log"
: >"$FAKE_KEYS"; : >"$FAKE_PROMPTS"
regs3 "$SD_J2" "$T0" 3 2 2
prios "$SD_J2"
arm "$SD_J2" "$T0" 0.25 0.50 warning
MGR_STATE_DIR="$SD_J2" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick >/dev/null
assert_eq "(j) the constrained tick escs wC" 2 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
# 30 s after the no-room tick the cooldown (60 s) has not elapsed yet
export FAKE_AGENTS="$TMP/agents-i-idle.json"
arm "$SD_J2" $(( T0 + 30000 )) 0.10 0.10
ST_J2="$(MGR_STATE_DIR="$SD_J2" MGR_GUARD_NOW_MS=$(( T0 + 30000 )) "$GUARD" tick)"
assert_jq "(j) room but inside the cooldown -> still paused" "$ST_J2" \
  '.constrained == false and ([.stalled[] | select(.cause == "paused")] | length) == 4
   and .managers["ws-wC"].no_room_at == '"$T0"
assert_eq "(j) no prompt inside the cooldown" 0 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
# 61 s after the last tick with no room, the resume fires
arm "$SD_J2" $(( T0 + 61000 )) 0.10 0.10
ST_J3="$(MGR_STATE_DIR="$SD_J2" MGR_GUARD_NOW_MS=$(( T0 + 61000 )) "$GUARD" tick)"
assert_eq "(j) the cooldown elapsed -> wC resumes, wB up to its room" 3 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
assert_jq "(j) the two esc'd builders are back" "$ST_J3" \
  '[.stalled[] | select(.pane_id | startswith("wC:"))] | length == 0'
# the knob itself: cooldown 0 resumes on the very next tick, held builders included
SD_J3="$TMP/s-j3"
export FAKE_AGENTS="$TMP/agents-i-working.json" FAKE_KEYS="$TMP/keys-j3.log" FAKE_PROMPTS="$TMP/prompts-j3.log"
: >"$FAKE_KEYS"; : >"$FAKE_PROMPTS"
regs3 "$SD_J3" "$T0" 3 2 2
prios "$SD_J3"
arm "$SD_J3" "$T0" 0.25 0.50 warning
MGR_STATE_DIR="$SD_J3" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick >/dev/null
export FAKE_AGENTS="$TMP/agents-i-idle.json"
arm "$SD_J3" $(( T0 + 1000 )) 0.10 0.10
ST_J4="$(MGR_GUARD_RESUME_COOLDOWN_S=0 MGR_STATE_DIR="$SD_J3" MGR_GUARD_NOW_MS=$(( T0 + 1000 )) "$GUARD" tick)"
assert_eq "(j) cooldown 0 resumes on the next tick" 3 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
assert_jq "(j) cooldown 0 clears the esc'd entries" "$ST_J4" \
  '[.stalled[] | select(.pane_id | startswith("wC:"))] | length == 0'
if grep -q 'The quota guard held this session at the end of its previous turn' "$FAKE_PROMPTS"; then
  pass "(j) a held builder gets the turn-boundary resume text"
else
  fail "(j) held builder resume text: $(cut -f2 <"$FAKE_PROMPTS" | sed -n '1p')"
fi

printf '\n== (k) a 429 entry is only reignited when its manager has room ==\n'
SD_K="$TMP/s-k"
agents_file "$TMP/agents-k.json" \
  "$(mk_agent manager wK:p1 wK idle '')" \
  "$(mk_agent issue-1 wK:p2 wK working '')" \
  "$(mk_agent issue-9 wK:p9 wK blocked "$SESS_ANTHROPIC")"
export FAKE_AGENTS="$TMP/agents-k.json" FAKE_USAGE="$TMP/usage-ok.json"
export FAKE_PROMPTS="$TMP/prompts-k.log" FAKE_TOASTS="$TMP/toasts-k.log" FAKE_KEYS="$TMP/keys-k.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"; : >"$FAKE_KEYS"
NOW_K=$(( T0 + 900001 ))
mk_usage "$TMP/usage-k.json" ok 0.20 $(( NOW_K + 7200000 ))
export FAKE_USAGE="$TMP/usage-k.json"
reg "$SD_K" "$NOW_K" ws-wK wK wK:p1 3 1 0 0 1 acme/k >/dev/null
ST_K1="$(MGR_STATE_DIR="$SD_K" MGR_GUARD_NOW_MS="$NOW_K" "$GUARD" tick)"
assert_jq "(k) allotment 1, active 1 -> no room" "$ST_K1" \
  '.managers["ws-wK"].allotment == 1 and .managers["ws-wK"].active_builders == 1'
assert_jq "(k) the 429 entry is there, due"      "$ST_K1" \
  '(.stalled | length) == 1 and .stalled[0].cause == "429" and .stalled[0].attempts == 0
   and .stalled[0].next_reignite_at == '"$(( T0 + 900000 ))"
assert_eq "(k) no reignite without room" 0 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
assert_eq "(k) and no esc (not constrained)" 0 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
reg "$SD_K" $(( NOW_K + 1000 )) ws-wK wK wK:p1 3 2 0 0 2 acme/k >/dev/null
ST_K2="$(MGR_STATE_DIR="$SD_K" MGR_GUARD_NOW_MS=$(( NOW_K + 1000 )) "$GUARD" tick)"
assert_jq "(k) allotment 2 -> room" "$ST_K2" '.managers["ws-wK"].allotment == 2'
assert_eq "(k) reignited once room appears" 1 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
assert_eq "(k) reignite targets the stalled pane" "wK:p9" "$(cut -f1 <"$FAKE_PROMPTS")"
assert_jq "(k) attempts 1"          "$ST_K2" '.stalled[0].attempts == 1'
assert_jq "(k) reignite event"      "$ST_K2" '[.events[] | select(.kind == "reignite")] | length == 1'

printf '\n== (l) esc gives up after three tries ==\n'
SD_L="$TMP/s-l"
export FAKE_AGENTS="$TMP/agents-i-working.json"
export FAKE_KEYS="$TMP/keys-l.log" FAKE_PROMPTS="$TMP/prompts-l.log"
: >"$FAKE_KEYS"; : >"$FAKE_PROMPTS"
regs3 "$SD_L" "$T0" 3 2 2
prios "$SD_L"
ST_L=""
for off in 0 60000 120000 180000; do
  arm "$SD_L" $(( T0 + off )) 0.25 0.50 warning
  ST_L="$(MGR_STATE_DIR="$SD_L" MGR_GUARD_NOW_MS=$(( T0 + off )) "$GUARD" tick)"
done
assert_eq "(l) at most three esc per builder" 6 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
assert_jq "(l) esc_sent capped at 3" "$ST_L" '[.stalled[] | select(.workspace_id == "wC") | .esc_sent] == [3,3]'
assert_jq "(l) entries stay paused"  "$ST_L" \
  '[.stalled[] | select(.cause == "paused") | select(.workspace_id == "wC")] | length == 2'
if grep -q 'error pause wC:p9 did not take' "$SD_L/guard.log"; then
  pass "(l) gives up loudly in the log"
else
  fail "(l) no 'did not take' error in guard.log"
fi
if grep -q 'paused=4 resumed=0 constrained=true hard=true' "$SD_L/guard.log"; then
  pass "(l) tick log line carries paused/resumed/constrained"
else
  fail "(l) tick log line: $(sed -n '$p' "$SD_L/guard.log")"
fi

printf '\n== (m) stall --pane: a paused entry wins over the file ==\n'
SP1="$(MGR_STATE_DIR="$SD_L" "$GUARD" stall --pane wC:p9 "$SESS_CLEAN")"
assert_jq "(m) paused entry printed as-is" "$SP1" \
  '.cause == "paused" and .pane_id == "wC:p9" and .name == "issue-9" and .manager_id == "ws-wC" and .esc_sent == 3'
SP2="$(MGR_STATE_DIR="$SD_L" "$GUARD" stall "$SESS_CLEAN" --pane wC:p9)"
assert_eq "(m) --pane after the file arg" "$SP1" "$SP2"
SP3="$(MGR_STATE_DIR="$SD_L" "$GUARD" stall --pane wA:p2 "$SESS_CLEAN")"
assert_eq "(m) unpaused pane falls back to the file rule" "null" "$SP3"
SP4="$(MGR_STATE_DIR="$SD_L" "$GUARD" stall --pane wA:p2 "$SESS_ANTHROPIC")"
assert_jq "(m) unpaused pane still reports a 429 stall" "$SP4" \
  '.provider == "anthropic" and .retry_after_ms == 976000 and (has("cause") | not)'
MGR_STATE_DIR="$SD_L" "$GUARD" stall --pane wA:p2 "$TMP/nope.jsonl" >/dev/null 2>&1
assert_eq "(m) unpaused pane + missing file -> exit 4" 4 "$?"
MGR_STATE_DIR="$SD_L" "$GUARD" stall --pane >/dev/null 2>&1
assert_eq "(m) --pane without a file -> exit 2" 2 "$?"

printf '\n== (n) priority-derived cap ceiling ==\n'
export FAKE_PROMPTS="$TMP/prompts-n.log" FAKE_TOASTS="$TMP/toasts-n.log" FAKE_KEYS="$TMP/keys-n.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"; : >"$FAKE_KEYS"
managers3() { # managers3 <file> <ws...>: one idle manager pane per workspace, no builders
  local out="$1"; shift
  local a=() w
  for w in "$@"; do a+=("$(mk_agent "manager-$w" "$w:p1" "$w" idle '')"); done
  agents_file "$out" "${a[@]}"
}

# ---- (n1) priorities 10 / 5 / 3, cap 3 and demand 3 each: only the top project keeps
# its whole cap, the others scale down to floor(3 * p / 10) with a floor of one slot
SD_N1="$TMP/s-n1"
managers3 "$TMP/agents-n1.json" wP wQ wR
export FAKE_AGENTS="$TMP/agents-n1.json"
reg "$SD_N1" "$T0" ws-wP wP wP:p1 3 0 0 3 3 acme/p >/dev/null
reg "$SD_N1" "$T0" ws-wQ wQ wQ:p1 3 0 0 3 3 acme/q >/dev/null
reg "$SD_N1" "$T0" ws-wR wR wR:p1 3 0 0 3 3 acme/r >/dev/null
MGR_STATE_DIR="$SD_N1" "$GUARD" priority acme/p 10 >/dev/null
MGR_STATE_DIR="$SD_N1" "$GUARD" priority acme/q 5 >/dev/null
MGR_STATE_DIR="$SD_N1" "$GUARD" priority acme/r 3 >/dev/null
arm "$SD_N1" "$T0" 0.25 0.25          # no burn -> allowed_total = ceiling 9, provider ok
ST_N1="$(MGR_STATE_DIR="$SD_N1" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(n1) provider is not the limit" "$ST_N1" \
  '.allowed_total == 9 and .providers.anthropic.reason == "ok" and .constrained == false'
assert_jq "(n1) top_priority 10, top_cap 3" "$ST_N1" '.top_priority == 10 and .top_cap == 3'
assert_jq "(n1) demand_total counts the effective demand" "$ST_N1" '.demand_total == 5'
assert_jq "(n1) derived_cap / demand_effective / allotment 3-1-1" "$ST_N1" \
  '[.managers["ws-wP"], .managers["ws-wQ"], .managers["ws-wR"]]
   | map([.priority, .derived_cap, .demand_effective, .allotment])
     == [[10,3,3,3],[5,1,1,1],[3,1,1,1]]'
assert_jq "(n1) the registered demand is untouched" "$ST_N1" \
  '[.managers["ws-wP"], .managers["ws-wQ"], .managers["ws-wR"]] | map(.demand) == [3,3,3]'
assert_jq "(n1) the ceiling still sums the registered caps" "$ST_N1" '.providers.anthropic.ceiling == 9'
assert_eq "(n1) nothing paused, nothing prompted" 0 \
  "$(( $(wc -l <"$FAKE_KEYS") + $(wc -l <"$FAKE_PROMPTS") ))"

# ---- (n2) a tie at the top takes the largest cap of the tied projects as the scale
SD_N2="$TMP/s-n2"
reg "$SD_N2" "$T0" ws-wP wP wP:p1 3 0 0 3 3 acme/p >/dev/null
reg "$SD_N2" "$T0" ws-wQ wQ wQ:p1 2 0 0 2 2 acme/q >/dev/null
reg "$SD_N2" "$T0" ws-wR wR wR:p1 3 0 0 3 3 acme/r >/dev/null
MGR_STATE_DIR="$SD_N2" "$GUARD" priority acme/p 10 >/dev/null
MGR_STATE_DIR="$SD_N2" "$GUARD" priority acme/q 10 >/dev/null
MGR_STATE_DIR="$SD_N2" "$GUARD" priority acme/r 5 >/dev/null
arm "$SD_N2" "$T0" 0.25 0.25
ST_N2="$(MGR_STATE_DIR="$SD_N2" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(n2) top_cap is the max cap among the tied top projects" "$ST_N2" \
  '.top_priority == 10 and .top_cap == 3'
assert_jq "(n2) both tied projects derive the top cap, the tier below derives floor(3*5/10)" "$ST_N2" \
  '[.managers["ws-wP"], .managers["ws-wQ"], .managers["ws-wR"]]
   | map([.derived_cap, .demand_effective, .allotment]) == [[3,3,3],[3,2,2],[1,1,1]]'

# ---- (n3) a project whose own cap is already below the derived cap keeps its own cap
SD_N3="$TMP/s-n3"
managers3 "$TMP/agents-n3.json" wP wS
export FAKE_AGENTS="$TMP/agents-n3.json"
reg "$SD_N3" "$T0" ws-wP wP wP:p1 3 0 0 3 3 acme/p >/dev/null
reg "$SD_N3" "$T0" ws-wS wS wS:p1 1 0 0 1 1 acme/s >/dev/null
MGR_STATE_DIR="$SD_N3" "$GUARD" priority acme/p 10 >/dev/null
MGR_STATE_DIR="$SD_N3" "$GUARD" priority acme/s 8 >/dev/null
arm "$SD_N3" "$T0" 0.25 0.25
ST_N3="$(MGR_STATE_DIR="$SD_N3" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(n3) derived 2 but the registered cap 1 binds" "$ST_N3" \
  '.top_cap == 3 and (.managers["ws-wS"] | .cap == 1 and .derived_cap == 2
                      and .demand == 1 and .demand_effective == 1 and .allotment == 1)'

# ---- (n4) priority 0 still derives one slot: pausing a project is a separate function
SD_N4="$TMP/s-n4"
managers3 "$TMP/agents-n4.json" wP wZ
export FAKE_AGENTS="$TMP/agents-n4.json"
reg "$SD_N4" "$T0" ws-wP wP wP:p1 3 0 0 3 3 acme/p >/dev/null
reg "$SD_N4" "$T0" ws-wZ wZ wZ:p1 3 0 0 3 3 acme/z >/dev/null
MGR_STATE_DIR="$SD_N4" "$GUARD" priority acme/p 10 >/dev/null
MGR_STATE_DIR="$SD_N4" "$GUARD" priority acme/z 0 >/dev/null
arm "$SD_N4" "$T0" 0.25 0.25
ST_N4="$(MGR_STATE_DIR="$SD_N4" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(n4) priority 0 -> derived_cap 1, one slot allotted" "$ST_N4" \
  '(.managers["ws-wZ"] | .priority == 0 and .derived_cap == 1
    and .demand == 3 and .demand_effective == 1 and .allotment == 1)
   and .demand_total == 4 and .constrained == false'

printf '\n== (o) jittered resets_at: every in-window sample is fitted ==\n'
# fit_window <samples.jsonl> <limit> <resets-at> <tolerance-ms> -> "<count> <slope>",
# the guard's least-squares fit recomputed from the fixture it was handed
fit_window() {
  jq -Rnr --arg l "$2" --argjson r "$3" --argjson tol "$4" '
    ([inputs | (fromjson? // empty)
      | select((.limit == $l) and (((.resets_at - $r) | fabs) <= $tol))] | sort_by(.t)) as $s
    | ($s | length) as $n
    | ([$s[] | .t / 3600000]) as $xs | ([$s[] | .used]) as $ys
    | (($xs | add) / $n) as $mx | (($ys | add) / $n) as $my
    | ([range(0; $n) | ($xs[.] - $mx) * ($ys[.] - $my)] | add) as $sxy
    | ([$xs[] | (. - $mx) * (. - $mx)] | add) as $sxx
    | (($n | tostring) + " " + (((($sxy / $sxx) * 100) | round) / 100 | tostring))' "$1"
}
SD_O="$TMP/s-o"
mkdir -p "$SD_O"
RESET_O=$(( T0 + 585000000 ))          # ~162.5 h out, the incident's weekly window
CUR_O=$(( RESET_O + 402 ))             # this tick's jittered stamp, colliding with two samples
mk_usage "$TMP/usage-o.json" ok 0.24 "$CUR_O"
agents_file "$TMP/agents-o.json" \
  "$(mk_agent manager wO:p1 wO idle '')" \
  "$(mk_agent issue-1 wO:p2 wO working '')"
export FAKE_USAGE="$TMP/usage-o.json" FAKE_AGENTS="$TMP/agents-o.json"
export FAKE_KEYS="$TMP/keys-o.log" FAKE_PROMPTS="$TMP/prompts-o.log"
: >"$FAKE_KEYS"; : >"$FAKE_PROMPTS"
reg "$SD_O" "$T0" ws-wO wO wO:p1 3 1 0 0 1 acme/o >/dev/null
# the incident's rows: usage creeps 0.22 -> 0.24 over 1065 s while resets_at jitters by ms
: >"$SD_O/samples.jsonl"
for row in "1065000 0.22 402" "1024000 0.23 -376" "963000 0.23 338" \
           "589000 0.23 43" "521000 0.24 402" "20000 0.24 282"; do
  set -- $row
  jq -nc --argjson t $(( T0 - $1 )) --argjson u "$2" --argjson r $(( RESET_O + $3 )) \
    '{t:$t, provider:"anthropic", limit:"anthropic:5h", used:$u, resets_at:$r, status:"ok"}' \
    >>"$SD_O/samples.jsonl"
done
# and one sample from a different window: five minutes off, it must not be fitted
jq -nc --argjson t $(( T0 - 300000 )) --argjson r $(( RESET_O + 300000 )) \
  '{t:$t, provider:"anthropic", limit:"anthropic:5h", used:0.3, resets_at:$r, status:"ok"}' \
  >>"$SD_O/samples.jsonl"
ST_O="$(MGR_GUARD_CONFIRM_TICKS=3 MGR_STATE_DIR="$SD_O" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
read -r WIN_O SLOPE_O <<<"$(fit_window "$SD_O/samples.jsonl" anthropic:5h "$CUR_O" 120000)"
read -r COLL_O COLLSLOPE_O <<<"$(fit_window "$SD_O/samples.jsonl" anthropic:5h "$CUR_O" 0)"
assert_eq "(o) the window holds seven samples (six seeded plus this tick)" 7 "$WIN_O"
assert_jq "(o) sample_count is the whole window" "$ST_O" \
  '.providers.anthropic.limits[0].sample_count == 7'
assert_jq "(o) burn_per_hour is the least-squares slope over all seven" "$ST_O" \
  '.providers.anthropic.limits[0].burn_per_hour == '"$SLOPE_O"
assert_eq "(o) ms-equality would only have seen the colliding samples" 3 "$COLL_O"
if [ "$SLOPE_O" = "$COLLSLOPE_O" ]; then
  fail "(o) the fixture does not distinguish window matching from ms equality ($SLOPE_O)"
else
  pass "(o) ms-equality slope $COLLSLOPE_O differs from the window slope $SLOPE_O"
fi
assert_jq "(o) the five-minutes-off sample is not fitted" "$ST_O" \
  '.providers.anthropic.limits[0].used == 0.24 and .providers.anthropic.limits[0].burn_per_hour > 0'
assert_jq "(o) one tick over 1 only watches, it does not constrain" "$ST_O" \
  '.constrained == false and .providers.anthropic.limits[0].over_ticks == 1
   and (.providers.anthropic.limits[0].fits | not)
   and (.providers.anthropic.reason | startswith("ok (watching: anthropic:5h projected "))
   and (.providers.anthropic.reason | endswith("tick 1/3)"))'
assert_eq "(o) nothing is interrupted" 0 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"

printf '\n== (p) a projection constrains only after CONFIRM_TICKS ticks ==\n'
SD_P="$TMP/s-p"
agents_file "$TMP/agents-p.json" \
  "$(mk_agent manager wP:p1 wP idle '')" \
  "$(mk_agent issue-1 wP:p2 wP working '')" \
  "$(mk_agent issue-2 wP:p3 wP working '')" \
  "$(mk_agent issue-3 wP:p4 wP working '')"
export FAKE_AGENTS="$TMP/agents-p.json" FAKE_KEYS="$TMP/keys-p.log" FAKE_PROMPTS="$TMP/prompts-p.log"
: >"$FAKE_KEYS"; : >"$FAKE_PROMPTS"
reg "$SD_P" "$T0" ws-wP wP wP:p1 3 3 0 0 3 acme/p >/dev/null
arm "$SD_P" "$T0" 0.25 0.50
ST_P1="$(MGR_GUARD_CONFIRM_TICKS=3 MGR_STATE_DIR="$SD_P" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(p) tick 1: ceiling kept, watching 1/3" "$ST_P1" \
  '.allowed_total == 3 and .constrained == false
   and .providers.anthropic.limits[0].over_ticks == 1
   and (.providers.anthropic.reason | startswith("ok (watching:"))
   and (.providers.anthropic.reason | endswith("tick 1/3)"))'
arm "$SD_P" $(( T0 + 60000 )) 0.25 0.50
ST_P2="$(MGR_GUARD_CONFIRM_TICKS=3 MGR_STATE_DIR="$SD_P" MGR_GUARD_NOW_MS=$(( T0 + 60000 )) "$GUARD" tick)"
assert_jq "(p) tick 2: ceiling kept, watching 2/3" "$ST_P2" \
  '.allowed_total == 3 and .constrained == false
   and .providers.anthropic.limits[0].over_ticks == 2
   and (.providers.anthropic.reason | endswith("tick 2/3)"))'
arm "$SD_P" $(( T0 + 120000 )) 0.25 0.50
ST_P3="$(MGR_GUARD_CONFIRM_TICKS=3 MGR_STATE_DIR="$SD_P" MGR_GUARD_NOW_MS=$(( T0 + 120000 )) "$GUARD" tick)"
assert_jq "(p) tick 3: the projection is confirmed and constrains" "$ST_P3" \
  '.allowed_total == 1 and .constrained == true
   and .providers.anthropic.limits[0].over_ticks == 3
   and (.providers.anthropic.reason | startswith("projected"))'
assert_jq "(p) the allowed_changed event carries the fit" "$ST_P3" \
  '[.events[] | select(.kind == "allowed_changed" and .at == '"$(( T0 + 120000 ))"')] | first
   | .fit.limit == "anthropic:5h"
     and .fit.slope == 0.5
     and (.fit.samples | length) >= 2
     and (([.fit.samples[] | select(has("t") and has("used"))] | length) == (.fit.samples | length))'
assert_jq "(p) the fit slope is the reported burn" "$ST_P3" \
  '([.events[] | select(.kind == "allowed_changed" and .at == '"$(( T0 + 120000 ))"')] | first | .fit.slope)
   == .providers.anthropic.limits[0].burn_per_hour'
arm "$SD_P" $(( T0 + 180000 )) 0.10 0.10
ST_P4="$(MGR_GUARD_CONFIRM_TICKS=3 MGR_STATE_DIR="$SD_P" MGR_GUARD_NOW_MS=$(( T0 + 180000 )) "$GUARD" tick)"
assert_jq "(p) tick 4: a fitting limit lifts the cap at once" "$ST_P4" \
  '.allowed_total == 3 and .constrained == false
   and .providers.anthropic.limits[0].over_ticks == 0
   and .providers.anthropic.reason == "ok"'
assert_eq "(p) a projection never sends keys" 0 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"

printf '\n== (q) level 1 holds at the turn boundary, level 2 interrupts ==\n'
SD_Q="$TMP/s-q"
agents_file "$TMP/agents-q-working.json" \
  "$(mk_agent manager wQ:p1 wQ idle '')" \
  "$(mk_agent issue-1 wQ:p2 wQ working '')" \
  "$(mk_agent issue-2 wQ:p3 wQ working '')" \
  "$(mk_agent issue-3 wQ:p4 wQ working '')"
agents_file "$TMP/agents-q-idle3.json" \
  "$(mk_agent manager wQ:p1 wQ idle '')" \
  "$(mk_agent issue-1 wQ:p2 wQ working '')" \
  "$(mk_agent issue-2 wQ:p3 wQ working '')" \
  "$(mk_agent issue-3 wQ:p4 wQ idle '')"
export FAKE_AGENTS="$TMP/agents-q-working.json"
export FAKE_KEYS="$TMP/keys-q.log" FAKE_PROMPTS="$TMP/prompts-q.log" FAKE_TOASTS="$TMP/toasts-q.log"
: >"$FAKE_KEYS"; : >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"
reg "$SD_Q" "$T0" ws-wQ wQ wQ:p1 3 3 0 0 3 acme/q >/dev/null
arm "$SD_Q" "$T0" 0.25 0.50
ST_Q1="$(MGR_STATE_DIR="$SD_Q" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(q) constrained by the projection alone, provider not hard" "$ST_Q1" \
  '.constrained == true and .allowed_total == 1 and .managers["ws-wQ"].allotment == 1
   and .providers.anthropic.hard == false'
assert_eq "(q) working builders are left alone" 0 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
assert_jq "(q) nothing is paused while they work" "$ST_Q1" \
  '(.stalled | length) == 0 and .managers["ws-wQ"].paused == false'
# the over-allotment builder finishes its turn -> held at the boundary, still no keys
export FAKE_AGENTS="$TMP/agents-q-idle3.json"
arm "$SD_Q" $(( T0 + 60000 )) 0.25 0.50
ST_Q2="$(MGR_STATE_DIR="$SD_Q" MGR_GUARD_NOW_MS=$(( T0 + 60000 )) "$GUARD" tick)"
assert_jq "(q) the idle over-allotment builder is held" "$ST_Q2" \
  '[.stalled[] | select(.cause == "paused")] as $p
   | ($p | length) == 1 and $p[0].pane_id == "wQ:p4" and $p[0].esc_sent == 0
     and $p[0].name == "issue-3" and $p[0].paused_at == '"$(( T0 + 60000 ))"'
     and .providers.anthropic.hard == false'
assert_eq "(q) a hold sends no keys" 0 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
assert_jq "(q) the hold is an event" "$ST_Q2" \
  '[.events[] | select(.kind == "paused") | .detail]
   | length == 1 and (.[0] | test("wQ:p4 issue-3 \\(ws-wQ priority 5, allotment 1\\)"))'
if grep -q 'paused: wQ:p4' "$FAKE_TOASTS"; then pass "(q) hold toast"; else fail "(q) no hold toast"; fi
# the provider itself goes to warning -> level 2, the working one is interrupted
arm "$SD_Q" $(( T0 + 120000 )) 0.25 0.50 warning
ST_Q3="$(MGR_STATE_DIR="$SD_Q" MGR_GUARD_NOW_MS=$(( T0 + 120000 )) "$GUARD" tick)"
assert_jq "(q) warning makes the provider hard" "$ST_Q3" '.providers.anthropic.hard == true'
assert_eq "(q) the working over-allotment builder is esc'd" "wQ:p3 esc" "$(cat "$FAKE_KEYS")"
assert_jq "(q) and it gets an esc'd entry" "$ST_Q3" \
  '[.stalled[] | select(.pane_id == "wQ:p3")] | first | .esc_sent == 1'
assert_jq "(q) the kept builder is untouched" "$ST_Q3" \
  '[.stalled[] | select(.pane_id == "wQ:p2")] | length == 0'

printf '\n== (r) room again cancels the pending esc re-send ==\n'
SD_R="$TMP/s-r"
agents_file "$TMP/agents-r.json" \
  "$(mk_agent manager wR:p1 wR idle '')" \
  "$(mk_agent issue-1 wR:p2 wR working '')" \
  "$(mk_agent issue-2 wR:p3 wR working '')" \
  "$(mk_agent issue-3 wR:p4 wR working '')"
export FAKE_AGENTS="$TMP/agents-r.json"
export FAKE_KEYS="$TMP/keys-r.log" FAKE_PROMPTS="$TMP/prompts-r.log"
: >"$FAKE_KEYS"; : >"$FAKE_PROMPTS"
reg "$SD_R" "$T0" ws-wR wR wR:p1 3 3 0 0 3 acme/r >/dev/null
arm "$SD_R" "$T0" 0.25 0.50 warning
ST_R1="$(MGR_STATE_DIR="$SD_R" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_eq "(r) two over-allotment builders interrupted, highest issue first" "wR:p4 esc
wR:p3 esc" "$(cat "$FAKE_KEYS")"
assert_jq "(r) no_room_at is this tick" "$ST_R1" '.managers["ws-wR"].no_room_at == '"$T0"
# quota recovers 30 s later: room is back, so the re-send is cancelled...
arm "$SD_R" $(( T0 + 30000 )) 0.10 0.10 warning
ST_R2="$(MGR_STATE_DIR="$SD_R" MGR_GUARD_NOW_MS=$(( T0 + 30000 )) "$GUARD" tick)"
assert_jq "(r) unconstrained again, provider still hard" "$ST_R2" \
  '.constrained == false and .allowed_total == 3 and .providers.anthropic.hard == true'
assert_eq "(r) no second esc once the manager has room" 2 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"
assert_jq "(r) esc_sent stays 1" "$ST_R2" \
  '[.stalled[] | select(.cause == "paused") | .esc_sent] == [1,1]'
assert_eq "(r) ... and no resume inside the cooldown" 0 "$(wc -l <"$FAKE_PROMPTS" | tr -d ' ')"
assert_jq "(r) no_room_at still points at the constrained tick" "$ST_R2" \
  '.managers["ws-wR"].no_room_at == '"$T0"
# ... and 61 s after that tick the cooldown is over
arm "$SD_R" $(( T0 + 61000 )) 0.10 0.10 warning
ST_R3="$(MGR_STATE_DIR="$SD_R" MGR_GUARD_NOW_MS=$(( T0 + 61000 )) "$GUARD" tick)"
assert_eq "(r) both resumed, lowest issue number first" "wR:p3
wR:p4" "$(cut -f1 <"$FAKE_PROMPTS")"
assert_jq "(r) the entries are gone" "$ST_R3" '(.stalled | length) == 0'
assert_eq "(r) still only the two original esc" 2 "$(wc -l <"$FAKE_KEYS" | tr -d ' ')"

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
assert_jq "no managers -> top_priority/top_cap null" "$ST_Y" '.top_priority == null and .top_cap == null'

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'guard-smoke: all assertions passed\n'
  exit 0
fi
printf 'guard-smoke: %d assertion(s) failed\n' "$FAILURES"
exit 1
