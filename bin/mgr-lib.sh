# shellcheck shell=bash
# mgr-lib.sh — shared library sourced by bin/mgr and reachable by bin/mgr-guard
# via `$(dirname "$0")/mgr-lib.sh`. Holds the session-metrics jq the two
# scripts both need (mgr for the retire record, mgr-guard for session facts).

declare -F warn >/dev/null 2>&1 || warn() { printf 'mgr: warning: %s\n' "$*" >&2; }

# ---------------------------------------------------------------- jq programs

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
               | if ($c | length) == 0 then null else ($c | add) end),
    active_ms: (($msgs | map(.duration) | map(select(. != null))) as $d
                | if ($d | length) == 0 then null else ($d | add) end),
    models: ($msgs | map(.model) | map(select(. != null)) | group_by(.) | map({key: .[0], value: length}) | from_entries),
    model_changes: ($lines | map(select(.type == "model_change")) | length),
    resizes: ($lines | map(select(.type == "title_change" and .trigger == "replan")) | length),
    stop_reasons: ($msgs | map(.stopReason) | map(select(. != null)) | group_by(.) | map({key: .[0], value: length}) | from_entries),
    rate_limit_hits: ($msgs
      | map(select(.stopReason == "error"
          and ((.errorStatus == 429) or ((.errorMessage // "") | test("rate.?limit|429|too many requests"; "i")))))
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

session_metrics() { # session_metrics <session.jsonl> -> session sub-object; never fails
  local f="${1:-}" null_shape parent dir sub sfile out
  null_shape='{"read":false,"turns":null,"tokens":{"input":null,"output":null,"cache_read":null,"cache_write":null,"total":null},"cost_usd":null,"active_ms":null,"models":null,"model_changes":null,"resizes":null,"stop_reasons":null,"rate_limit_hits":null,"subagents":{"count":null,"agents":null,"roles":null,"models":null}}'

  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    warn "session file unreadable: ${f:-(none)}"
    printf '%s\n' "$null_shape"
    return 0
  fi

  if ! parent=$(jq -Rnc "$JQ_SESSION_METRICS" <"$f" 2>/dev/null); then
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
