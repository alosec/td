#!/usr/bin/env bash
# td - Todo tracker for AI agents
# Implementation: JSONL (append-only log, single file)
# Target: <1k LOC, <100ms response time
set -euo pipefail

VERSION="0.1.0"
TD_DIR=".td"
DATA_FILE="$TD_DIR/tasks.jsonl"

# Colors
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

die() { echo -e "${RED}error:${NC} $1" >&2; exit 1; }
info() { echo -e "${BLUE}info:${NC} $1" >&2; }

find_td_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    [[ -d "$dir/$TD_DIR" ]] && echo "$dir" && return 0
    dir="$(dirname "$dir")"
  done
  return 1
}

gen_id() { echo "td-$(echo "$(date +%s%N)$$" | sha256sum | head -c 6)"; }
now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

require_init() {
  TD_ROOT=$(find_td_root) || die "not initialized. Run 'td init'"
  TD_DIR="$TD_ROOT/$TD_DIR"
  DATA_FILE="$TD_DIR/tasks.jsonl"
}

# Get latest state for a task by scanning log
get_task() {
  local id="$1"
  grep "\"id\":\"$id\"" "$DATA_FILE" 2>/dev/null | tail -1
}

# Get all tasks (latest state for each)
get_all_tasks() {
  # Extract unique IDs then get latest state for each
  jq -r '.id' "$DATA_FILE" 2>/dev/null | sort -u | while read -r id; do
    get_task "$id"
  done | jq -s '.'
}

# Append event to log
append() {
  echo "$1" >> "$DATA_FILE"
}

JSON_OUTPUT=false
[[ "${1:-}" == "--json" ]] && { JSON_OUTPUT=true; shift; }
[[ "${1:-}" == "-j" ]] && { JSON_OUTPUT=true; shift; }

cmd_init() {
  local stealth=false
  [[ "${1:-}" == "--stealth" ]] && stealth=true
  
  [[ -d "$TD_DIR" ]] && die "already initialized"
  mkdir -p "$TD_DIR"
  touch "$DATA_FILE"
  
  $stealth && echo ".td/" >> .gitignore && info "initialized in stealth mode"
  info "initialized .td/"
  $JSON_OUTPUT && echo '{"success":true}'
}

cmd_create() {
  require_init
  local title="" priority=2 type="task" desc="" parent="" labels=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--priority) priority="$2"; shift 2 ;;
      -t|--type) type="$2"; shift 2 ;;
      -d|--desc) desc="$2"; shift 2 ;;
      --parent) parent="$2"; shift 2 ;;
      -l|--labels) labels="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) title="$1"; shift ;;
    esac
  done
  
  [[ -z "$title" ]] && die "title required"
  
  local id
  if [[ -n "$parent" ]]; then
    local child_count=$(grep -c "\"parent\":\"$parent\"" "$DATA_FILE" 2>/dev/null || echo 0)
    id="${parent}.$((child_count + 1))"
  else
    id=$(gen_id)
  fi
  
  local labels_json="[]"
  [[ -n "$labels" ]] && labels_json=$(echo "$labels" | tr ',' '\n' | jq -R . | jq -s .)
  
  local task=$(jq -n \
    --arg id "$id" \
    --arg title "$title" \
    --arg desc "$desc" \
    --arg type "$type" \
    --argjson priority "$priority" \
    --arg parent "$parent" \
    --argjson labels "$labels_json" \
    --arg ts "$(now)" \
    '{id:$id,title:$title,description:$desc,type:$type,priority:$priority,status:"open",parent:$parent,labels:$labels,blockers:[],created:$ts,updated:$ts}')
  
  append "$task"
  
  $JSON_OUTPUT && echo "$task" || echo -e "${GREEN}created${NC} $id: $title"
}

cmd_list() {
  require_init
  local status="" priority=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--status) status="$2"; shift 2 ;;
      -p|--priority) priority="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  local filter="true"
  [[ -n "$status" ]] && filter="$filter and .status == \"$status\""
  [[ -n "$priority" ]] && filter="$filter and .priority == $priority"
  
  local tasks=$(get_all_tasks | jq "map(select($filter))")
  
  if $JSON_OUTPUT; then
    echo "$tasks"
  else
    echo "$tasks" | jq -r '.[] | "\(.id)\t[\(.status)]\tP\(.priority)\t\(.title)"' | \
      while IFS=$'\t' read -r id status pri title; do
        printf "${BOLD}%-12s${NC} ${YELLOW}%-12s${NC} ${RED}%-4s${NC} %s\n" "$id" "$status" "$pri" "$title"
      done
  fi
}

cmd_ready() {
  require_init
  
  local all_tasks=$(get_all_tasks)
  local result=$(echo "$all_tasks" | jq '
    map(select(.status == "open")) |
    map(select(
      .blockers as $blockers |
      if ($blockers | length) == 0 then true
      else
        # Check if all blockers are closed
        ($blockers | all(. as $b |
          ('"$all_tasks"' | map(select(.id == $b and .status == "closed")) | length > 0)
        ))
      end
    )) |
    sort_by(.priority)
  ')
  
  if $JSON_OUTPUT; then
    echo "$result"
  else
    echo "$result" | jq -r '.[] | "\(.id)\tP\(.priority)\t\(.title)"' | \
      while IFS=$'\t' read -r id pri title; do
        printf "${GREEN}%-12s${NC} ${RED}%-4s${NC} %s\n" "$id" "$pri" "$title"
      done
  fi
}

cmd_show() {
  require_init
  local id="$1"
  [[ -z "$id" ]] && die "id required"
  
  local task=$(get_task "$id")
  [[ -z "$task" ]] && die "task $id not found"
  
  if $JSON_OUTPUT; then
    echo "$task"
  else
    echo -e "${BOLD}$(echo "$task" | jq -r '.id')${NC}: $(echo "$task" | jq -r '.title')"
    echo -e "Status: ${YELLOW}$(echo "$task" | jq -r '.status')${NC}  Priority: ${RED}P$(echo "$task" | jq -r '.priority')${NC}"
    local desc=$(echo "$task" | jq -r '.description')
    [[ -n "$desc" && "$desc" != "null" ]] && echo -e "\n$desc"
  fi
}

cmd_update() {
  require_init
  local id="$1"; shift
  [[ -z "$id" ]] && die "id required"
  
  local task=$(get_task "$id")
  [[ -z "$task" ]] && die "task $id not found"
  
  local updates=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--status) updates="$updates | .status = \"$2\""; shift 2 ;;
      -p|--priority) updates="$updates | .priority = $2"; shift 2 ;;
      -t|--title) updates="$updates | .title = \"$2\""; shift 2 ;;
      *) shift ;;
    esac
  done
  
  updates="$updates | .updated = \"$(now)\""
  local new_task=$(echo "$task" | jq "$updates")
  append "$new_task"
  
  $JSON_OUTPUT && echo "$new_task" || echo -e "${GREEN}updated${NC} $id"
}

cmd_done() {
  require_init
  for id in "$@"; do
    local task=$(get_task "$id")
    [[ -z "$task" ]] && { echo "task $id not found" >&2; continue; }
    local new_task=$(echo "$task" | jq '.status = "closed" | .updated = "'"$(now)"'"')
    append "$new_task"
    $JSON_OUTPUT && echo "$new_task" || echo -e "${GREEN}closed${NC} $id"
  done
}

cmd_reopen() {
  require_init
  for id in "$@"; do
    local task=$(get_task "$id")
    [[ -z "$task" ]] && continue
    append "$(echo "$task" | jq '.status = "open" | .updated = "'"$(now)"'"')"
    $JSON_OUTPUT || echo -e "${GREEN}reopened${NC} $id"
  done
}

cmd_dep() {
  require_init
  local action="${1:-}"; shift || true
  
  case "$action" in
    add)
      local child="$1" parent="$2"
      local task=$(get_task "$child")
      [[ -z "$task" ]] && die "task $child not found"
      local new_task=$(echo "$task" | jq --arg p "$parent" '.blockers += [$p] | .blockers |= unique | .updated = "'"$(now)"'"')
      append "$new_task"
      $JSON_OUTPUT && echo "$new_task" || echo -e "${GREEN}$child${NC} blocked by ${YELLOW}$parent${NC}"
      ;;
    rm)
      local child="$1" parent="$2"
      local task=$(get_task "$child")
      [[ -z "$task" ]] && die "task $child not found"
      append "$(echo "$task" | jq --arg p "$parent" '.blockers -= [$p] | .updated = "'"$(now)"'"')"
      ;;
    tree)
      local id="$1"
      echo "$id"
      grep "\"parent\":\"$id\"" "$DATA_FILE" 2>/dev/null | jq -r '.id' | sort -u | while read -r cid; do
        echo "  $cid"
      done
      ;;
    *) die "usage: td dep <add|rm|tree> ..." ;;
  esac
}

cmd_label() {
  require_init
  local action="${1:-}"; shift || true
  
  case "$action" in
    add)
      local id="$1" label="$2"
      local task=$(get_task "$id")
      [[ -z "$task" ]] && die "task $id not found"
      append "$(echo "$task" | jq --arg l "$label" '.labels += [$l] | .labels |= unique | .updated = "'"$(now)"'"')"
      $JSON_OUTPUT || echo -e "${GREEN}added${NC} label $label"
      ;;
    rm)
      local id="$1" label="$2"
      local task=$(get_task "$id")
      append "$(echo "$task" | jq --arg l "$label" '.labels -= [$l] | .updated = "'"$(now)"'"')"
      ;;
    list)
      get_task "$1" | jq -r '.labels[]'
      ;;
    list-all)
      get_all_tasks | jq -r '.[].labels[]' | sort -u
      ;;
    *) die "usage: td label <add|rm|list|list-all>" ;;
  esac
}

cmd_search() {
  require_init
  local query="$1"
  get_all_tasks | jq --arg q "$query" 'map(select(.title + .description | test($q; "i")))'
}

cmd_compact() {
  require_init
  info "compacting log..."
  local tasks=$(get_all_tasks)
  echo "$tasks" | jq -c '.[]' > "$DATA_FILE.tmp"
  mv "$DATA_FILE.tmp" "$DATA_FILE"
  local count=$(wc -l < "$DATA_FILE")
  info "compacted to $count entries"
}

cmd_stats() {
  require_init
  get_all_tasks | jq '{
    total: length,
    open: map(select(.status == "open")) | length,
    in_progress: map(select(.status == "in_progress")) | length,
    closed: map(select(.status == "closed")) | length
  }'
}

cmd_help() {
  cat << 'EOF'
td - Todo tracker for AI agents (JSONL implementation)

USAGE:
  td [--json] <command> [args]

COMMANDS:
  init [--stealth]        Initialize .td directory
  create <title> [opts]   Create task (-p priority, -t type, -d desc, --parent id)
  list [-s status] [-p n] List tasks
  ready                   Tasks with no open blockers
  show <id>               Show task details
  update <id> [opts]      Update task (-s status, -p priority)
  done <id>...            Mark task(s) closed
  reopen <id>...          Reopen task(s)
  dep add <c> <p>         Add dependency
  dep rm <c> <p>          Remove dependency
  dep tree <id>           Show children
  label add <id> <l>      Add label
  label rm <id> <l>       Remove label
  search <query>          Search tasks
  compact                 Compact log file
  stats                   Show statistics

FLAGS:
  --json, -j              Output JSON
EOF
}

case "${1:-help}" in
  init) shift; cmd_init "$@" ;;
  create|add) shift; cmd_create "$@" ;;
  list|ls) shift; cmd_list "$@" ;;
  ready) shift; cmd_ready "$@" ;;
  show) shift; cmd_show "$@" ;;
  update) shift; cmd_update "$@" ;;
  done|close) shift; cmd_done "$@" ;;
  reopen) shift; cmd_reopen "$@" ;;
  dep) shift; cmd_dep "$@" ;;
  label) shift; cmd_label "$@" ;;
  search) shift; cmd_search "$@" ;;
  compact) shift; cmd_compact "$@" ;;
  stats) shift; cmd_stats "$@" ;;
  help|--help|-h) cmd_help ;;
  version|--version) echo "td $VERSION (jsonl)" ;;
  *) die "unknown command: $1" ;;
esac
