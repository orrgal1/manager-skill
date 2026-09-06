# shellcheck shell=bash
# mgr-lib.sh — shared library sourced by both bin/mgr and bin/mgr-guard. Holds
# the session-metrics jq behind the execution record `mgr retire` writes, and
# the RATE_RE pattern both scripts key their rate-limit detection off of.

declare -F warn >/dev/null 2>&1 || warn() { printf 'mgr: warning: %s\n' "$*" >&2; }

# ---------------------------------------------------------------- jq programs

# the single rate-limit pattern mgr-guard's stall detection and mgr's
# session_metrics both test errorMessage against
RATE_RE='rate.?limit|too many requests|(^|[^0-9])429([^0-9]|$)|resource_exhausted|quota_exhausted|usage.?limit|insufficient_quota|overloaded'

# raw session-jsonl lines on stdin -> the `session` sub-object (minus read/subagents)
JQ_SESSION_METRICS='
[ inputs | (fromjson? // empty) | select(type == "object") ] as $lines
| ($lines
    | map(select(.type == "message" and (.message | type) == "object" and .message.role == "assistant"))
    | map(.message)) as $msgs
| {
    turns: ($msgs | length),
    tokens: {
      input: ($msgs | map(.usage.input // 0) | add // 0),
      output: ($msgs | map(.usage.output // 0) | add // 0),
      cache_read: ($msgs | map(.usage.cacheRead // 0) | add // 0),
      cache_write: ($msgs | map(.usage.cacheWrite // 0) | add // 0),
      total: ($msgs | map(.usage.totalTokens // ((.usage.input // 0) + (.usage.output // 0))) | add // 0)
    },
    cost_usd: (($msgs | map(.usage.cost.total) | map(select(. != null))) as $c
               | if ($c | length) == 0 then null else ($c | add * 1e6 | round / 1e6) end),
    active_ms: (($msgs | map(.duration) | map(select(. != null))) as $d
                | if ($d | length) == 0 then null else ($d | add) end),
    models: ($msgs | map(.model) | map(select(. != null)) | group_by(.) | map({key: .[0], value: length}) | from_entries),
    model_changes: ($lines | map(select(.type == "model_change")) | length),
    resizes: ($lines | map(select(.type == "title_change" and .trigger == "replan")) | length),
    stop_reasons: ($msgs | map(.stopReason) | map(select(. != null)) | group_by(.) | map({key: .[0], value: length}) | from_entries),
    rate_limit_hits: ($msgs
      | map(select(.stopReason == "error"
          and ((.errorStatus == 429) or ((.errorMessage // "") | test($re; "i")))))
      | length)
  }
'

# concatenated subagent-transcript lines on stdin -> {count,agents,roles,models}
JQ_SUBAGENTS='
[ inputs | (fromjson? // empty) | select(type == "object")
  | select(.type == "session_init" or has("session_init"))
  | (.session_init // .) ] as $inits
| {
    count: ($inits | length),
    agents: ($inits | map(.agent) | map(select(. != null)) | group_by(.) | map({key: .[0], value: length}) | from_entries),
    roles: ($inits | map(.modelRole) | map(select(. != null)) | group_by(.) | map({key: .[0], value: length}) | from_entries),
    models: ($inits | map(.resolvedModel) | map(select(. != null)) | group_by(.) | map({key: .[0], value: length}) | from_entries)
  }
'

# a model string like anthropic/claude-fable-5-1:high stripped of its
# provider prefix and effort suffix -> claude-fable-5-1; null stays null
JQ_SHORT_MODEL='def short_model: if . == null then null else (sub("^[^/]*/"; "") | sub(":[^/]*$"; "")) end;'

# raw session-jsonl lines on stdin -> {provider,model}: the last assistant
# message's own facts (nulls when none). Same shape and tail-window logic as
# bin/mgr's JQ_SELF_FACTS/self_house.
JQ_SESSION_FACTS='
[ inputs | (fromjson? // empty) | select(type == "object")
  | select((.type == "message") and ((.message | type) == "object")
           and (.message.role == "assistant")) ]
| (last // null)
| if . == null then {provider:null, model:null}
  else {provider:(.message.provider // null), model:(.message.model // null)} end'

session_facts() { # session_facts <session.jsonl> -> {provider,model} JSON; never fails
  local f="${1:-}" body size
  local none='{"provider":null,"model":null}'

  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    printf '%s\n' "$none"
    return 0
  fi

  size=$(wc -c <"$f" 2>/dev/null | tr -d ' ') || size=0
  case "$size" in ''|*[!0-9]*) size=0;; esac
  if [ "$size" -gt 65536 ]; then
    body=$(tail -c 65536 "$f" 2>/dev/null | sed 1d) || body=""
  else
    body=$(cat "$f" 2>/dev/null) || body=""
  fi

  printf '%s\n' "$body" | jq -Rnc "$JQ_SESSION_FACTS" 2>/dev/null || printf '%s\n' "$none"
}

session_metrics() { # session_metrics <session.jsonl> -> session sub-object; never fails
  local f="${1:-}" null_shape parent dir sub sfile out
  null_shape='{"read":false,"turns":null,"tokens":{"input":null,"output":null,"cache_read":null,"cache_write":null,"total":null},"cost_usd":null,"active_ms":null,"models":null,"model_changes":null,"resizes":null,"stop_reasons":null,"rate_limit_hits":null,"subagents":{"count":null,"agents":null,"roles":null,"models":null}}'

  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    warn "session file unreadable: ${f:-(none)}"
    printf '%s\n' "$null_shape"
    return 0
  fi

  if ! parent=$(jq -Rnc --arg re "$RATE_RE" "$JQ_SESSION_METRICS" <"$f" 2>/dev/null); then
    warn "session file unreadable: $f"
    printf '%s\n' "$null_shape"
    return 0
  fi

  dir="${f%.jsonl}"
  sub=$(
    for sfile in "$dir"/*.jsonl; do
      [ -f "$sfile" ] || continue
      cat "$sfile"
    done | jq -Rnc "$JQ_SUBAGENTS" 2>/dev/null
  ) || sub=""
  [ -n "$sub" ] || sub='{"count":0,"agents":{},"roles":{},"models":{}}'

  if ! out=$(jq -c --argjson s "$sub" '{read:true} + . + {subagents:$s}' <<<"$parent" 2>/dev/null); then
    warn "session file unreadable: $f"
    printf '%s\n' "$null_shape"
    return 0
  fi

  printf '%s\n' "$out"
  return 0
}
