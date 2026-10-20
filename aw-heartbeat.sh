#!/usr/bin/env bash
# Claude Code hook → ActivityWatch. Reads hook JSON on stdin, detaches immediately.
# AW's heartbeat endpoint only merges into a bucket's last event, which breaks with concurrent
# sessions, so each session tracks and extends its own event by id.
set -uo pipefail

AW_CURL=${AW_CURL:-curl.exe}
AW_URL=${AW_URL:-http://localhost:5600/api/0}
AW_PULSETIME=${AW_PULSETIME:-300}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/aw-watcher-claude-code

input=$(cat)

main() {
  mkdir -p "$STATE_DIR"

  local host_file=$STATE_DIR/hostname
  [[ -s $host_file ]] || hostname.exe | tr -d '\r\n' >"$host_file"
  local bucket=aw-watcher-claude-code_$(<"$host_file")

  if [[ ! -e $STATE_DIR/bucket-created ]]; then
    aw POST "/buckets/$bucket" "{\"client\":\"aw-watcher-claude-code\",\"type\":\"app.claude-code.activity\",\"hostname\":\"$(<"$host_file")\"}" \
      && touch "$STATE_DIR/bucket-created"
  fi

  local session cwd transcript
  session=$(jq -r '.session_id' <<<"$input")
  cwd=$(jq -r '.cwd' <<<"$input")
  transcript=$(jq -r '.transcript_path // empty' <<<"$input")

  local state=$STATE_DIR/$session.json
  exec 9>"$state.lock"
  flock 9

  local prev
  prev=$([[ -s $state ]] && cat "$state" || echo '{}')

  # Outside a repo (e.g. ~/projects) keep the session's last project rather than flapping.
  local repo project branch ticket title model effort
  repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  if [[ -n $repo ]]; then
    project=$(basename "$repo")
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
    ticket=$(grep -oiE '(AB[#_-]?|^|/)[0-9]{3,}' <<<"$branch" | head -1 | grep -oE '[0-9]+' | sed 's/^/AB#/')
  else
    project=$(jq -r --arg d "$(basename "$cwd")" '.data.project // $d' <<<"$prev")
    branch=$(jq -r '.data.branch // ""' <<<"$prev")
    ticket=$(jq -r '.data.ticket // ""' <<<"$prev")
  fi
  title=$([[ -f $transcript ]] && tac "$transcript" | grep -m1 -E '"type":"(custom-title|ai-title)"' | jq -r '.customTitle // .aiTitle // empty')
  model=$([[ -f $transcript ]] && tac "$transcript" | grep -a '"type":"assistant"' | jq -rn 'first(inputs | .message.model // empty | select(startswith("claude-")))')

  effort=$([[ -f $transcript ]] && tac "$transcript" | grep -a '"type":"api-request"' \
    | jq -rn 'first(inputs | select(.querySource == "repl_main_thread") | .params.output_config.effort // empty)')

  local data cost
  data=$(jq -nc --arg project "$project" --arg branch "$branch" \
    --arg ticket "$ticket" --arg title "$title" --arg model "$model" --arg effort "$effort" --arg session "$session" \
    'def nullable: if . == "" then null else . end;
     {project:$project, branch:($branch|nullable), ticket:($ticket|nullable), title:($title|nullable),
      model:($model|nullable), effort:($effort|nullable), session_id:$session}')
  cost=$(session_cost "$transcript")

  local now_iso now
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  now=$(date -u +%s.%3N)

  backfill "$bucket" "$session" "$prev" "$data"

  # Cost since the previous heartbeat belongs to whichever event this heartbeat lands in.
  local id start start_iso cost_base
  if jq -e --argjson d "$data" --argjson now "$now" --argjson pulse "$AW_PULSETIME" \
      '.event.id and .data == $d and ($now - .last) < $pulse' <<<"$prev" >/dev/null; then
    id=$(jq -r '.event.id' <<<"$prev")
    start=$(jq -r '.event.start' <<<"$prev")
    start_iso=$(jq -r '.event.timestamp' <<<"$prev")
    cost_base=$(jq -r --argjson c "$cost" '.event.cost_base // $c' <<<"$prev")
    aw POST "/buckets/$bucket/events" \
      "$(jq -nc --argjson id "$id" --arg ts "$start_iso" --argjson dur "$(jq -n "$now - $start")" --argjson d "$data" --argjson c "$(jq -n "$cost - $cost_base")" \
        '[{id:$id, timestamp:$ts, duration:$dur, data:($d + {cost_usd:$c})}]')"
  else
    cost_base=$(jq -r --argjson c "$cost" '.cost // $c' <<<"$prev")
    aw POST "/buckets/$bucket/events" \
      "$(jq -nc --arg ts "$now_iso" --argjson d "$data" --argjson c "$(jq -n "$cost - $cost_base")" \
        '{timestamp:$ts, duration:0, data:($d + {cost_usd:$c})}')"
    id=$(aw GET "/buckets/$bucket/events?start=${now_iso%.*}Z&limit=50" \
      | jq -r --arg s "$session" --arg ts "$now_iso" '[.[] | select(.data.session_id == $s and .timestamp[0:23] == $ts[0:23])][0].id // empty')
    start=$now
    start_iso=$now_iso
  fi

  jq -nc --argjson prev "$prev" --arg id "$id" --argjson start "$start" --arg ts "$start_iso" --argjson now "$now" \
    --argjson d "$data" --arg now_iso "$now_iso" --argjson cost "$cost" --argjson cost_base "$cost_base" \
    '{started:($prev.started // $now_iso), event:{id:($id|tonumber? // null), start:$start, timestamp:$ts, cost_base:$cost_base},
      last:$now, cost:$cost, data:$d}' >"$state"
}

# Estimated list-price USD for the session so far, including its subagents.
session_cost() {
  local transcript=$1
  [[ -f $transcript ]] || { echo 0; return; }
  cat "$transcript" "${transcript%.jsonl}"/subagents/*.jsonl 2>/dev/null | grep -a '"type":"assistant"' \
    | jq -s --slurpfile p "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/prices.json" '
      $p[0] as $prices
      | [unique_by(.message.id)[] | .message as $m | $m.usage as $u
         | $prices[$m.model | sub("-[0-9]{8}$"; "")] as $r | select($r)
         | (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0)) as $prompt
         | (if $r.over_100k and $prompt > 100000 then $r.over_100k else $r end) as $r
         | (($u.input_tokens // 0) * $r.input
            + ($u.output_tokens // 0) * $r.output
            + ($u.cache_creation.ephemeral_5m_input_tokens // $u.cache_creation_input_tokens // 0) * $r.cache_write_5m
            + ($u.cache_creation.ephemeral_1h_input_tokens // 0) * $r.cache_write_1h
            + ($u.cache_read_input_tokens // 0) * $r.cache_read) / 1e6]
      | add // 0'
}

# Earlier events in this session get the latest title, and the ticket where they had none.
backfill() {
  local bucket=$1 session=$2 prev=$3 data=$4
  local started ticket title
  started=$(jq -r '.started // empty' <<<"$prev")
  ticket=$(jq -r '.ticket // ""' <<<"$data")
  title=$(jq -r '.title // ""' <<<"$data")
  [[ -z $started ]] && return
  [[ $(jq -r '.data.ticket // ""' <<<"$prev") == "$ticket" && $(jq -r '.data.title // ""' <<<"$prev") == "$title" ]] && return

  local patched
  patched=$(aw GET "/buckets/$bucket/events?start=$started&limit=10000" | jq -c --arg s "$session" --arg t "$ticket" --arg ti "$title" '
    [.[] | select(.data.session_id == $s)
         | select(($ti != "" and .data.title != $ti) or ($t != "" and .data.ticket == null))
         | if $ti != "" then .data.title = $ti else . end
         | if $t != "" and .data.ticket == null then .data.ticket = $t else . end]')
  [[ $patched != "[]" && -n $patched ]] && aw POST "/buckets/$bucket/events" "$patched"
}

aw() {
  local method=$1 path=$2 body=${3:-}
  if [[ -n $body ]]; then
    "$AW_CURL" -sf -X "$method" "$AW_URL$path" -H 'Content-Type: application/json' --data-binary @- <<<"$body"
  else
    "$AW_CURL" -sf -X "$method" "$AW_URL$path"
  fi
}

main >/dev/null 2>&1 &
disown
