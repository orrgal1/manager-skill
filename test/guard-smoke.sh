#!/usr/bin/env bash
# guard-smoke.sh — self-contained smoke test for bin/mgr-guard.
# Fakes `omp`, `herdr` and `gh` on PATH, pins the clock with MGR_GUARD_NOW_MS and
# keeps every byte of state in a temp dir. Never touches the live herdr session.
# The guard has three jobs here: the 429 ledger with its reignitions, the burn projection,
# and the backlog/throughput collection behind `overview`. Anything that dials pace is gone,
# and this file proves it stays gone.
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
lines_of() { # lines_of <file>: 0 for an empty or absent file
  [ -s "$1" ] || { printf '0'; return; }
  wc -l <"$1" | tr -d ' '
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
    printf '%s\n' "$prov" >>"${FAKE_FETCHES:-/dev/null}"
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
    # nothing in the watered-down guard ever interrupts a builder; the suite asserts
    # this log stays empty from the first tick to the last
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

cat >"$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${FAKE_GH_LOG:-/dev/null}"
case "${1:-}/${2:-}" in
  issue/list)
    if [ -n "${FAKE_ISSUES:-}" ] && [ -f "${FAKE_ISSUES:-}" ]; then
      cat "$FAKE_ISSUES"
    else
      printf 'fake gh: no issue fixture\n' >&2; exit 1
    fi;;
  *) printf 'fake gh: unsupported: %s\n' "$*" >&2; exit 1;;
esac
FAKE

chmod +x "$BIN/omp" "$BIN/herdr" "$BIN/gh"
PATH="$BIN:$PATH"; export PATH
# one key log for the whole suite: a single line in it means pace-dialing came back
FAKE_KEYS="$TMP/keys-all.log"; export FAKE_KEYS; : >"$FAKE_KEYS"

# ------------------------------------------------------------------ fixtures

T0=1700000000000   # pinned "now" base, ms, divisible by 1000

iso_ms() { # iso_ms <ms> -> 2023-11-14T22:13:20.000Z (session timestamps)
  local s=$(( ${1} / 1000 ))
  # GNU date renders an epoch with -d @N; BSD/macOS date uses -r N
  if date --version >/dev/null 2>&1; then
    date -u -d "@$s" +%Y-%m-%dT%H:%M:%S.000Z
  else
    date -u -r "$s" +%Y-%m-%dT%H:%M:%S.000Z
  fi
}

iso_of() { # iso_of <ms> -> 2023-11-14T22:13:20Z (the guard's own rendering)
  local s=$(( ${1} / 1000 ))
  if date --version >/dev/null 2>&1; then
    date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -r "$s" +%Y-%m-%dT%H:%M:%SZ
  fi
}

hhmm_of() { # hhmm_of <ms> -> 17:00Z (what the reason sentence prints)
  local s=$(( ${1} / 1000 ))
  if date --version >/dev/null 2>&1; then
    date -u -d "@$s" +%H:%MZ
  else
    date -u -r "$s" +%H:%MZ
  fi
}

mk_usage() { # mk_usage <file> <status> <used-fraction> <resets-at-ms>
  # written whole then renamed: the daemon scenario flips this file under a live fake `omp`
  jq -n --arg st "$2" --argjson uf "$3" --argjson r "$4" '
    {generatedAt: 0,
     reports: [{provider: "anthropic", fetchedAt: 0,
       limits: [{id: "anthropic:5h", label: "Claude 5 Hour",
                 scope: {provider: "anthropic", windowId: "5h", shared: true},
                 window: {id: "5h", label: "5 hours", durationMs: 18000000, resetsAt: $r},
                 amount: {used: ($uf * 100), limit: 100, remaining: ((1 - $uf) * 100),
                          usedFraction: $uf, remainingFraction: (1 - $uf), unit: "percent"},
                 status: $st}],
       metadata: {}}]}' >"$1.tmp" && mv -f "$1.tmp" "$1"
}

mk_usage2() { # mk_usage2 <file> <a-status> <a-used> <a-reset> <o-status> <o-used> <o-reset>
  # a two-subscription fixture: anthropic:5h and openai-codex:5h, individually fetchable
  # exactly like mk_usage's single report -- the fake omp usage filters .reports by --provider
  jq -n --arg ast "$2" --argjson auf "$3" --argjson ar "$4" \
        --arg ost "$5" --argjson ouf "$6" --argjson or "$7" '
    {generatedAt: 0,
     reports: [
       {provider: "anthropic", fetchedAt: 0,
        limits: [{id: "anthropic:5h", label: "Claude 5 Hour",
                  scope: {provider: "anthropic", windowId: "5h", shared: true},
                  window: {id: "5h", label: "5 hours", durationMs: 18000000, resetsAt: $ar},
                  amount: {used: ($auf * 100), limit: 100, remaining: ((1 - $auf) * 100),
                           usedFraction: $auf, remainingFraction: (1 - $auf), unit: "percent"},
                  status: $ast}],
        metadata: {}},
       {provider: "openai-codex", fetchedAt: 0,
        limits: [{id: "openai-codex:5h", label: "Codex 5 Hour",
                  scope: {provider: "openai-codex", windowId: "5h", shared: true},
                  window: {id: "5h", label: "5 hours", durationMs: 18000000, resetsAt: $or},
                  amount: {used: ($ouf * 100), limit: 100, remaining: ((1 - $ouf) * 100),
                           usedFraction: $ouf, remainingFraction: (1 - $ouf), unit: "percent"},
                  status: $ost}],
        metadata: {}}
     ]}' >"$1.tmp" && mv -f "$1.tmp" "$1"
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

reg() { # reg <state-dir> <now-ms> <manager_id> <ws> <pane> <cap> <in_flight> <adopting> <ready> [repo] [provider] [house]
  local sd="$1" now="$2" repo="${10:-acme/widgets}" prov="${11:-}" house="${12:-}"
  MGR_STATE_DIR="$sd" MGR_GUARD_NOW_MS="$now" "$GUARD" register "$(jq -nc \
    --arg id "$3" --arg ws "$4" --arg pane "$5" --arg repo "$repo" \
    --argjson cap "$6" --argjson inf "$7" --argjson ad "$8" --argjson rd "$9" \
    --arg prov "$prov" --arg house "$house" '
    {manager_id:$id, workspace_id:$ws, pane_id:$pane, repo:$repo,
     primary:"/Users/x/code/widgets", cap:$cap, paused_by_operator:false,
     in_flight:$inf, adopting:$ad, ready:$rd}
    + (if $prov == "" then {} else {provider:$prov} end)
    + (if $house == "" then {} else {house:$house} end)')"
}

mk_issue() { # mk_issue <number> <title> <labels-csv> <body>
  jq -nc --argjson n "$1" --arg t "$2" --arg l "$3" --arg b "$4" \
    '{number:$n, title:$t, body:$b,
      labels: ($l | if . == "" then [] else split(",") end | map({name:.}))}'
}

issues_file() { # issues_file <file> <issue-json...>
  local out="$1"; shift
  printf '%s\n' "$@" | jq -sc . >"$out"
}

launches_file() { # launches_file <state-dir> <repo> <"number:launched_at"...>
  local sd="$1" repo="$2"; shift 2
  local slug pair obj='{}'
  slug=$(printf '%s' "$repo" | sed 's|/|__|g')
  mkdir -p "$sd/launches"
  for pair in "$@"; do
    obj=$(jq -c --argjson n "${pair%%:*}" --argjson at "${pair##*:}" \
      '. + {($n | tostring): {number:$n, launched_at:$at}}' <<<"$obj")
  done
  printf '%s\n' "$obj" >"$sd/launches/$slug.json"
}

thru_file() { # thru_file <state-dir> <repo> <duration_s...>
  local sd="$1" repo="$2"; shift 2
  local slug d n=1
  slug=$(printf '%s' "$repo" | sed 's|/|__|g')
  mkdir -p "$sd/throughput"
  : >"$sd/throughput/$slug.jsonl"
  for d in "$@"; do
    jq -nc --arg r "$repo" --argjson n "$n" --argjson d "$d" \
      '{repo:$r, number:$n, launched_at:0, merged_at:($d * 1000), duration_s:$d}' \
      >>"$sd/throughput/$slug.jsonl"
    n=$((n + 1))
  done
}

arm() { # arm <state-dir> <now-ms> <used-prev> <used-now> [status] [reset-offset-ms]
  # seed one prior sample half an hour back plus this tick's reading: the fit then has a
  # 30-minute span, which is exactly MGR_GUARD_MIN_SLOPE_SPAN_S
  local sd="$1" now="$2" prev="$3" cur="$4" status="${5:-ok}" off="${6:-7200000}" reset usage
  reset=$(( now + off ))
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
for c in start stop status overview tick run register touch stall; do
  case "$HELP" in *"mgr-guard $c"*) pass "--help lists $c";; *) fail "--help is missing $c";; esac
done
for c in priority pause unpause paused; do
  case "$HELP" in *"mgr-guard $c"*) fail "--help still mentions $c";; *) pass "--help does not mention $c";; esac
done
for e in MGR_STATE_DIR MGR_GUARD_INTERVAL MGR_GUARD_SLOPE_WINDOW_S MGR_GUARD_MIN_SLOPE_SPAN_S \
         MGR_GUARD_IDLE_EXIT_S MGR_GUARD_NOTIFY MGR_GUARD_BACKLOG_INTERVAL_S MGR_DEFAULT_TASK_S; do
  case "$HELP" in *"$e"*) pass "--help lists $e";; *) fail "--help is missing $e";; esac
done
for e in MGR_GUARD_CONFIRM_TICKS MGR_GUARD_RESUME_COOLDOWN_S; do
  case "$HELP" in *"$e"*) fail "--help still lists $e";; *) pass "--help drops $e";; esac
done
"$GUARD" nonsense >/dev/null 2>&1; assert_eq "unknown subcommand exit code" 2 "$?"
SD_GONE="$TMP/s-gone"
for c in priority pause unpause paused; do
  MGR_STATE_DIR="$SD_GONE" "$GUARD" "$c" acme/x >/dev/null 2>&1
  assert_eq "$c is not a subcommand any more" 2 "$?"
done
if [ -e "$SD_GONE/priorities.json" ] || [ -e "$SD_GONE/paused.json" ]; then
  fail "a removed subcommand wrote a store"
else
  pass "no priorities.json / paused.json is ever written"
fi

printf '\n== (a) stall rule: 429 only, no --pane ==\n'
S_A="$(MGR_STATE_DIR="$TMP/s-a" "$GUARD" stall "$SESS_ANTHROPIC")"
assert_json "stall (anthropic)" "$S_A"
assert_jq "stall anthropic provider/retry/model" "$S_A" \
  '.provider == "anthropic" and .retry_after_ms == 976000 and .model == "claude-fable-5-1" and .since == '"$T0"
S_G="$(MGR_STATE_DIR="$TMP/s-a" "$GUARD" stall "$SESS_GOOGLE")"
assert_jq "stall google (no errorStatus, RESOURCE_EXHAUSTED matches RATE_RE)" "$S_G" \
  '.provider == "google-antigravity" and .retry_after_ms == null and (.error | test("RESOURCE_EXHAUSTED"))'
S_C="$(MGR_STATE_DIR="$TMP/s-a" "$GUARD" stall "$SESS_CLEAN")"
assert_eq "stall on clean last message" "null" "$S_C"
MGR_STATE_DIR="$TMP/s-a" "$GUARD" stall "$TMP/nope.jsonl" >/dev/null 2>&1
assert_eq "stall on missing file exit code" 4 "$?"
PANE_ERR="$(MGR_STATE_DIR="$TMP/s-a" "$GUARD" stall --pane w3:p9 "$SESS_ANTHROPIC" 2>&1)"
assert_eq "stall --pane exit code" 2 "$?"
assert_jq "stall --pane is an unknown option" "$PANE_ERR" \
  '.error.code == 2 and (.error.message | test("usage: mgr-guard stall <session.jsonl>"))'

printf '\n== register validation (no demand key any more) ==\n'
SD_REG="$TMP/s-reg"
BAD_OUT="$(MGR_STATE_DIR="$SD_REG" "$GUARD" register '{"manager_id":"ws-w9"}' 2>&1)"
assert_eq "register missing keys exit code" 2 "$?"
assert_jq "register missing keys error shape" "$BAD_OUT" '.error.code == 2 and (.error.message | test("missing keys"))'
assert_jq "the missing-key list has no demand" "$BAD_OUT" '.error.message | test("demand") | not'
R_OK="$(reg "$SD_REG" "$T0" ws-w9 w9 w9:p1 3 1 0 2)"
assert_eq "register without demand exit code" 0 "$?"
assert_jq "register writes seen_at and the payload" "$R_OK" \
  '.manager_id == "ws-w9" and .seen_at == '"$T0"' and .cap == 3 and (has("demand") | not)'
BAD_NUM="$(MGR_STATE_DIR="$SD_REG" "$GUARD" register \
  '{"manager_id":"ws-w9","workspace_id":"w9","pane_id":"w9:p1","repo":"a/b","primary":"/p","cap":"3","in_flight":0,"adopting":0,"ready":0}' 2>&1)"
assert_eq "register non-number exit code" 2 "$?"
assert_jq "register non-number error" "$BAD_NUM" '.error.message | test("not numbers: cap")'

printf '\n== (b) managers: liveness, dead drop, last_report files ==\n'
SD_B="$TMP/s-b"
STALE_B=$(( T0 - 7200000 ))     # two hours old: a 429-stalled manager stops running mgr board
mk_usage "$TMP/usage-ok.json" ok 0.10 $(( T0 + 7200000 ))
agents_file "$TMP/agents-b.json" "$(mk_agent manager w3:p1 w3 idle '')"
export FAKE_AGENTS="$TMP/agents-b.json" FAKE_USAGE="$TMP/usage-ok.json"
export FAKE_PROMPTS="$TMP/prompts-b.log" FAKE_TOASTS="$TMP/toasts-b.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"
reg "$SD_B" "$STALE_B" ws-w3 w3 w3:p1 3 2 0 4 >/dev/null
reg "$SD_B" "$STALE_B" ws-w7 w7 w7:p1 3 0 0 1 >/dev/null
# `mgr board` files its last projection next to the registration; the guard's glob must
# skip it (this one carries a manager_id on purpose: picked up, it would look like a
# registration with no pane and drop the live ws-w3 with it)
for id in ws-w3 ws-w7; do
  jq -nc --arg id "$id" --argjson at "$STALE_B" \
    '{at:$at, manager_id:$id, provider:"anthropic",
      limits:[{id:"anthropic:5h", projected_at_reset:1.04, fits:false}]}' \
    >"$SD_B/managers/$id.last_report.json"
done
ST_B="$(MGR_STATE_DIR="$SD_B" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_json "tick output" "$ST_B"
assert_jq "(b) state version 2"        "$ST_B" '.version == 2 and .builder_provider == "anthropic" and .interval_s == 60'
assert_jq "(b) state top-level shape"  "$ST_B" \
  '(keys) == ["builder_provider","events","interval_s","managers","pid","providers","stalled","tick_at","version"]'
assert_jq "(b) stale heartbeat + live pane is live" "$ST_B" \
  '.managers["ws-w3"] | .live == true and .pane_alive == true and .seen_at == '"$STALE_B"
assert_jq "(b) the row is the registration plus liveness and this tick's collection" "$ST_B" \
  '(.managers["ws-w3"] | keys)
   == ["adopting","backlog","backlog_at","backlog_error","cap","in_flight","live","manager_id",
       "pane_alive","pane_id","paused_by_operator","primary","ready","repo","seen_at",
       "throughput","workspace_id"]'
assert_jq "(b) with no gh fixture the backlog is absent and says why" "$ST_B" \
  '.managers["ws-w3"] | .backlog == null and .backlog_at == null
   and .backlog_error == "gh issue list failed"
   and .throughput.source == "default" and .throughput.median_s == 2700 and .throughput.n == 0'
assert_jq "(b) the pane that is gone is the only one dropped" "$ST_B" '(.managers | keys) == ["ws-w3"]'
assert_jq "(b) manager_dropped event" "$ST_B" \
  '[.events[] | select(.kind == "manager_dropped")] | last | .detail == "ws-w7: pane w7:p1 is gone"'
if [ -f "$SD_B/managers/ws-w7.json" ]; then fail "(b) ws-w7.json still on disk"; else pass "(b) ws-w7.json deleted"; fi
if [ -f "$SD_B/managers/ws-w7.last_report.json" ]; then
  fail "(b) ws-w7.last_report.json survived the dead registration"
else
  pass "(b) ws-w7.last_report.json removed with the registration"
fi
if [ -f "$SD_B/managers/ws-w3.json" ]; then pass "(b) ws-w3.json kept"; else fail "(b) ws-w3.json deleted"; fi
if [ -f "$SD_B/managers/ws-w3.last_report.json" ]; then
  pass "(b) the live manager keeps its last_report.json"
else
  fail "(b) ws-w3.last_report.json was deleted"
fi
assert_jq "(b) no stalls, no events beyond the drop" "$ST_B" \
  '(.stalled | length) == 0 and ([.events[] | select(.kind != "manager_dropped")] | length) == 0'
STATUS_B="$(MGR_STATE_DIR="$SD_B" "$GUARD" status)"
assert_json "status output" "$STATUS_B"
assert_jq "status guard=stopped, pid null, state passthrough" "$STATUS_B" \
  '.guard == "stopped" and .pid == null and .version == 2 and (.managers | keys) == ["ws-w3"]'
assert_jq "status last_exit is null before any exit" "$STATUS_B" \
  '.last_exit_at == null and .last_exit_reason == null'

printf '\n== (c) the burn projection: limits shape, windowed fit, samples in state ==\n'
SD_C="$TMP/s-c"
mkdir -p "$SD_C"
RESET_C=$(( T0 + 585000000 ))          # ~162.5 h out, the incident's weekly window
CUR_C=$(( RESET_C + 402 ))             # this tick's jittered stamp, colliding with two samples
mk_usage "$TMP/usage-c.json" ok 0.24 "$CUR_C"
agents_file "$TMP/agents-c.json" \
  "$(mk_agent manager wO:p1 wO idle '')" \
  "$(mk_agent issue-1 wO:p2 wO working '')"
export FAKE_USAGE="$TMP/usage-c.json" FAKE_AGENTS="$TMP/agents-c.json"
export FAKE_PROMPTS="$TMP/prompts-c.log"; : >"$FAKE_PROMPTS"
reg "$SD_C" "$T0" ws-wO wO wO:p1 3 1 0 0 acme/o >/dev/null
# the incident's rows: usage creeps 0.22 -> 0.24 over 1065 s while resets_at jitters by ms
: >"$SD_C/samples.jsonl"
for row in "1065000 0.22 402" "1024000 0.23 -376" "963000 0.23 338" \
           "589000 0.23 43" "521000 0.24 402" "20000 0.24 282"; do
  set -- $row
  jq -nc --argjson t $(( T0 - $1 )) --argjson u "$2" --argjson r $(( RESET_C + $3 )) \
    '{t:$t, provider:"anthropic", limit:"anthropic:5h", used:$u, resets_at:$r, status:"ok"}' \
    >>"$SD_C/samples.jsonl"
done
# and one sample from a different window: five minutes off, it must not be fitted
jq -nc --argjson t $(( T0 - 300000 )) --argjson r $(( RESET_C + 300000 )) \
  '{t:$t, provider:"anthropic", limit:"anthropic:5h", used:0.3, resets_at:$r, status:"ok"}' \
  >>"$SD_C/samples.jsonl"
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
ST_C="$(MGR_STATE_DIR="$SD_C" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
read -r WIN_C SLOPE_C <<<"$(fit_window "$SD_C/samples.jsonl" anthropic:5h "$CUR_C" 120000)"
read -r COLL_C COLLSLOPE_C <<<"$(fit_window "$SD_C/samples.jsonl" anthropic:5h "$CUR_C" 0)"
assert_jq "(c) provider row shape" "$ST_C" \
  '(.providers.anthropic | keys)
   == ["exhausted_limit","fetched_at","limits","ok","reason","recovers_at","status","usage_fetch_failures"]'
assert_jq "(c) limit row shape" "$ST_C" \
  '(.providers.anthropic.limits[0] | keys)
   == ["burn_per_hour","fits","hours_to_reset","id","label","projected_at_reset","resets_at",
       "sample_count","samples","status","used"]'
assert_jq "(c) a successful fetch is ok with zero failures" "$ST_C" \
  '.providers.anthropic.ok == true and .providers.anthropic.usage_fetch_failures == 0
   and .providers.anthropic.status == "ok" and .providers.anthropic.recovers_at == null'
assert_eq "(c) the window holds seven samples (six seeded plus this tick)" 7 "$WIN_C"
assert_jq "(c) sample_count is the whole window" "$ST_C" \
  '.providers.anthropic.limits[0].sample_count == 7'
assert_jq "(c) the fitted samples stay in state" "$ST_C" \
  '(.providers.anthropic.limits[0].samples | length) == 7
   and ([.providers.anthropic.limits[0].samples[] | select((.t | type) == "number" and (.used | type) == "number")] | length) == 7
   and (.providers.anthropic.limits[0].samples | sort_by(.t)) == .providers.anthropic.limits[0].samples'
assert_jq "(c) burn_per_hour is the least-squares slope over all seven" "$ST_C" \
  '.providers.anthropic.limits[0].burn_per_hour == '"$SLOPE_C"
assert_eq "(c) ms-equality would only have seen the colliding samples" 3 "$COLL_C"
if [ "$SLOPE_C" = "$COLLSLOPE_C" ]; then
  fail "(c) the fixture does not distinguish window matching from ms equality ($SLOPE_C)"
else
  pass "(c) ms-equality slope $COLLSLOPE_C differs from the window slope $SLOPE_C"
fi
assert_jq "(c) the five-minutes-off sample is not fitted" "$ST_C" \
  '.providers.anthropic.limits[0].used == 0.24 and .providers.anthropic.limits[0].burn_per_hour > 0'
assert_jq "(c) hours_to_reset and the projection" "$ST_C" \
  '.providers.anthropic.limits[0]
   | .hours_to_reset == ((('"$CUR_C"' - '"$T0"') / 3600000 * 100 | round) / 100)
     and .projected_at_reset > 1 and (.fits | not)'
ST_C2="$(MGR_GUARD_MIN_SLOPE_SPAN_S=7200 MGR_STATE_DIR="$SD_C" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(c) a span shorter than MIN_SLOPE_SPAN_S is not fitted" "$ST_C2" \
  '.providers.anthropic.limits[0].burn_per_hour == 0
   and .providers.anthropic.limits[0].projected_at_reset == 0.24
   and .providers.anthropic.limits[0].fits == true'
assert_eq "(c) a projection prompts nobody" 0 "$(lines_of "$FAKE_PROMPTS")"

printf '\n== (d) the reason sentence ==\n'
SD_D="$TMP/s-d"
agents_file "$TMP/agents-d.json" "$(mk_agent manager wD:p1 wD idle '')"
export FAKE_AGENTS="$TMP/agents-d.json"
reg "$SD_D" "$T0" ws-wD wD wD:p1 3 1 0 0 acme/d >/dev/null
# 0.10 -> 0.20 over half an hour is 0.2/h; 11.8 h to reset projects 0.2 + 2.36 = 2.56
arm "$SD_D" "$T0" 0.10 0.20 ok 42480000
ST_D="$(MGR_STATE_DIR="$SD_D" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
EXP_D="anthropic:5h at 20% burning 0.2/h → 2.56× the window by $(hhmm_of $(( T0 + 42480000 )))"
assert_eq "(d) over-limit reason" "$EXP_D" "$(jq -r '.providers.anthropic.reason' <<<"$ST_D")"
assert_jq "(d) the numbers behind the sentence" "$ST_D" \
  '.providers.anthropic.limits[0]
   | .used == 0.2 and .burn_per_hour == 0.2 and .projected_at_reset == 2.56
     and .hours_to_reset == 11.8 and (.fits | not)'
arm "$SD_D" $(( T0 + 60000 )) 0.20 0.20 ok 42480000
ST_D2="$(MGR_STATE_DIR="$SD_D" MGR_GUARD_NOW_MS=$(( T0 + 60000 )) "$GUARD" tick)"
assert_eq "(d) a flat reading fits" "fits" "$(jq -r '.providers.anthropic.reason' <<<"$ST_D2")"
assert_jq "(d) fits means projected <= 1" "$ST_D2" \
  '.providers.anthropic.limits[0] | .burn_per_hour == 0 and .fits == true'

printf '\n== (e) exhausted: the ledger fills, nothing is reignited ==\n'
SD_E="$TMP/s-e"
agents_file "$TMP/agents-e.json" \
  "$(mk_agent manager w3:p1 w3 idle '')" \
  "$(mk_agent issue-9 w3:p9 w3 blocked "$SESS_ANTHROPIC")"
export FAKE_AGENTS="$TMP/agents-e.json"
export FAKE_PROMPTS="$TMP/prompts-e.log" FAKE_TOASTS="$TMP/toasts-e.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"
NOW_E=$(( T0 + 1000 ))
RECOV_E=$(( NOW_E + 3600000 ))
mk_usage "$TMP/usage-e-exhausted.json" exhausted 1 "$RECOV_E"
export FAKE_USAGE="$TMP/usage-e-exhausted.json"
reg "$SD_E" "$NOW_E" ws-w3 w3 w3:p1 3 1 0 0 >/dev/null
ST_E="$(MGR_STATE_DIR="$SD_E" MGR_GUARD_NOW_MS="$NOW_E" "$GUARD" tick)"
assert_jq "(e) status exhausted with recovers_at and the limit that did it" "$ST_E" \
  '.providers.anthropic.status == "exhausted" and .providers.anthropic.ok == true
   and .providers.anthropic.recovers_at == '"$RECOV_E"' and .providers.anthropic.exhausted_limit == "anthropic:5h"'
assert_jq "(e) the reason says exhausted, not fits" "$ST_E" \
  '.providers.anthropic.reason == "anthropic:5h exhausted, resets at " + ((('"$RECOV_E"' / 1000) | todate)[11:16]) + "Z"'
assert_jq "(e) exactly one exhausted event" "$ST_E" \
  '[.events[] | select(.kind == "exhausted")] | length == 1'
assert_jq "(e) the exhausted event names the reset" "$ST_E" \
  '[.events[] | select(.kind == "exhausted")] | first | .detail == "anthropic: exhausted until '"$(iso_of "$RECOV_E")"'"'
assert_jq "(e) stall entry shape" "$ST_E" \
  '(.stalled | length) == 1 and (.stalled[0] | keys)
   == ["attempts","error","last_reignite_at","limit","manager_id","model","name","next_reignite_at",
       "pane_id","provider","recovers_at","retry_after_ms","session","since","workspace_id"]'
assert_jq "(e) the entry is attributed and carries recovers_at" "$ST_E" \
  '.stalled[0] | .pane_id == "w3:p9" and .name == "issue-9" and .manager_id == "ws-w3"
   and .provider == "anthropic" and .retry_after_ms == 976000 and .since == '"$T0"'
   and .attempts == 0 and .last_reignite_at == null and .recovers_at == '"$RECOV_E"' and .limit == "anthropic:5h"'
assert_jq "(e) next_reignite_at is since + min(retry_after, 15m)" "$ST_E" \
  '.stalled[0].next_reignite_at == '"$(( T0 + 900000 ))"
# the status-line extension (extensions/mgr-status.ts) reads these by name, off
# the same file, so a rename here has to break a test rather than a status line
assert_jq "(e) fields extensions/mgr-status.ts reads exist" "$ST_E" \
  'has("pid") and has("tick_at") and has("interval_s")
   and (.stalled[0] | has("pane_id") and has("provider") and has("limit")
        and has("recovers_at") and has("next_reignite_at") and has("manager_id"))'
assert_jq "(e) fields extensions/mgr-status.ts reads exist: the burn item" "$ST_E" \
  '(.providers.anthropic | has("recovers_at"))
   and (.providers.anthropic.limits[0] | has("id") and has("used") and has("burn_per_hour")
        and has("projected_at_reset") and has("resets_at") and has("fits"))'
assert_jq "(e) fields extensions/mgr-status.ts reads exist: the manager row" "$ST_E" \
  '.managers["ws-w3"] | has("workspace_id") and has("pane_id") and has("paused_by_operator")'
assert_eq "(e) no prompt while exhausted" 0 "$(lines_of "$FAKE_PROMPTS")"
assert_eq "(e) and no toast for an exhausted provider" 0 "$(lines_of "$FAKE_TOASTS")"
# past the backoff, still exhausted, reset still ahead -> still nothing
ST_E2="$(MGR_STATE_DIR="$SD_E" MGR_GUARD_NOW_MS=$(( T0 + 900001 )) "$GUARD" tick)"
assert_jq "(e) the entry is due but exhausted blocks it" "$ST_E2" \
  '.stalled[0].next_reignite_at <= .tick_at and .stalled[0].attempts == 0
   and .providers.anthropic.status == "exhausted"'
assert_eq "(e) no reignite on exhausted" 0 "$(lines_of "$FAKE_PROMPTS")"
assert_jq "(e) no reignite event either" "$ST_E2" '[.events[] | select(.kind == "reignite")] | length == 0'

printf '\n== (f) a positive reading reignites once, then backs off ==\n'
NOW_F=$(( T0 + 900002 ))
mk_usage "$TMP/usage-f-back.json" ok 0.20 $(( NOW_F + 3600000 ))
export FAKE_USAGE="$TMP/usage-f-back.json"
ST_F="$(MGR_STATE_DIR="$SD_E" MGR_GUARD_NOW_MS="$NOW_F" "$GUARD" tick)"
assert_eq "(f) exactly one prompt" 1 "$(lines_of "$FAKE_PROMPTS")"
assert_eq "(f) prompt targets the stalled pane" "w3:p9" "$(cut -f1 <"$FAKE_PROMPTS")"
EXP_F="mgr-guard: anthropic:5h reset at $(iso_of "$RECOV_E"), now at 20%. Your previous turn stopped on a provider rate limit (429). Nobody needs to answer anything — resume exactly where you stopped and continue under your existing instructions."
assert_eq "(f) reignite text" "$EXP_F" "$(cut -f2 <"$FAKE_PROMPTS")"
if grep -q 'available again' "$FAKE_PROMPTS"; then
  fail "(f) the prompt still says 'available again'"
else
  pass "(f) the prompt never says 'available again'"
fi
assert_jq "(f) attempts 1, last_reignite_at, 15m backoff" "$ST_F" \
  '.stalled[0] | .attempts == 1 and .last_reignite_at == '"$NOW_F"'
   and .next_reignite_at == '"$(( NOW_F + 900000 ))"
assert_jq "(f) reignite and recovered events" "$ST_F" \
  '([.events[] | select(.kind == "reignite")] | length) == 1
   and ([.events[] | select(.kind == "reignite")] | first | .detail == "w3:p9 (anthropic, anthropic:5h)")
   and ([.events[] | select(.kind == "recovered" and .at == '"$NOW_F"')] | length) == 1'
assert_eq "(f) one toast, for the reignite only" 1 "$(lines_of "$FAKE_TOASTS")"
assert_eq "(f) the toast is the reignite" "reignite: w3:p9 (anthropic, anthropic:5h)" "$(cat "$FAKE_TOASTS")"
ST_F2="$(MGR_STATE_DIR="$SD_E" MGR_GUARD_NOW_MS=$(( NOW_F + 1000 )) "$GUARD" tick)"
assert_eq "(f) no second prompt inside the backoff" 1 "$(lines_of "$FAKE_PROMPTS")"
assert_jq "(f) attempts stay 1" "$ST_F2" '.stalled[0].attempts == 1'
# the schedule itself: 15m, 30m, 1h, 2h, then capped at 2h
DUE=$(( NOW_F + 900000 ))
for want in 1800000 3600000 7200000 7200000; do
  mk_usage "$TMP/usage-f-back.json" ok 0.20 $(( DUE + 3600000 ))
  ST_FN="$(MGR_STATE_DIR="$SD_E" MGR_GUARD_NOW_MS="$DUE" "$GUARD" tick)"
  GOT=$(( $(jq -r '.stalled[0].next_reignite_at' <<<"$ST_FN") - DUE ))
  assert_eq "(f) backoff after attempt $(jq -r '.stalled[0].attempts' <<<"$ST_FN")" "$want" "$GOT"
  DUE=$(( DUE + want ))
done
assert_eq "(f) one prompt per due tick" 5 "$(lines_of "$FAKE_PROMPTS")"

printf '\n== (g) a failed fetch holds the last verdict and never reignites ==\n'
SD_G="$TMP/s-g"
agents_file "$TMP/agents-g.json" \
  "$(mk_agent manager wG:p1 wG idle '')" \
  "$(mk_agent issue-9 wG:p9 wG blocked "$SESS_ANTHROPIC")"
export FAKE_AGENTS="$TMP/agents-g.json"
export FAKE_PROMPTS="$TMP/prompts-g.log" FAKE_TOASTS="$TMP/toasts-g.log" FAKE_FETCHES="$TMP/fetches-g.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"; : >"$FAKE_FETCHES"
RECOV_G=$(( T0 + 7200000 ))
mk_usage "$TMP/usage-g.json" exhausted 1 "$RECOV_G"
export FAKE_USAGE="$TMP/usage-g.json"
reg "$SD_G" "$T0" ws-wG wG wG:p1 3 1 0 0 acme/g >/dev/null
MGR_STATE_DIR="$SD_G" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick >/dev/null
assert_eq "(g) a successful fetch is fetched once" 1 "$(lines_of "$FAKE_FETCHES")"
export FAKE_USAGE="$TMP/does-not-exist.json"
: >"$FAKE_FETCHES"
ST_G1="$(MGR_STATE_DIR="$SD_G" MGR_GUARD_NOW_MS=$(( T0 + 900001 )) "$GUARD" tick)"
assert_eq "(g) a failing fetch is retried once inside the tick" 2 "$(lines_of "$FAKE_FETCHES")"
assert_eq "(g) holding reason" \
  "unknown: holding last verdict (exhausted until $(iso_of "$RECOV_G"))" \
  "$(jq -r '.providers.anthropic.reason' <<<"$ST_G1")"
assert_jq "(g) the held verdict keeps status and recovers_at" "$ST_G1" \
  '.providers.anthropic | .status == "exhausted" and .ok == false
   and .recovers_at == '"$RECOV_G"' and .usage_fetch_failures == 1'
assert_jq "(g) the carried limits are still there" "$ST_G1" \
  '(.providers.anthropic.limits | length) == 1 and .providers.anthropic.limits[0].id == "anthropic:5h"'
assert_jq "(g) the entry is due, unknown provider, still no reignite" "$ST_G1" \
  '.stalled[0].next_reignite_at <= .tick_at and .stalled[0].attempts == 0
   and .stalled[0].recovers_at == '"$RECOV_G"
assert_eq "(g) no prompt while the fetch is failing" 0 "$(lines_of "$FAKE_PROMPTS")"
ST_G2="$(MGR_STATE_DIR="$SD_G" MGR_GUARD_NOW_MS=$(( T0 + 900002 )) "$GUARD" tick)"
assert_jq "(g) consecutive failures are counted" "$ST_G2" \
  '.providers.anthropic.usage_fetch_failures == 2 and .providers.anthropic.ok == false'
mk_usage "$TMP/usage-g.json" ok 0.05 $(( T0 + 900003 + 3600000 ))
export FAKE_USAGE="$TMP/usage-g.json"
ST_G3="$(MGR_STATE_DIR="$SD_G" MGR_GUARD_NOW_MS=$(( T0 + 900003 )) "$GUARD" tick)"
assert_jq "(g) a good fetch resets the failure count" "$ST_G3" \
  '.providers.anthropic.usage_fetch_failures == 0 and .providers.anthropic.ok == true
   and .providers.anthropic.status == "ok"'
assert_eq "(g) and now it reignites" 1 "$(lines_of "$FAKE_PROMPTS")"
unset FAKE_FETCHES

printf '\n== (h) no reading at all, but the reset has passed ==\n'
SD_H="$TMP/s-h"
agents_file "$TMP/agents-h.json" \
  "$(mk_agent manager wH:p1 wH idle '')" \
  "$(mk_agent issue-9 wH:p9 wH blocked "$SESS_ANTHROPIC")"
export FAKE_AGENTS="$TMP/agents-h.json"
export FAKE_PROMPTS="$TMP/prompts-h.log" FAKE_TOASTS="$TMP/toasts-h.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"
RECOV_H=$(( T0 + 61000 ))       # the window resets long before the 15-minute backoff is up
mk_usage "$TMP/usage-h.json" exhausted 1 "$RECOV_H"
export FAKE_USAGE="$TMP/usage-h.json"
reg "$SD_H" "$T0" ws-wH wH wH:p1 3 1 0 0 acme/h >/dev/null
ST_H0="$(MGR_STATE_DIR="$SD_H" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(h) exhausted with the near reset" "$ST_H0" \
  '.providers.anthropic.recovers_at == '"$RECOV_H"' and .stalled[0].recovers_at == '"$RECOV_H"
export FAKE_USAGE="$TMP/does-not-exist.json"
ST_H1="$(MGR_STATE_DIR="$SD_H" MGR_GUARD_NOW_MS=$(( T0 + 900001 )) "$GUARD" tick)"
assert_jq "(h) the hold expired: unknown, no reading" "$ST_H1" \
  '.providers.anthropic | .status == "unknown" and .ok == false and .recovers_at == null
   and .reason == "unknown: no reading"'
assert_eq "(h) reignited on the passed reset alone" 1 "$(lines_of "$FAKE_PROMPTS")"
EXP_H="mgr-guard: anthropic:5h reset at $(iso_of "$RECOV_H") has passed (no fresh usage reading). Your previous turn stopped on a provider rate limit (429). Nobody needs to answer anything — resume exactly where you stopped and continue under your existing instructions."
assert_eq "(h) the text says the reset passed with no reading" "$EXP_H" "$(cut -f2 <"$FAKE_PROMPTS")"
assert_jq "(h) the entry keeps recovers_at across the unknown tick" "$ST_H1" \
  '.stalled[0] | .recovers_at == '"$RECOV_H"' and .attempts == 1'

printf '\n== (i) issue #13 regression: exhausted -> unknown -> exhausted reignites nothing ==\n'
SD_I="$TMP/s-i"
agents_file "$TMP/agents-i.json" \
  "$(mk_agent manager wI:p1 wI idle '')" \
  "$(mk_agent issue-9 wI:p9 wI blocked "$SESS_ANTHROPIC")"
export FAKE_AGENTS="$TMP/agents-i.json"
export FAKE_PROMPTS="$TMP/prompts-i.log" FAKE_TOASTS="$TMP/toasts-i.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"
RECOV_I=$(( T0 + 7200000 ))
mk_usage "$TMP/usage-i.json" exhausted 1 "$RECOV_I"
export FAKE_USAGE="$TMP/usage-i.json"
reg "$SD_I" "$T0" ws-wI wI wI:p1 3 1 0 0 acme/i >/dev/null
ST_I1="$(MGR_STATE_DIR="$SD_I" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
export FAKE_USAGE="$TMP/does-not-exist.json"
ST_I2="$(MGR_STATE_DIR="$SD_I" MGR_GUARD_NOW_MS=$(( T0 + 900001 )) "$GUARD" tick)"
export FAKE_USAGE="$TMP/usage-i.json"
ST_I3="$(MGR_STATE_DIR="$SD_I" MGR_GUARD_NOW_MS=$(( T0 + 1800000 )) "$GUARD" tick)"
assert_jq "(i) tick 1 exhausted" "$ST_I1" '.providers.anthropic.status == "exhausted"'
assert_jq "(i) tick 2 holds the verdict instead of going unknown" "$ST_I2" \
  '.providers.anthropic.status == "exhausted" and .providers.anthropic.ok == false'
assert_jq "(i) tick 3 exhausted again" "$ST_I3" \
  '.providers.anthropic.status == "exhausted" and .providers.anthropic.ok == true'
assert_eq "(i) zero prompts across the whole sequence" 0 "$(lines_of "$FAKE_PROMPTS")"
assert_jq "(i) zero reignite events" "$ST_I3" '[.events[] | select(.kind == "reignite")] | length == 0'
assert_jq "(i) the entry never advanced its attempts" "$ST_I3" '.stalled[0].attempts == 0'
assert_eq "(i) and no toast at all" 0 "$(lines_of "$FAKE_TOASTS")"

printf '\n== (j) a stalled manager pane is in the ledger and reignited too ==\n'
SD_J="$TMP/s-j"
agents_file "$TMP/agents-j.json" "$(mk_agent manager w5:p1 w5 idle "$SESS_ANTHROPIC")"
export FAKE_AGENTS="$TMP/agents-j.json"
export FAKE_PROMPTS="$TMP/prompts-j.log" FAKE_TOASTS="$TMP/toasts-j.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"
RECOV_J=$(( T0 + 3600000 ))
mk_usage "$TMP/usage-j.json" exhausted 1 "$RECOV_J"
export FAKE_USAGE="$TMP/usage-j.json"
reg "$SD_J" "$T0" ws-w5 w5 w5:p1 3 0 0 0 acme/j >/dev/null
ST_J1="$(MGR_STATE_DIR="$SD_J" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(j) the manager's own 429 is in the ledger" "$ST_J1" \
  '.stalled[0] | .pane_id == "w5:p1" and .name == "manager" and .manager_id == "ws-w5"'
mk_usage "$TMP/usage-j.json" ok 0.12 $(( T0 + 900001 + 3600000 ))
ST_J2="$(MGR_STATE_DIR="$SD_J" MGR_GUARD_NOW_MS=$(( T0 + 900001 )) "$GUARD" tick)"
assert_eq "(j) the manager pane is reignited" "w5:p1" "$(cut -f1 <"$FAKE_PROMPTS")"
assert_jq "(j) the manager row survives its own stall" "$ST_J2" \
  '.managers["ws-w5"].live == true and .stalled[0].attempts == 1'
if grep -q 'reset at .*, now at 12%\.' "$FAKE_PROMPTS"; then
  pass "(j) the prompt reports the observed reading"
else
  fail "(j) prompt text: $(cut -f2 <"$FAKE_PROMPTS")"
fi

printf '\n== daemon lifecycle (start/status/stop, fake PATH) ==\n'
DAEMON_STATE="$TMP/s-daemon"
NOW_REAL=$(( $(date +%s) * 1000 ))
mk_usage "$TMP/usage-daemon.json" ok 0.05 $(( NOW_REAL + 7200000 ))
export FAKE_USAGE="$TMP/usage-daemon.json" FAKE_AGENTS="$TMP/agents-b.json"
reg "$DAEMON_STATE" "$NOW_REAL" ws-w3 w3 w3:p1 3 0 0 1 >/dev/null
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
STATUS_D2="$(MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" status)"
assert_jq "status after stop" "$STATUS_D2" '.guard == "stopped"'
assert_jq "stop records why the guard is gone" "$STATUS_D2" \
  '.last_exit_reason == "stopped by mgr-guard stop" and (.last_exit_at | type) == "number"'
if [ -f "$DAEMON_STATE/exit.json" ]; then pass "exit.json written"; else fail "no exit.json"; fi

printf '\n== (k) issue #12: a filled ledger and a live pane keep the daemon past IDLE_EXIT_S ==\n'
# The incident: every manager 429-stalled, so nothing ran `mgr board`, so no heartbeat landed
# and the guard idle-exited while eight builders waited for the window to reset. Real clock
# here: a daemon never gets MGR_GUARD_NOW_MS.
DAEMON_STATE="$TMP/s-guard12"
NOW_12=$(( $(date +%s) * 1000 ))
AG_12="$TMP/agents-12.json"
US_12="$TMP/usage-12.json"
agents_file "$AG_12" \
  "$(mk_agent manager w3:p1 w3 idle '')" \
  "$(mk_agent issue-9 w3:p9 w3 blocked "$SESS_ANTHROPIC")"
mk_usage "$US_12" exhausted 1 $(( NOW_12 + 4000 ))
export FAKE_AGENTS="$AG_12" FAKE_USAGE="$US_12"
export FAKE_PROMPTS="$TMP/prompts-12.log" FAKE_TOASTS="$TMP/toasts-12.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"
reg "$DAEMON_STATE" $(( NOW_12 - 7200000 )) ws-w3 w3 w3:p1 3 1 0 0 >/dev/null
START12="$(MGR_STATE_DIR="$DAEMON_STATE" MGR_GUARD_INTERVAL=1 MGR_GUARD_IDLE_EXIT_S=2 "$GUARD" start)"
assert_jq "(k) daemon started" "$START12" '.started == true and .running == true'
PID12="$(jq -r '.pid // empty' <<<"$START12")"
for _ in $(seq 1 9); do sleep 0.5; done      # > IDLE_EXIT_S of ticks, zero fresh heartbeats
if [ -n "$PID12" ] && kill -0 "$PID12" 2>/dev/null; then
  pass "(k) daemon alive past IDLE_EXIT_S"
else
  fail "(k) daemon idle-exited with a builder still stalled"
fi
if grep -q 'idle-exit' "$DAEMON_STATE/guard.log" 2>/dev/null; then
  fail "(k) idle-exit logged while a builder was stalled"
else
  pass "(k) no idle-exit while a builder was stalled"
fi
ST_K1="$(MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" status)"
assert_jq "(k) stale heartbeat, live pane, one stalled builder" "$ST_K1" \
  '.guard == "running" and (.stalled | length) == 1
   and .managers["ws-w3"].live == true and .managers["ws-w3"].pane_alive == true
   and .providers.anthropic.status == "exhausted"'
# the window resets: the guard is still there to notice and reignite
mk_usage "$US_12" ok 0.20 $(( NOW_12 + 3600000 ))
REIGNITED=0
for _ in $(seq 1 10); do
  if grep -q '^w3:p9' "$FAKE_PROMPTS" 2>/dev/null; then REIGNITED=1; break; fi
  sleep 0.5
done
assert_eq "(k) reignited after the reset" 1 "$REIGNITED"
if kill -0 "$PID12" 2>/dev/null; then pass "(k) daemon alive after the reignition"; else fail "(k) daemon gone after the reignition"; fi
# the toast lands a moment after the prompt (state write, log, then notify): wait for it
TOASTED_K=0
for _ in $(seq 1 10); do
  if grep -q '^reignite: w3:p9' "$FAKE_TOASTS" 2>/dev/null; then TOASTED_K=1; break; fi
  sleep 0.5
done
if [ "$TOASTED_K" = 1 ]; then pass "(k) reignite toast"; else fail "(k) no reignite toast"; fi
if grep -qv '^reignite: ' "$FAKE_TOASTS"; then fail "(k) a non-reignite toast was sent"; else pass "(k) reignites are the only toasts"; fi
# and the gate itself still closes: pane gone, ledger empty -> the daemon may leave
printf '[]\n' >"$AG_12"
EXITED=0
for _ in $(seq 1 16); do
  kill -0 "$PID12" 2>/dev/null || { EXITED=1; break; }
  sleep 0.5
done
assert_eq "(k) idle-exit once nothing is left" 1 "$EXITED"
ST_K3="$(MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" status)"
assert_jq "(k) the exit shows up on status" "$ST_K3" \
  '.guard == "stopped" and (.last_exit_reason | startswith("idle-exit after 2s"))
   and (.last_exit_at | type) == "number"'
if grep -q 'idle-exit after 2s with no live manager and no stalled builder' "$DAEMON_STATE/guard.log"; then
  pass "(k) idle-exit log line"
else
  fail "(k) idle-exit log line missing: $(tail -n 1 "$DAEMON_STATE/guard.log")"
fi
if grep -q 'tick providers=anthropic status=anthropic:.* managers=.* stalled=.* reignited=.* reason=anthropic:' "$DAEMON_STATE/guard.log"; then
  pass "(k) the tick log line carries providers/status/managers/stalled/reignited/reason"
else
  fail "(k) tick log line: $(grep -m1 '^.* info tick ' "$DAEMON_STATE/guard.log")"
fi
# the scenarios below inherit FAKE_AGENTS: hand back a manager fixture, not the empty one
export FAKE_AGENTS="$TMP/agents-b.json"
# a daemon that failed to idle-exit must not outlive the suite
MGR_STATE_DIR="$DAEMON_STATE" "$GUARD" stop >/dev/null 2>&1
DAEMON_STATE=""

printf '\n== degraded inputs (omp / herdr unusable) ==\n'
SD_X="$TMP/s-x"
export FAKE_USAGE="$TMP/does-not-exist.json"
reg "$SD_X" "$T0" ws-w3 w3 w3:p1 3 0 0 1 >/dev/null
ST_X="$(MGR_STATE_DIR="$SD_X" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_json "tick with failing omp" "$ST_X"
assert_jq "no previous verdict to hold -> unknown" "$ST_X" \
  '.providers.anthropic | .status == "unknown" and .ok == false and .recovers_at == null
   and .reason == "unknown: no reading" and .usage_fetch_failures == 1 and (.limits | length) == 0'
unset FAKE_AGENTS
SD_Y="$TMP/s-y"
export FAKE_USAGE="$TMP/usage-ok.json"
ST_Y="$(MGR_STATE_DIR="$SD_Y" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "no agents, no managers, empty ledger" "$ST_Y" \
  '(.managers | length) == 0 and (.stalled | length) == 0 and .version == 2
   and .providers.anthropic.status == "ok"'

printf '\n== (l) the tick collects the backlog: mgr board rules, launches, the 50 cap ==\n'
SD_L="$TMP/s-l"
agents_file "$TMP/agents-l.json" "$(mk_agent manager wL:p1 wL idle '')"
export FAKE_AGENTS="$TMP/agents-l.json" FAKE_USAGE="$TMP/usage-ok.json"
export FAKE_GH_LOG="$TMP/gh-l.log"; : >"$FAKE_GH_LOG"
issues_file "$TMP/issues-l.json" \
  "$(mk_issue 10 ten mgr:in-flight '')" \
  "$(mk_issue 11 eleven mgr:awaiting-approval '')" \
  "$(mk_issue 12 twelve '' 'a plain body')" \
  "$(mk_issue 13 thirteen '' "$(printf 'needs the other one\nBlocked by: #12\n')")" \
  "$(mk_issue 14 fourteen '' 'Blocked by: #99')" \
  "$(mk_issue 15 fifteen mgr:in-flight,mgr:awaiting-approval '')"
export FAKE_ISSUES="$TMP/issues-l.json"
launches_file "$SD_L" acme/bk "10:$(( T0 - 600000 ))"
reg "$SD_L" "$T0" ws-wL wL wL:p1 3 2 1 2 acme/bk >/dev/null
ST_L="$(MGR_STATE_DIR="$SD_L" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_eq "(l) one gh call for the one repo" 1 "$(lines_of "$FAKE_GH_LOG")"
assert_jq "(l) the gh call is the board fetch" "$(jq -Rsc . <"$FAKE_GH_LOG")" \
  'test("issue list -R acme/bk --state open --limit 200 --json number,title,labels,body")'
assert_jq "(l) backlog shape" "$ST_L" \
  '(.managers["ws-wL"].backlog | keys)
   == ["awaiting_approval","blocked","cap","counts","in_flight","ready","slots_free"]'
assert_jq "(l) ready is unlabelled with no OPEN blocker (#14 blocked by a closed one)" "$ST_L" \
  '.managers["ws-wL"].backlog.ready
   == [{number:12, title:"twelve", blocked_by:[]}, {number:14, title:"fourteen", blocked_by:[]}]'
assert_jq "(l) blocked keeps the open blocker it parsed off the body" "$ST_L" \
  '.managers["ws-wL"].backlog.blocked == [{number:13, title:"thirteen", blocked_by:[12]}]'
assert_jq "(l) in flight joins launched_at from the launches file" "$ST_L" \
  '.managers["ws-wL"].backlog.in_flight
   == [{number:10, title:"ten", launched_at:'"$(( T0 - 600000 ))"'},
       {number:15, title:"fifteen", launched_at:null}]'
assert_jq "(l) awaiting-approval only when it is not in flight" "$ST_L" \
  '.managers["ws-wL"].backlog.awaiting_approval == [{number:11, title:"eleven"}]'
assert_jq "(l) cap, slots_free and the true counts" "$ST_L" \
  '.managers["ws-wL"].backlog
   | .cap == 3 and .slots_free == 0
     and .counts == {ready:2, blocked:1, in_flight:2, awaiting_approval:1, open:6}'
assert_jq "(l) the refresh stamps backlog_at and clears backlog_error" "$ST_L" \
  '.managers["ws-wL"] | .backlog_at == '"$T0"' and .backlog_error == null'
# 60 open issues, all launchable: the ledger keeps the first 50 and the true count
SD_L60="$TMP/s-l60"
jq -nc '[range(100; 160) | {number:., title:("issue " + (. | tostring)), body:"", labels:[]}]' \
  >"$TMP/issues-l60.json"
export FAKE_ISSUES="$TMP/issues-l60.json" FAKE_GH_LOG="$TMP/gh-l60.log"; : >"$FAKE_GH_LOG"
reg "$SD_L60" "$T0" ws-wL wL wL:p1 4 0 0 60 acme/big >/dev/null
ST_L60="$(MGR_STATE_DIR="$SD_L60" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(l) the ready list is capped at 50, the count is not" "$ST_L60" \
  '.managers["ws-wL"].backlog
   | (.ready | length) == 50 and .counts.ready == 60 and .counts.open == 60
     and (.ready | first | .number) == 100 and (.ready | last | .number) == 149'
BK_L60="$SD_L60/backlog/acme__big.json"
if [ -f "$BK_L60" ]; then pass "(l) the whole queue is filed under backlog/"; else fail "(l) no $BK_L60"; fi
assert_jq "(l) the filed queue is uncapped and stamped" "$(cat "$BK_L60")" \
  '(keys) == ["at","blocked","ready","repo"] and .at == '"$T0"' and .repo == "acme/big"
   and (.ready | length) == 60 and .blocked == []
   and (.ready | last) == {number:159, title:"issue 159", blocked_by:[]}'
# the display is capped, the simulation is not: all 60 get an ETA off the filed queue
OVL="$(MGR_STATE_DIR="$SD_L60" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview --limit 10)"
LAST_L60=$(( T0 + 15 * 2700000 ))     # cap 4, no throughput rows: 15 rounds of MGR_DEFAULT_TASK_S
assert_jq "(l) ten shown, the other fifty summarised" "$OVL" \
  '(.timeline.shown | length) == 10
   and .timeline.beyond == {count:50, blocked:0, last_eta:'"$LAST_L60"',
                            drains_at:'"$LAST_L60"'}
   and .timeline.drains_at == '"$LAST_L60"
assert_jq "(l) the ledger row still reports the true counts" "$OVL" \
  '.backlog.managers[0] | .ready == 60 and .cap == 4
   and .backlog_drains_at == '"$LAST_L60"
OVL2="$(MGR_STATE_DIR="$SD_L60" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview --limit 100)"
assert_jq "(l) every one of the sixty has an ETA" "$OVL2" \
  '(.timeline.shown | length) == 60
   and ([.timeline.shown[] | select(.eta == null)] | length) == 0
   and ([.timeline.shown[] | .eta] | max) == '"$LAST_L60"
# and with the file gone the projection falls back to the 50 the ledger carries
rm -f "$BK_L60"
OVL3="$(MGR_STATE_DIR="$SD_L60" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview --limit 10)"
assert_jq "(l) a missing backlog file falls back to the capped ledger lists" "$OVL3" \
  '.timeline.beyond.count == 40
   and .timeline.drains_at == '"$(( T0 + 13 * 2700000 ))"'
   and (.backlog.managers[0].ready == 60)'
printf 'not json at all\n' >"$BK_L60"
OVL4="$(MGR_STATE_DIR="$SD_L60" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview --limit 10)"
assert_jq "(l) a junk backlog file is ignored, not fatal" "$OVL4" \
  '.timeline.beyond.count == 40'
rm -f "$BK_L60"

printf '\n== (m) the refresh is rate-limited, then refetches ==\n'
export FAKE_ISSUES="$TMP/issues-l.json" FAKE_GH_LOG="$TMP/gh-m.log"; : >"$FAKE_GH_LOG"
ST_M1="$(MGR_STATE_DIR="$SD_L" MGR_GUARD_NOW_MS=$(( T0 + 60000 )) "$GUARD" tick)"
assert_eq "(m) inside MGR_GUARD_BACKLOG_INTERVAL_S nothing is fetched" 0 "$(lines_of "$FAKE_GH_LOG")"
assert_jq "(m) and the snapshot is carried forward untouched" "$ST_M1" \
  '.managers["ws-wL"] | .backlog_at == '"$T0"' and .backlog_error == null
   and (.backlog.counts.open == 6) and (.backlog.in_flight | length) == 2'
ST_M2="$(MGR_STATE_DIR="$SD_L" MGR_GUARD_NOW_MS=$(( T0 + 120001 )) "$GUARD" tick)"
assert_eq "(m) past the interval it refetches" 1 "$(lines_of "$FAKE_GH_LOG")"
assert_jq "(m) with a fresh backlog_at" "$ST_M2" \
  '.managers["ws-wL"].backlog_at == '"$(( T0 + 120001 ))"

printf '\n== (n) a failing gh keeps the last snapshot and says so ==\n'
unset FAKE_ISSUES
export FAKE_GH_LOG="$TMP/gh-n.log"; : >"$FAKE_GH_LOG"
ST_N="$(MGR_STATE_DIR="$SD_L" MGR_GUARD_NOW_MS=$(( T0 + 300000 )) "$GUARD" tick)"
assert_eq "(n) it did try" 1 "$(lines_of "$FAKE_GH_LOG")"
assert_jq "(n) the previous backlog and its stamp survive the failure" "$ST_N" \
  '.managers["ws-wL"] | .backlog_at == '"$(( T0 + 120001 ))"'
   and .backlog.counts == {ready:2, blocked:1, in_flight:2, awaiting_approval:1, open:6}'
assert_jq "(n) and backlog_error names it" "$ST_N" \
  '.managers["ws-wL"].backlog_error == "gh issue list failed"'
export FAKE_ISSUES="$TMP/issues-l.json"
ST_N2="$(MGR_STATE_DIR="$SD_L" MGR_GUARD_NOW_MS=$(( T0 + 420001 )) "$GUARD" tick)"
assert_jq "(n) a good fetch clears the error" "$ST_N2" \
  '.managers["ws-wL"] | .backlog_error == null and .backlog_at == '"$(( T0 + 420001 ))"

printf '\n== (o) throughput: repo median, machine median, then the default ==\n'
SD_O="$TMP/s-o"
agents_file "$TMP/agents-o.json" \
  "$(mk_agent manager wO1:p1 wO1 idle '')" \
  "$(mk_agent manager wO2:p1 wO2 idle '')"
export FAKE_AGENTS="$TMP/agents-o.json" FAKE_GH_LOG="$TMP/gh-o.log"; : >"$FAKE_GH_LOG"
reg "$SD_O" "$T0" ws-o1 wO1 wO1:p1 2 0 0 0 acme/t1 >/dev/null
thru_file "$SD_O" acme/t1 600 1200 1800
ST_O1="$(MGR_STATE_DIR="$SD_O" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(o) three rows of its own -> the repo median" "$ST_O1" \
  '.managers["ws-o1"].throughput
   == {n:3, median_s:1200, p80_s:1800, last_10_mean_s:1200, estimated:false, source:"repo"}'
reg "$SD_O" "$T0" ws-o2 wO2 wO2:p1 2 0 0 0 acme/t2 >/dev/null
thru_file "$SD_O" acme/t2 300
ST_O2="$(MGR_STATE_DIR="$SD_O" MGR_GUARD_NOW_MS=$(( T0 + 1000 )) "$GUARD" tick)"
assert_jq "(o) one row of its own -> the machine median, flagged estimated" "$ST_O2" \
  '.managers["ws-o2"].throughput
   == {n:1, median_s:900, p80_s:1800, last_10_mean_s:975, estimated:true, source:"machine"}'
assert_jq "(o) the repo with its own rows is unaffected" "$ST_O2" \
  '.managers["ws-o1"].throughput.source == "repo" and .managers["ws-o1"].throughput.n == 3'
SD_O3="$TMP/s-o3"
agents_file "$TMP/agents-o3.json" "$(mk_agent manager wO3:p1 wO3 idle '')"
export FAKE_AGENTS="$TMP/agents-o3.json"
reg "$SD_O3" "$T0" ws-o3 wO3 wO3:p1 2 0 0 0 acme/t3 >/dev/null
ST_O3="$(MGR_STATE_DIR="$SD_O3" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(o) no rows anywhere -> MGR_DEFAULT_TASK_S" "$ST_O3" \
  '.managers["ws-o3"].throughput
   == {n:0, median_s:2700, p80_s:2700, last_10_mean_s:2700, estimated:true, source:"default"}'
ST_O4="$(MGR_DEFAULT_TASK_S=1500 MGR_STATE_DIR="$SD_O3" MGR_GUARD_NOW_MS=$(( T0 + 1000 )) "$GUARD" tick)"
assert_jq "(o) MGR_DEFAULT_TASK_S is honoured" "$ST_O4" \
  '.managers["ws-o3"].throughput | .median_s == 1500 and .source == "default"'

printf '\n== (p) overview: the burn stall window, FIFO with a blocker, starvation ==\n'
SD_P="$TMP/s-p"; mkdir -p "$SD_P"
# hand-written ledger: 80% of a 5h window burning 0.4/h resets two hours out, so the
# projection exhausts it in 30 minutes and everything after that lands past the reset
jq -n --argjson t "$T0" '
  {version:2, tick_at:$t, interval_s:60, builder_provider:"anthropic",
   providers:{anthropic:{status:"warning", ok:true, recovers_at:null, exhausted_limit:null,
     limits:[{id:"anthropic:5h", label:"5h", status:"warning", used:0.8,
              resets_at:($t + 7200000), burn_per_hour:0.4, projected_at_reset:2.2,
              fits:false, hours_to_reset:2, sample_count:4, samples:[]}]}},
   managers:{
     "ws-a":{manager_id:"ws-a", repo:"acme/a", live:true, pane_alive:true, cap:2, adopting:0,
             backlog_at:$t, backlog_error:null,
             throughput:{n:6, median_s:600, p80_s:700, last_10_mean_s:650,
                         estimated:false, source:"repo"},
             backlog:{ready:[{number:2, title:"two", blocked_by:[]},
                             {number:3, title:"three", blocked_by:[]},
                             {number:4, title:"four", blocked_by:[]},
                             {number:6, title:"six", blocked_by:[]},
                             {number:7, title:"seven", blocked_by:[]}],
                      blocked:[{number:5, title:"five", blocked_by:[2]}],
                      in_flight:[{number:1, title:"one", launched_at:($t - 300000)}],
                      awaiting_approval:[], cap:2, slots_free:1,
                      counts:{ready:5, blocked:1, in_flight:1, awaiting_approval:0, open:7}}},
     "ws-b":{manager_id:"ws-b", repo:"shape/b", live:true, pane_alive:true, cap:2, adopting:0,
             backlog_at:$t, backlog_error:"gh issue list failed",
             throughput:{n:1, median_s:900, p80_s:1800, last_10_mean_s:975,
                         estimated:true, source:"machine"},
             backlog:{ready:[], blocked:[], in_flight:[], awaiting_approval:[],
                      cap:2, slots_free:2,
                      counts:{ready:0, blocked:0, in_flight:0, awaiting_approval:0, open:0}}},
     "ws-dead":{manager_id:"ws-dead", repo:"gone/g", live:false, pane_alive:false, cap:9,
                adopting:0, backlog_at:$t, backlog_error:null, throughput:null,
                backlog:{ready:[{number:80, title:"eighty", blocked_by:[]}], blocked:[],
                         in_flight:[], awaiting_approval:[], cap:9, slots_free:9,
                         counts:{ready:1, blocked:0, in_flight:0, awaiting_approval:0, open:1}}}},
   stalled:[], events:[]}' >"$SD_P/state.json"
OV="$(MGR_STATE_DIR="$SD_P" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview --limit 3)"
assert_json "overview output" "$OV"
assert_jq "(p) top-level shape" "$OV" '(keys) == ["at","backlog","burn","timeline"] and .at == '"$T0"
assert_jq "(p) burn limit shape" "$OV" \
  '(.burn.limits[0] | keys)
   == ["burn_per_hour","exhaust_at","fits","id","projected_at_reset","provider","resets_at",
       "status","used"]'
assert_jq "(p) exhaust_at is (1-used)/bph ahead, bounded by the reset" "$OV" \
  '.burn.limits[0] | .fits == false and .exhaust_at == '"$(( T0 + 1800000 ))"'
   and .provider == "anthropic"'
assert_jq "(p) the stall window is that limit to its reset" "$OV" \
  '.burn.stall_window
   == {from:'"$(( T0 + 1800000 ))"', to:'"$(( T0 + 7200000 ))"', limit:"anthropic:5h"}'
assert_jq "(p) manager row shape" "$OV" \
  '(.backlog.managers[0] | keys)
   == ["awaiting_approval","backlog_at","backlog_drains_at","backlog_error","blocked","cap",
       "idle_slots","in_flight","manager_id","provider","ready","repo","stall_window",
       "starves_at","starving","throughput"]'
assert_jq "(p) only live managers, sorted by repo" "$OV" \
  '[.backlog.managers[] | .manager_id] == ["ws-a","ws-b"]'
assert_jq "(p) shown item shape" "$OV" \
  '(.timeline.shown[0] | keys)
   == ["blocked_by","estimated","eta","manager_id","number","repo","state","title"]'
# in flight 5 min in with a 10-min median: max(median, elapsed + quarter median) = median
assert_jq "(p) the in-flight ETA runs off launched_at" "$OV" \
  '.timeline.shown[0]
   | .number == 1 and .state == "in_flight" and .eta == '"$(( T0 + 300000 ))"'
     and .estimated == false and .repo == "acme/a" and .manager_id == "ws-a"'
# cap 2, one slot free now and one at 5 min: #2 10m, #3 15m, #4 20m
assert_jq "(p) FIFO by number over the free slots" "$OV" \
  '[.timeline.shown[] | select(.state != "in_flight") | [.number, .eta]]
   == [[2, '"$(( T0 + 600000 ))"'], [3, '"$(( T0 + 900000 ))"'], [4, '"$(( T0 + 1200000 ))"']]'
OVA="$(MGR_STATE_DIR="$SD_P" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview --limit 50)"
# FIFO is by number, so #5 is scheduled in the same pass as its blocker #2 (start = the
# first slot free after #2 finishes); #6 lands exactly on the exhaustion and #7 crosses it
assert_jq "(p) the blocker delays #5, and #7 is pushed past the reset" "$OVA" \
  '[.timeline.shown[] | select(.number == 5 or .number == 6 or .number == 7) | [.number, .eta]]
   == [[5, '"$(( T0 + 1500000 ))"'], [6, '"$(( T0 + 1800000 ))"'],
       [7, '"$(( T0 + 7500000 ))"']]'
assert_jq "(p) the blocked item still names its blocker" "$OVA" \
  '[.timeline.shown[] | select(.number == 5)] | first
   | .state == "blocked" and .blocked_by == [2]'
assert_jq "(p) nothing hidden at --limit 50" "$OVA" '.timeline.beyond == null'
assert_jq "(p) the working manager is not starving; its queue drains past the reset" "$OV" \
  '[.backlog.managers[] | select(.manager_id == "ws-a")] | first
   | .ready == 5 and .blocked == 1 and .in_flight == 1 and .cap == 2
     and .idle_slots == 0 and .starving == false
     and .starves_at == '"$(( T0 + 1800000 ))"'
     and .backlog_drains_at == '"$(( T0 + 7500000 ))"
assert_jq "(p) the empty manager starves now" "$OV" \
  '[.backlog.managers[] | select(.manager_id == "ws-b")] | first
   | .idle_slots == 2 and .starving == true and .starves_at == '"$T0"'
     and .backlog_drains_at == null and .backlog_error == "gh issue list failed"'
assert_jq "(p) the throughput chain travels into the overview" "$OV" \
  '[.backlog.managers[] | .throughput.source] == ["repo","machine"]
   and ([.backlog.managers[] | .throughput.estimated] == [false, true])
   and ([.backlog.managers[] | select(.manager_id == "ws-b")] | first | .throughput.median_s) == 900'
assert_jq "(p) totals are the sums, dead managers excluded" "$OV" \
  '.backlog.totals
   == {ready:5, blocked:1, in_flight:1, awaiting_approval:0, cap:4, idle_slots:2, open:7}'
assert_jq "(p) beyond summarises what the limit hid" "$OV" \
  '.timeline.beyond
   == {count:3, blocked:1, last_eta:'"$(( T0 + 7500000 ))"',
       drains_at:'"$(( T0 + 7500000 ))"'}'
assert_jq "(p) machine drains_at and last_eta are the same number" "$OV" \
  '.timeline.drains_at == '"$(( T0 + 7500000 ))"' and .timeline.last_eta == .timeline.drains_at'
OV0="$(MGR_STATE_DIR="$SD_P" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview --limit 0)"
assert_jq "(p) --limit 0 shows the in-flight work and hides the queue" "$OV0" \
  '(.timeline.shown | length) == 1 and .timeline.shown[0].state == "in_flight"
   and .timeline.beyond.count == 6'
BADL="$(MGR_STATE_DIR="$SD_P" "$GUARD" overview --limit x 2>&1)"
assert_eq "(p) --limit x exit code" 2 "$?"
assert_jq "(p) --limit x error" "$BADL" \
  '.error.code == 2 and (.error.message | test("non-negative integer"))'
MGR_STATE_DIR="$SD_P" "$GUARD" overview --limit -3 >/dev/null 2>&1
assert_eq "(p) a negative limit is refused too" 2 "$?"
MGR_STATE_DIR="$SD_P" "$GUARD" overview --wat >/dev/null 2>&1
assert_eq "(p) an unknown flag is refused" 2 "$?"
OVE="$(MGR_STATE_DIR="$TMP/s-nothing" "$GUARD" overview)"
assert_json "overview with no state at all" "$OVE"
assert_jq "(p) no state.json -> zeros, no window, nothing queued" "$OVE" \
  '.burn.limits == [] and .burn.stall_window == null
   and .backlog.managers == [] and .timeline.shown == []
   and .timeline.beyond == null and .timeline.drains_at == null
   and .backlog.totals == {ready:0, blocked:0, in_flight:0, awaiting_approval:0,
                           cap:0, idle_slots:0, open:0}'

printf '\n== (q) overview is judicious: 40 ready, 10 shown, the rest summarised ==\n'
SD_Q="$TMP/s-q"; mkdir -p "$SD_Q"
jq -n --argjson t "$T0" '
  {version:2, tick_at:$t, providers:{},
   managers:{"ws-q":{manager_id:"ws-q", repo:"acme/q", live:true, pane_alive:true,
     cap:2, adopting:0, backlog_at:$t, backlog_error:null,
     throughput:{n:5, median_s:1800, p80_s:2000, last_10_mean_s:1800,
                 estimated:false, source:"repo"},
     backlog:{ready:[range(1; 41) | {number:., title:("i" + (. | tostring)), blocked_by:[]}],
              blocked:[],
              in_flight:[{number:100, title:"a", launched_at:($t - 600000)},
                         {number:101, title:"b", launched_at:($t - 600000)}],
              awaiting_approval:[], cap:2, slots_free:0,
              counts:{ready:40, blocked:0, in_flight:2, awaiting_approval:0, open:42}}}},
   stalled:[], events:[]}' >"$SD_Q/state.json"
OVQ="$(MGR_STATE_DIR="$SD_Q" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview)"
LAST_Q=$(( T0 + 1200000 + 20 * 1800000 ))
assert_jq "(q) shown is every in-flight plus the default ten" "$OVQ" \
  '(.timeline.shown | length) == 12
   and ([.timeline.shown[] | select(.state == "in_flight")] | length) == 2
   and ([.timeline.shown[] | select(.state == "ready")] | length) == 10'
assert_jq "(q) beyond counts the other thirty and names the last ETA" "$OVQ" \
  '.timeline.beyond == {count:30, blocked:0, last_eta:'"$LAST_Q"', drains_at:'"$LAST_Q"'}'
assert_jq "(q) drains_at is that same last ETA" "$OVQ" \
  '.timeline.drains_at == '"$LAST_Q"'
   and (.backlog.managers[0].backlog_drains_at == '"$LAST_Q"')'
OVQ2="$(MGR_STATE_DIR="$SD_Q" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview --limit 100)"
assert_jq "(q) the simulation covered all forty, not just the shown ten" "$OVQ2" \
  '(.timeline.shown | length) == 42
   and ([.timeline.shown[] | select(.eta == null)] | length) == 0
   and ([.timeline.shown[] | select(.state == "ready")] | map(.eta) | max) == '"$LAST_Q"'
   and .timeline.beyond == null'

printf '\n== (r) a blocker this manager does not own counts as passed ==\n'
# The `Blocked by:` line can name an issue that is closed, in another repo, or merely
# awaiting approval. None of those are on this manager's board, so the queued issue starts
# now instead of hanging on a blocker whose ETA can never arrive.
SD_R="$TMP/s-r"; mkdir -p "$SD_R"
jq -n --argjson t "$T0" '
  {version:2, tick_at:$t, providers:{},
   managers:{"ws-r":{manager_id:"ws-r", repo:"other/shape", live:true, pane_alive:true,
     cap:1, adopting:0, backlog_at:$t, backlog_error:null,
     throughput:{n:5, median_s:1500, p80_s:1600, last_10_mean_s:1500,
                 estimated:false, source:"repo"},
     backlog:{ready:[], blocked:[{number:101, title:"one-oh-one", blocked_by:[999]},
                                 {number:102, title:"one-oh-two", blocked_by:[101, 999]}],
              in_flight:[], awaiting_approval:[], cap:1, slots_free:1,
              counts:{ready:0, blocked:2, in_flight:0, awaiting_approval:0, open:2}}}},
   stalled:[], events:[]}' >"$SD_R/state.json"
OVR="$(MGR_STATE_DIR="$SD_R" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview)"
assert_jq "(r) the unknown blocker does not strand the issue" "$OVR" \
  '[.timeline.shown[] | [.number, .eta]]
   == [[101, '"$(( T0 + 1500000 ))"'], [102, '"$(( T0 + 3000000 ))"']]'
assert_jq "(r) the blocker it does own is still waited on, and the queue drains" "$OVR" \
  '.backlog.managers[0]
   | .backlog_drains_at == '"$(( T0 + 3000000 ))"' and .idle_slots == 1
     and .starving == true and .starves_at == '"$T0"

printf '\n== (s) two providers ==\n'
SD_S="$TMP/s-s"
agents_file "$TMP/agents-s.json" \
  "$(mk_agent manager wa:p1 wa idle '')" \
  "$(mk_agent manager wo:p1 wo idle '')" \
  "$(mk_agent manager wn:p1 wn idle '')"
export FAKE_AGENTS="$TMP/agents-s.json"
mk_usage2 "$TMP/usage-s.json" ok 0.10 $(( T0 + 3600000 )) ok 0.15 $(( T0 + 3600000 ))
export FAKE_USAGE="$TMP/usage-s.json" FAKE_FETCHES="$TMP/fetches-s.log"; : >"$FAKE_FETCHES"
reg "$SD_S" "$T0" ws-a wa wa:p1 3 1 0 0 acme/a anthropic anthropic >/dev/null
reg "$SD_S" "$T0" ws-o wo wo:p1 3 1 0 0 acme/o openai-codex openai >/dev/null
reg "$SD_S" "$T0" ws-n wn wn:p1 3 1 0 0 acme/n >/dev/null
ST_S="$(MGR_STATE_DIR="$SD_S" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_json "(s) tick output" "$ST_S"
assert_eq "(s) both subscriptions are sampled exactly once in one tick" 2 "$(lines_of "$FAKE_FETCHES")"
assert_eq "(s) the sorted fetch log names both providers" "anthropic
openai-codex" "$(sort "$FAKE_FETCHES")"
assert_jq "(s) providers keys are both" "$ST_S" '(.providers | keys) == ["anthropic","openai-codex"]'
assert_jq "(s) ws-a carries its own provider and house" "$ST_S" \
  '.managers["ws-a"].provider == "anthropic" and .managers["ws-a"].house == "anthropic"'
assert_jq "(s) ws-o carries its own provider and house" "$ST_S" \
  '.managers["ws-o"].provider == "openai-codex" and .managers["ws-o"].house == "openai"'
assert_jq "(s) the provider-less manager contributes no provider or house key" "$ST_S" \
  '(.managers["ws-n"] | has("provider") | not) and (.managers["ws-n"] | has("house") | not)'
assert_jq "(s) builder_provider is still stamped every tick" "$ST_S" '.builder_provider == "anthropic"'
assert_jq "(s) the top-level state shape is unchanged" "$ST_S" \
  '(keys) == ["builder_provider","events","interval_s","managers","pid","providers","stalled","tick_at","version"]'
EXP_S_LOG="tick providers=anthropic,openai-codex status=anthropic:ok,openai-codex:ok managers=3 stalled=0 reignited=0 reason=anthropic:fits; openai-codex:fits"
if grep -qF "$EXP_S_LOG" "$SD_S/guard.log"; then
  pass "(s) the tick log line proves the two-provider form"
else
  fail "(s) tick log line: $(grep -m1 '^.* info tick ' "$SD_S/guard.log")"
fi
STATUS_S="$(MGR_STATE_DIR="$SD_S" "$GUARD" status)"
assert_jq "(s) status passes both providers through unscoped" "$STATUS_S" \
  '(.providers | keys) == ["anthropic","openai-codex"]'
OV_S="$(MGR_STATE_DIR="$SD_S" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview)"
assert_jq "(s) overview burn.limits carries both providers, unfiltered" "$OV_S" \
  '([.burn.limits[].provider] | sort) == ["anthropic","openai-codex"]'
assert_jq "(s) every backlog.managers row carries a provider key" "$OV_S" \
  '[.backlog.managers[] | has("provider")] | all'
assert_jq "(s) backlog.managers provider values are both providers plus the provider-less null" "$OV_S" \
  '([.backlog.managers[].provider] | sort) == [null,"anthropic","openai-codex"]'
# the fallback role: no live manager and no stalled pane names a provider at all ->
# builder_provider() is the sole poll target, polled exactly once
SD_SF="$TMP/s-s-fallback"; mkdir -p "$SD_SF"
printf '[]\n' >"$TMP/agents-s-empty.json"
mk_usage "$TMP/usage-s-fallback.json" ok 0.05 $(( T0 + 7200000 ))
export FAKE_AGENTS="$TMP/agents-s-empty.json" FAKE_USAGE="$TMP/usage-s-fallback.json" \
       FAKE_FETCHES="$TMP/fetches-s-fallback.log"
: >"$FAKE_FETCHES"
ST_SF="$(MGR_STATE_DIR="$SD_SF" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_eq "(s) no managers at all: exactly one fetch, the fallback target" 1 "$(lines_of "$FAKE_FETCHES")"
assert_eq "(s) the fallback target is builder_provider()'s value" "anthropic" "$(cat "$FAKE_FETCHES")"
assert_jq "(s) providers keys are just the fallback" "$ST_SF" '(.providers | keys) == ["anthropic"]'
unset FAKE_FETCHES

printf '\n== (t) two providers, one stalling: a foreign window must not bend a fitting caller ==\n'
# review finding on the fix round: widening the poll set means $win alone can no longer be
# handed to every manager -- a hand-authored ledger (like (p)'s) with anthropic fitting and
# openai-codex stalling, so the assertions below can tell "my own window" from "someone else's".
SD_T="$TMP/s-t"; mkdir -p "$SD_T"
# anthropic fits (flat 50%, burn 0); openai-codex is (p)'s fixture verbatim: 80% of a 5h
# window burning 0.4/h with 2h to reset -> exhausts in 30 min, resets 2h out
jq -n --argjson t "$T0" '
  {version:2, tick_at:$t, interval_s:60, builder_provider:"anthropic",
   providers:{
     anthropic:{status:"ok", ok:true, recovers_at:null, exhausted_limit:null,
       limits:[{id:"anthropic:5h", label:"5h", status:"ok", used:0.5,
                resets_at:($t + 7200000), burn_per_hour:0, projected_at_reset:0.5,
                fits:true, hours_to_reset:2, sample_count:1, samples:[]}]},
     "openai-codex":{status:"warning", ok:true, recovers_at:null, exhausted_limit:null,
       limits:[{id:"openai-codex:5h", label:"5h", status:"warning", used:0.8,
                resets_at:($t + 7200000), burn_per_hour:0.4, projected_at_reset:2.2,
                fits:false, hours_to_reset:2, sample_count:4, samples:[]}]}},
   managers:{
     "ws-fit":{manager_id:"ws-fit", repo:"acme/fit", provider:"anthropic",
               live:true, pane_alive:true, cap:1, adopting:0,
               backlog_at:$t, backlog_error:null,
               throughput:{n:5, median_s:600, p80_s:700, last_10_mean_s:650,
                           estimated:false, source:"repo"},
               backlog:{ready:[range(1;6) | {number:., title:("f" + (. | tostring)), blocked_by:[]}],
                        blocked:[], in_flight:[], awaiting_approval:[], cap:1, slots_free:1,
                        counts:{ready:5, blocked:0, in_flight:0, awaiting_approval:0, open:5}}},
     "ws-stall":{manager_id:"ws-stall", repo:"acme/stall", provider:"openai-codex",
                 live:true, pane_alive:true, cap:1, adopting:0,
                 backlog_at:$t, backlog_error:null,
                 throughput:{n:5, median_s:600, p80_s:700, last_10_mean_s:650,
                             estimated:false, source:"repo"},
                 backlog:{ready:[range(1;6) | {number:., title:("s" + (. | tostring)), blocked_by:[]}],
                          blocked:[], in_flight:[], awaiting_approval:[], cap:1, slots_free:1,
                          counts:{ready:5, blocked:0, in_flight:0, awaiting_approval:0, open:5}}},
     "ws-none":{manager_id:"ws-none", repo:"acme/none",
                live:true, pane_alive:true, cap:1, adopting:0,
                backlog_at:$t, backlog_error:null,
                throughput:{n:5, median_s:600, p80_s:700, last_10_mean_s:650,
                            estimated:false, source:"repo"},
                backlog:{ready:[range(1;6) | {number:., title:("n" + (. | tostring)), blocked_by:[]}],
                         blocked:[], in_flight:[], awaiting_approval:[], cap:1, slots_free:1,
                         counts:{ready:5, blocked:0, in_flight:0, awaiting_approval:0, open:5}}}},
   stalled:[], events:[]}' >"$SD_T/state.json"
OV_T="$(MGR_STATE_DIR="$SD_T" MGR_GUARD_NOW_MS="$T0" "$GUARD" overview --limit 50)"
assert_json "(t) overview output" "$OV_T"
assert_jq "(t) burn.stall_window stays machine-wide, naming the stalling provider's limit" "$OV_T" \
  '.burn.stall_window
   == {from:'"$(( T0 + 1800000 ))"', to:'"$(( T0 + 7200000 ))"', limit:"openai-codex:5h"}'
# THE regression assertion: before the fix every row got $win uniformly, so the fitting
# anthropic manager would have carried openai-codex's window here. Now it gets none.
assert_jq "(t) the fitting provider's manager carries no window (acceptance box 5)" "$OV_T" \
  '[.backlog.managers[] | select(.manager_id == "ws-fit")] | first | .stall_window == null'
assert_jq "(t) the stalling provider's manager carries its own window" "$OV_T" \
  '[.backlog.managers[] | select(.manager_id == "ws-stall")] | first | .stall_window
   == {from:'"$(( T0 + 1800000 ))"', to:'"$(( T0 + 7200000 ))"', limit:"openai-codex:5h"}'
assert_jq "(t) the provider-less manager keeps the machine-wide fallback window" "$OV_T" \
  '[.backlog.managers[] | select(.manager_id == "ws-none")] | first | .stall_window
   == {from:'"$(( T0 + 1800000 ))"', to:'"$(( T0 + 7200000 ))"', limit:"openai-codex:5h"}'
# the window actually reaches the simulation, not just the row: cap 1, five 10-minute
# items with no window drain by T0+3000000 (50m); with the 30m/2h window in effect the
# fourth item's slot opens inside the window and gets bumped to the reset, landing the
# queue's drain at T0+8400000 (2h20m) -- past the 2h reset, unlike the fitting manager
assert_jq "(t) the fitting manager's queue drains well inside the window, untouched" "$OV_T" \
  '[.backlog.managers[] | select(.manager_id == "ws-fit")] | first
   | .backlog_drains_at == '"$(( T0 + 3000000 ))"' and .backlog_drains_at < '"$(( T0 + 7200000 ))"
assert_jq "(t) the stalling manager's queue is pushed past its own reset" "$OV_T" \
  '[.backlog.managers[] | select(.manager_id == "ws-stall")] | first
   | .backlog_drains_at == '"$(( T0 + 8400000 ))"' and .backlog_drains_at > '"$(( T0 + 7200000 ))"
assert_jq "(t) the provider-less manager is bent by the same machine-wide window" "$OV_T" \
  '[.backlog.managers[] | select(.manager_id == "ws-none")] | first | .backlog_drains_at
   == '"$(( T0 + 8400000 ))"
assert_jq "(t) relationally: the stalling and fallback managers drain identically, past the fitting one" "$OV_T" \
  '(([.backlog.managers[] | select(.manager_id == "ws-stall")] | first | .backlog_drains_at)
    == ([.backlog.managers[] | select(.manager_id == "ws-none")] | first | .backlog_drains_at))
   and (([.backlog.managers[] | select(.manager_id == "ws-stall")] | first | .backlog_drains_at)
        > ([.backlog.managers[] | select(.manager_id == "ws-fit")] | first | .backlog_drains_at))'

printf '\n== (u) poll-loop hardening: a malformed provider string contributes nothing ==\n'
# review finding (MEDIUM): the old `for p in $providers` over an unquoted variable both
# word-split and glob-expanded each line. A registration carrying "zzz-*" used to make the
# tick fetch whatever files matching that glob sat in the daemon's cwd; a registration
# carrying a space used to split into two bogus provider fetches.
SD_U1="$TMP/s-u-glob"
GLOBDIR="$TMP/poll-glob-cwd"; mkdir -p "$GLOBDIR"
: >"$GLOBDIR/zzz-alpha"; : >"$GLOBDIR/zzz-beta"
agents_file "$TMP/agents-u1.json" \
  "$(mk_agent manager wu1:p1 wu1 idle '')" \
  "$(mk_agent manager wu2:p1 wu2 idle '')"
export FAKE_AGENTS="$TMP/agents-u1.json"
mk_usage2 "$TMP/usage-u1.json" ok 0.10 $(( T0 + 3600000 )) ok 0.15 $(( T0 + 3600000 ))
export FAKE_USAGE="$TMP/usage-u1.json" FAKE_FETCHES="$TMP/fetches-u1.log"; : >"$FAKE_FETCHES"
reg "$SD_U1" "$T0" ws-u1zzz wu1 wu1:p1 3 1 0 0 acme/u1 "zzz-*" >/dev/null
reg "$SD_U1" "$T0" ws-u1ok wu2 wu2:p1 3 1 0 0 acme/u2 anthropic >/dev/null
# the daemon's actual cwd matters only to the vulnerable old code; the fix makes it inert
ST_U1="$(cd "$GLOBDIR" && MGR_STATE_DIR="$SD_U1" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(u) the glob-shaped provider is filtered out; the legitimate one is fetched" "$ST_U1" \
  '(.providers | keys) == ["anthropic"]'
assert_eq "(u) exactly one fetch happened" 1 "$(lines_of "$FAKE_FETCHES")"
assert_eq "(u) the fetch log names only the legitimate provider" "anthropic" "$(cat "$FAKE_FETCHES")"
if grep -q 'zzz' "$FAKE_FETCHES"; then
  fail "(u) the glob-vulnerable provider leaked into the fetch log: $(cat "$FAKE_FETCHES")"
else
  pass "(u) no zzz-anything was ever fetched (no glob expansion, no literal '*' fetch)"
fi
SD_U2="$TMP/s-u-space"
agents_file "$TMP/agents-u2.json" \
  "$(mk_agent manager wu3:p1 wu3 idle '')" \
  "$(mk_agent manager wu4:p1 wu4 idle '')"
export FAKE_AGENTS="$TMP/agents-u2.json" FAKE_FETCHES="$TMP/fetches-u2.log"; : >"$FAKE_FETCHES"
reg "$SD_U2" "$T0" ws-u2sp wu3 wu3:p1 3 1 0 0 acme/u3 "anthropic openai-codex" >/dev/null
reg "$SD_U2" "$T0" ws-u2ok wu4 wu4:p1 3 1 0 0 acme/u4 openai-codex >/dev/null
ST_U2="$(MGR_STATE_DIR="$SD_U2" MGR_GUARD_NOW_MS="$T0" "$GUARD" tick)"
assert_jq "(u) a provider with a space is filtered out; the legitimate one is fetched" "$ST_U2" \
  '(.providers | keys) == ["openai-codex"]'
assert_eq "(u) exactly one fetch happened" 1 "$(lines_of "$FAKE_FETCHES")"
assert_eq "(u) the fetch log names only the legitimate provider" "openai-codex" "$(cat "$FAKE_FETCHES")"
if grep -qx 'anthropic' "$FAKE_FETCHES"; then
  fail "(u) the space-separated provider word-split into a spurious anthropic fetch"
else
  pass "(u) no spurious anthropic fetch from word-splitting"
fi
unset FAKE_FETCHES

printf '\n== (v) issue #32 review: a provider that leaves the poll set keeps its stripped hold ==\n'
# review finding on the fix round: the poll set now follows live panes, so one manager pane
# blipping out of `herdr agent list` used to drop its provider from state.providers entirely,
# and JQ_POLICY rebuilds .providers from that tick's reports alone -- so an exhausted verdict's
# recovers_at/exhausted_limit vanished with it. A builder that then 429d on that provider during
# a usage outage got a stall record with recovers_at: null and missed its reset reignite.
SD_V="$TMP/s-v"
agents_file "$TMP/agents-v1.json" \
  "$(mk_agent manager wa:p1 wa idle '')" \
  "$(mk_agent manager wo:p1 wo idle '')"
export FAKE_AGENTS="$TMP/agents-v1.json"
export FAKE_PROMPTS="$TMP/prompts-v.log" FAKE_TOASTS="$TMP/toasts-v.log" FAKE_FETCHES="$TMP/fetches-v.log"
: >"$FAKE_PROMPTS"; : >"$FAKE_TOASTS"; : >"$FAKE_FETCHES"
RECOV_V=$(( T0 + 1800000 ))
mk_usage2 "$TMP/usage-v.json" exhausted 1.0 "$RECOV_V" ok 0.10 $(( T0 + 3600000 ))
export FAKE_USAGE="$TMP/usage-v.json"
reg "$SD_V" "$T0" ws-a wa wa:p1 3 1 0 0 acme/a anthropic >/dev/null
reg "$SD_V" "$T0" ws-o wo wo:p1 3 1 0 0 acme/o openai-codex >/dev/null
# tick1: both managers live, the fetch succeeds -- anthropic goes exhausted with a recovers_at
ST_V1="$(MGR_STATE_DIR="$SD_V" MGR_GUARD_NOW_MS=$(( T0 + 1000 )) "$GUARD" tick)"
assert_jq "(v) tick1: anthropic exhausted with a recovers_at and exhausted_limit" "$ST_V1" \
  '.providers.anthropic.status == "exhausted" and .providers.anthropic.ok == true
   and .providers.anthropic.recovers_at == '"$RECOV_V"' and .providers.anthropic.exhausted_limit == "anthropic:5h"'
# tick2: the blip -- wa:p1 drops out of `herdr agent list`, and the fetch fails for whoever
# is still polled, so nothing can refresh anthropic's verdict even if it were still polled
unset FAKE_USAGE
agents_file "$TMP/agents-v2.json" "$(mk_agent manager wo:p1 wo idle '')"
export FAKE_AGENTS="$TMP/agents-v2.json"
: >"$FAKE_FETCHES"
ST_V2="$(MGR_STATE_DIR="$SD_V" MGR_GUARD_NOW_MS=$(( T0 + 61000 )) "$GUARD" tick)"
if grep -q 'anthropic' "$FAKE_FETCHES"; then
  fail "(v) anthropic was polled despite its pane leaving the live set"
else
  pass "(v) anthropic was not polled while its pane was missing"
fi
assert_eq "(v) the only provider actually fetched is openai-codex" "openai-codex" "$(sort -u "$FAKE_FETCHES")"
assert_jq "(v) the stripped hold keeps status/ok/recovers_at/exhausted_limit, empty limits" "$ST_V2" \
  '.providers.anthropic
   | .status == "exhausted" and .ok == false
     and .recovers_at == '"$RECOV_V"' and .exhausted_limit == "anthropic:5h"
     and .usage_fetch_failures == 0 and (.limits | length) == 0
     and (.reason | startswith("unknown: not polled this tick"))'
# snapshot right here for the bounded variant below, before tick3/tick4 move SD_V forward
SD_V_BOUND="$TMP/s-v-bounded"
cp -a "$SD_V" "$SD_V_BOUND"
# tick3: wa:p1 is back, plus a builder that 429d on anthropic (issue-7, on ws-a's workspace) --
# still no usage fixture, so the fetch this tick fails too, but the held verdict survives
agents_file "$TMP/agents-v3.json" \
  "$(mk_agent manager wa:p1 wa idle '')" \
  "$(mk_agent manager wo:p1 wo idle '')" \
  "$(mk_agent issue-7 wb:p2 wa blocked "$SESS_ANTHROPIC")"
export FAKE_AGENTS="$TMP/agents-v3.json"
ST_V3="$(MGR_STATE_DIR="$SD_V" MGR_GUARD_NOW_MS=$(( T0 + 121000 )) "$GUARD" tick)"
assert_jq "(v) the stall record carries the held recovers_at and limit" "$ST_V3" \
  '.stalled[0].recovers_at == '"$RECOV_V"' and .stalled[0].limit == "anthropic:5h"'
assert_jq "(v) once polled again a failing fetch just holds (not the not-polled wording)" "$ST_V3" \
  '.providers.anthropic.reason | startswith("unknown: holding last verdict")'
# tick4: the reset has now passed, still no usage -- the reignite must fire, and it must
# name anthropic:5h, not the bare word "quota"
MGR_STATE_DIR="$SD_V" MGR_GUARD_NOW_MS=$(( T0 + 1801000 )) "$GUARD" tick >/dev/null
assert_eq "(v) exactly one reignite prompt fires at the reset" 1 "$(lines_of "$FAKE_PROMPTS")"
EXP_V="mgr-guard: anthropic:5h reset at $(iso_of "$RECOV_V") has passed (no fresh usage reading)"
case "$(cut -f2 <"$FAKE_PROMPTS")" in
  "$EXP_V"*) pass "(v) THE regression assertion: the reignite names anthropic:5h at the reset" ;;
  *) fail "(v) reignite text: $(cut -f2 <"$FAKE_PROMPTS")" ;;
esac
# bounded variant: from the tick2 state, once the reset has passed the hold must not become
# a permanent stale entry -- it has to drop the moment recovers_at is behind us
export FAKE_AGENTS="$TMP/agents-v2.json"
ST_VB="$(MGR_STATE_DIR="$SD_V_BOUND" MGR_GUARD_NOW_MS=$(( T0 + 1801000 )) "$GUARD" tick)"
assert_jq "(v) bounded: the hold drops once its reset has passed, anthropic is gone entirely" "$ST_VB" \
  '(.providers | has("anthropic") | not)'
unset FAKE_FETCHES

printf '\n== nothing in the guard ever interrupts a builder ==\n'
assert_eq "no send-keys in the whole run" 0 "$(lines_of "$FAKE_KEYS")"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'guard-smoke: all assertions passed\n'
  exit 0
fi
printf 'guard-smoke: %d assertion(s) failed\n' "$FAILURES"
exit 1
