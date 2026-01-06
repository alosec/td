#!/usr/bin/env bash
# td - Todo tracker for AI agents
# Implementation: Flat file (TSV-like, NO jq dependency)
# Target: <1k LOC, <100ms response time, ZERO external deps
set -euo pipefail

VERSION="0.1.0"
TD_DIR=".td"
DATA_FILE="$TD_DIR/tasks.tsv"
# Format: id\ttitle\ttype\tpriority\tstatus\tparent\tlabels\tblockers\tcreated\tupdated\tdescription

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

gen_id() { echo "td-$(head -c 100 /dev/urandom | sha256sum | head -c 6)"; }
now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

require_init() {
  TD_ROOT=$(find_td_root) || die "not initialized. Run 'td init'"
  TD_DIR="$TD_ROOT/$TD_DIR"
  DATA_FILE="$TD_DIR/tasks.tsv"
}

# Field positions (0-indexed)
F_ID=0; F_TITLE=1; F_TYPE=2; F_PRI=3; F_STATUS=4; F_PARENT=5
F_LABELS=6; F_BLOCKERS=7; F_CREATED=8; F_UPDATED=9; F_DESC=10

# Get field from line
get_f() { echo "$1" | cut -f$((${2}+1)); }

# Get task by ID
get_task() {
  local id="$1"
  grep "^${id}	" "$DATA_FILE" 2>/dev/null | tail -1
}

# Update task (replace line)
update_task() {
  local id="$1" newline="$2"
  local tmp=$(mktemp)
  grep -v "^${id}	" "$DATA_FILE" > "$tmp" 2>/dev/null || true
  echo "$newline" >> "$tmp"
  mv "$tmp" "$DATA_FILE"
}

# Output task as JSON (pure bash, no jq)
task_json() {
  local line="$1"
  local id=$(get_f "$line" $F_ID)
  local title=$(get_f "$line" $F_TITLE)
  local type=$(get_f "$line" $F_TYPE)
  local pri=$(get_f "$line" $F_PRI)
  local status=$(get_f "$line" $F_STATUS)
  local parent=$(get_f "$line" $F_PARENT)
  local labels=$(get_f "$line" $F_LABELS)
  local blockers=$(get_f "$line" $F_BLOCKERS)
  local created=$(get_f "$line" $F_CREATED)
  local updated=$(get_f "$line" $F_UPDATED)
  local desc=$(get_f "$line" $F_DESC)
  
  # Escape for JSON
  title="${title//\\/\\\\}"; title="${title//\"/\\\"}"
  desc="${desc//\\/\\\\}"; desc="${desc//\"/\\\"}"
  
  # Convert comma-sep to JSON array
  local labels_json="[]"
  if [[ -n "$labels" ]]; then
    labels_json="[$(echo "$labels" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/' )]"
  fi
  local blockers_json="[]"
  if [[ -n "$blockers" ]]; then
    blockers_json="[$(echo "$blockers" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/' )]"
  fi
  
  echo "{\"id\":\"$id\",\"title\":\"$title\",\"type\":\"$type\",\"priority\":$pri,\"status\":\"$status\",\"parent\":\"$parent\",\"labels\":$labels_json,\"blockers\":$blockers_json,\"created\":\"$created\",\"updated\":\"$updated\",\"description\":\"$desc\"}"
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
  
  $stealth && echo ".td/" >> .gitignore
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
    local child_count=$(grep -c "	$parent	" "$DATA_FILE" 2>/dev/null || echo 0)
    id="${parent}.$((child_count + 1))"
  else
    id=$(gen_id)
  fi
  
  local ts=$(now)
  # Escape tabs in title/desc
  title="${title//$'\t'/ }"
  desc="${desc//$'\t'/ }"
  
  local line="${id}	${title}	${type}	${priority}	open	${parent}	${labels}		${ts}	${ts}	${desc}"
  echo "$line" >> "$DATA_FILE"
  
  if $JSON_OUTPUT; then
    task_json "$line"
  else
    echo -e "${GREEN}created${NC} $id: $title"
  fi
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
  
  if $JSON_OUTPUT; then
    echo -n "["
    local first=true
  fi
  
  # Get unique IDs (latest entry wins)
  cut -f1 "$DATA_FILE" 2>/dev/null | sort -u | while read -r id; do
    local line=$(get_task "$id")
    [[ -z "$line" ]] && continue
    
    local s=$(get_f "$line" $F_STATUS)
    local p=$(get_f "$line" $F_PRI)
    
    [[ -n "$status" && "$s" != "$status" ]] && continue
    [[ -n "$priority" && "$p" != "$priority" ]] && continue
    
    if $JSON_OUTPUT; then
      $first || echo -n ","
      first=false
      task_json "$line"
    else
      local t=$(get_f "$line" $F_TITLE)
      printf "${BOLD}%-12s${NC} ${YELLOW}[%-11s]${NC} ${RED}P%-3s${NC} %s\n" "$id" "$s" "$p" "$t"
    fi
  done
  
  $JSON_OUTPUT && echo "]"
}

cmd_ready() {
  require_init
  
  if $JSON_OUTPUT; then
    echo -n "["
    local first=true
  fi
  
  cut -f1 "$DATA_FILE" 2>/dev/null | sort -u | while read -r id; do
    local line=$(get_task "$id")
    [[ -z "$line" ]] && continue
    
    local s=$(get_f "$line" $F_STATUS)
    [[ "$s" != "open" ]] && continue
    
    # Check blockers
    local blockers=$(get_f "$line" $F_BLOCKERS)
    local blocked=false
    
    if [[ -n "$blockers" ]]; then
      IFS=',' read -ra BLKS <<< "$blockers"
      for blk in "${BLKS[@]}"; do
        local blk_line=$(get_task "$blk")
        if [[ -n "$blk_line" ]]; then
          local blk_status=$(get_f "$blk_line" $F_STATUS)
          [[ "$blk_status" != "closed" ]] && blocked=true && break
        fi
      done
    fi
    
    $blocked && continue
    
    if $JSON_OUTPUT; then
      $first || echo -n ","
      first=false
      task_json "$line"
    else
      local t=$(get_f "$line" $F_TITLE)
      local p=$(get_f "$line" $F_PRI)
      printf "${GREEN}%-12s${NC} ${RED}P%-3s${NC} %s\n" "$id" "$p" "$t"
    fi
  done
  
  $JSON_OUTPUT && echo "]"
}

cmd_show() {
  require_init
  local id="$1"
  [[ -z "$id" ]] && die "id required"
  
  local line=$(get_task "$id")
  [[ -z "$line" ]] && die "task $id not found"
  
  if $JSON_OUTPUT; then
    task_json "$line"
  else
    echo -e "${BOLD}$(get_f "$line" $F_ID)${NC}: $(get_f "$line" $F_TITLE)"
    echo "Status: $(get_f "$line" $F_STATUS)  Priority: P$(get_f "$line" $F_PRI)  Type: $(get_f "$line" $F_TYPE)"
    local desc=$(get_f "$line" $F_DESC)
    [[ -n "$desc" ]] && echo -e "\n$desc"
    local labels=$(get_f "$line" $F_LABELS)
    [[ -n "$labels" ]] && echo -e "\nLabels: $labels"
    local blockers=$(get_f "$line" $F_BLOCKERS)
    [[ -n "$blockers" ]] && echo "Blockers: $blockers"
    echo -e "\nCreated: $(get_f "$line" $F_CREATED)"
    echo "Updated: $(get_f "$line" $F_UPDATED)"
  fi
}

cmd_update() {
  require_init
  local id="$1"; shift
  [[ -z "$id" ]] && die "id required"
  
  local line=$(get_task "$id")
  [[ -z "$line" ]] && die "task $id not found"
  
  # Parse existing
  local title=$(get_f "$line" $F_TITLE)
  local type=$(get_f "$line" $F_TYPE)
  local priority=$(get_f "$line" $F_PRI)
  local status=$(get_f "$line" $F_STATUS)
  local parent=$(get_f "$line" $F_PARENT)
  local labels=$(get_f "$line" $F_LABELS)
  local blockers=$(get_f "$line" $F_BLOCKERS)
  local created=$(get_f "$line" $F_CREATED)
  local desc=$(get_f "$line" $F_DESC)
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--status) status="$2"; shift 2 ;;
      -p|--priority) priority="$2"; shift 2 ;;
      -t|--title) title="$2"; shift 2 ;;
      -d|--desc) desc="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  local newline="${id}	${title}	${type}	${priority}	${status}	${parent}	${labels}	${blockers}	${created}	$(now)	${desc}"
  update_task "$id" "$newline"
  
  $JSON_OUTPUT && task_json "$newline" || echo -e "${GREEN}updated${NC} $id"
}

cmd_done() {
  require_init
  for id in "$@"; do
    local line=$(get_task "$id")
    [[ -z "$line" ]] && { echo "task $id not found" >&2; continue; }
    
    local title=$(get_f "$line" $F_TITLE)
    local type=$(get_f "$line" $F_TYPE)
    local priority=$(get_f "$line" $F_PRI)
    local parent=$(get_f "$line" $F_PARENT)
    local labels=$(get_f "$line" $F_LABELS)
    local blockers=$(get_f "$line" $F_BLOCKERS)
    local created=$(get_f "$line" $F_CREATED)
    local desc=$(get_f "$line" $F_DESC)
    
    local newline="${id}	${title}	${type}	${priority}	closed	${parent}	${labels}	${blockers}	${created}	$(now)	${desc}"
    update_task "$id" "$newline"
    $JSON_OUTPUT || echo -e "${GREEN}closed${NC} $id"
  done
}

cmd_reopen() {
  require_init
  for id in "$@"; do
    local line=$(get_task "$id")
    [[ -z "$line" ]] && continue
    
    local title=$(get_f "$line" $F_TITLE)
    local type=$(get_f "$line" $F_TYPE)
    local priority=$(get_f "$line" $F_PRI)
    local parent=$(get_f "$line" $F_PARENT)
    local labels=$(get_f "$line" $F_LABELS)
    local blockers=$(get_f "$line" $F_BLOCKERS)
    local created=$(get_f "$line" $F_CREATED)
    local desc=$(get_f "$line" $F_DESC)
    
    local newline="${id}	${title}	${type}	${priority}	open	${parent}	${labels}	${blockers}	${created}	$(now)	${desc}"
    update_task "$id" "$newline"
    $JSON_OUTPUT || echo -e "${GREEN}reopened${NC} $id"
  done
}

cmd_dep() {
  require_init
  local action="${1:-}"; shift || true
  
  case "$action" in
    add)
      local child="$1" parent="$2"
      local line=$(get_task "$child")
      [[ -z "$line" ]] && die "task $child not found"
      
      local blockers=$(get_f "$line" $F_BLOCKERS)
      [[ -n "$blockers" ]] && blockers="${blockers},"
      blockers="${blockers}${parent}"
      
      local title=$(get_f "$line" $F_TITLE)
      local type=$(get_f "$line" $F_TYPE)
      local priority=$(get_f "$line" $F_PRI)
      local status=$(get_f "$line" $F_STATUS)
      local par=$(get_f "$line" $F_PARENT)
      local labels=$(get_f "$line" $F_LABELS)
      local created=$(get_f "$line" $F_CREATED)
      local desc=$(get_f "$line" $F_DESC)
      
      local newline="${child}	${title}	${type}	${priority}	${status}	${par}	${labels}	${blockers}	${created}	$(now)	${desc}"
      update_task "$child" "$newline"
      $JSON_OUTPUT || echo -e "${GREEN}$child${NC} blocked by ${YELLOW}$parent${NC}"
      ;;
    rm)
      local child="$1" parent="$2"
      local line=$(get_task "$child")
      [[ -z "$line" ]] && die "task $child not found"
      
      local blockers=$(get_f "$line" $F_BLOCKERS)
      blockers=$(echo "$blockers" | sed "s/$parent//" | sed 's/,,/,/' | sed 's/^,//' | sed 's/,$//')
      
      local title=$(get_f "$line" $F_TITLE)
      local type=$(get_f "$line" $F_TYPE)
      local priority=$(get_f "$line" $F_PRI)
      local status=$(get_f "$line" $F_STATUS)
      local par=$(get_f "$line" $F_PARENT)
      local labels=$(get_f "$line" $F_LABELS)
      local created=$(get_f "$line" $F_CREATED)
      local desc=$(get_f "$line" $F_DESC)
      
      local newline="${child}	${title}	${type}	${priority}	${status}	${par}	${labels}	${blockers}	${created}	$(now)	${desc}"
      update_task "$child" "$newline"
      ;;
    tree)
      local id="$1"
      echo "$id"
      grep "	$id	" "$DATA_FILE" 2>/dev/null | cut -f1 | sort -u | while read -r cid; do
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
      local line=$(get_task "$id")
      [[ -z "$line" ]] && die "task $id not found"
      
      local labels=$(get_f "$line" $F_LABELS)
      [[ -n "$labels" ]] && labels="${labels},"
      labels="${labels}${label}"
      
      local title=$(get_f "$line" $F_TITLE)
      local type=$(get_f "$line" $F_TYPE)
      local priority=$(get_f "$line" $F_PRI)
      local status=$(get_f "$line" $F_STATUS)
      local parent=$(get_f "$line" $F_PARENT)
      local blockers=$(get_f "$line" $F_BLOCKERS)
      local created=$(get_f "$line" $F_CREATED)
      local desc=$(get_f "$line" $F_DESC)
      
      local newline="${id}	${title}	${type}	${priority}	${status}	${parent}	${labels}	${blockers}	${created}	$(now)	${desc}"
      update_task "$id" "$newline"
      $JSON_OUTPUT || echo -e "${GREEN}added${NC} label $label"
      ;;
    rm)
      local id="$1" label="$2"
      local line=$(get_task "$id")
      [[ -z "$line" ]] && die "task $id not found"
      
      local labels=$(get_f "$line" $F_LABELS)
      labels=$(echo "$labels" | sed "s/$label//" | sed 's/,,/,/' | sed 's/^,//' | sed 's/,$//')
      
      local title=$(get_f "$line" $F_TITLE)
      local type=$(get_f "$line" $F_TYPE)
      local priority=$(get_f "$line" $F_PRI)
      local status=$(get_f "$line" $F_STATUS)
      local parent=$(get_f "$line" $F_PARENT)
      local blockers=$(get_f "$line" $F_BLOCKERS)
      local created=$(get_f "$line" $F_CREATED)
      local desc=$(get_f "$line" $F_DESC)
      
      local newline="${id}	${title}	${type}	${priority}	${status}	${parent}	${labels}	${blockers}	${created}	$(now)	${desc}"
      update_task "$id" "$newline"
      ;;
    list)
      get_f "$(get_task "$1")" $F_LABELS | tr ',' '\n'
      ;;
    list-all)
      cut -f7 "$DATA_FILE" 2>/dev/null | tr ',' '\n' | sort -u | grep -v '^$'
      ;;
    *) die "usage: td label <add|rm|list|list-all>" ;;
  esac
}

cmd_search() {
  require_init
  local query="$1"
  
  if $JSON_OUTPUT; then
    echo -n "["
    local first=true
  fi
  
  grep -i "$query" "$DATA_FILE" 2>/dev/null | cut -f1 | sort -u | while read -r id; do
    local line=$(get_task "$id")
    if $JSON_OUTPUT; then
      $first || echo -n ","
      first=false
      task_json "$line"
    else
      local t=$(get_f "$line" $F_TITLE)
      printf "${BOLD}%-12s${NC} %s\n" "$id" "$t"
    fi
  done
  
  $JSON_OUTPUT && echo "]"
}

cmd_compact() {
  require_init
  info "compacting..."
  local tmp=$(mktemp)
  
  # Keep only latest entry per ID
  cut -f1 "$DATA_FILE" | sort -u | while read -r id; do
    get_task "$id" >> "$tmp"
  done
  
  mv "$tmp" "$DATA_FILE"
  local count=$(wc -l < "$DATA_FILE")
  info "compacted to $count entries"
}

cmd_stats() {
  require_init
  local total=$(cut -f1 "$DATA_FILE" 2>/dev/null | sort -u | wc -l)
  local open=$(grep "	open	" "$DATA_FILE" 2>/dev/null | cut -f1 | sort -u | wc -l)
  local in_progress=$(grep "	in_progress	" "$DATA_FILE" 2>/dev/null | cut -f1 | sort -u | wc -l)
  local closed=$(grep "	closed	" "$DATA_FILE" 2>/dev/null | cut -f1 | sort -u | wc -l)
  
  if $JSON_OUTPUT; then
    echo "{\"total\":$total,\"open\":$open,\"in_progress\":$in_progress,\"closed\":$closed}"
  else
    echo "Total: $total | Open: $open | In Progress: $in_progress | Closed: $closed"
  fi
}

cmd_help() {
  cat << 'EOF'
td - Todo tracker for AI agents (Flat file implementation)

ZERO EXTERNAL DEPENDENCIES. Pure bash + coreutils.

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
  compact                 Remove duplicate entries
  stats                   Show statistics

FLAGS:
  --json, -j              Output JSON

Data stored as TSV in .td/tasks.tsv
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
  version|--version) echo "td $VERSION (flat-file)" ;;
  *) die "unknown command: $1" ;;
esac
