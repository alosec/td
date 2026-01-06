#!/usr/bin/env bash
# td - Todo tracker for AI agents
# Implementation: JSON files (one file per task)
# Target: <1k LOC, <100ms response time
set -euo pipefail

VERSION="0.1.0"
TD_DIR=".td"
TASKS_DIR="$TD_DIR/tasks"
CONFIG_FILE="$TD_DIR/config.json"

# Colors (disable with NO_COLOR=1)
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

die() { echo -e "${RED}error:${NC} $1" >&2; exit 1; }
warn() { echo -e "${YELLOW}warn:${NC} $1" >&2; }
info() { echo -e "${BLUE}info:${NC} $1" >&2; }

# Find .td directory (walk up)
find_td_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    [[ -d "$dir/$TD_DIR" ]] && echo "$dir" && return 0
    dir="$(dirname "$dir")"
  done
  return 1
}

# Generate short hash ID
gen_id() {
  local hash=$(echo "$(date +%s%N)$$" | sha256sum | head -c 6)
  echo "td-$hash"
}

# Get timestamp
now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Ensure initialized
require_init() {
  TD_ROOT=$(find_td_root) || die "not initialized. Run 'td init'"
  TD_DIR="$TD_ROOT/$TD_DIR"
  TASKS_DIR="$TD_DIR/tasks"
  CONFIG_FILE="$TD_DIR/config.json"
}

# JSON output mode
JSON_OUTPUT=false
[[ "${1:-}" == "--json" ]] && { JSON_OUTPUT=true; shift; }
[[ "${1:-}" == "-j" ]] && { JSON_OUTPUT=true; shift; }

cmd_init() {
  local stealth=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stealth) stealth=true; shift ;;
      *) shift ;;
    esac
  done

  [[ -d "$TD_DIR" ]] && die "already initialized"
  mkdir -p "$TASKS_DIR"
  echo '{"version":"'"$VERSION"'","created":"'"$(now)"'"}' > "$CONFIG_FILE"
  
  if $stealth; then
    echo ".td/" >> .gitignore
    info "initialized in stealth mode (.td added to .gitignore)"
  else
    info "initialized .td/"
  fi
  
  $JSON_OUTPUT && echo '{"success":true,"path":"'"$PWD/$TD_DIR"'"}'
}

cmd_create() {
  require_init
  local title="" priority=2 type="task" desc="" parent="" labels=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--priority) priority="$2"; shift 2 ;;
      -t|--type) type="$2"; shift 2 ;;
      -d|--desc|--description) desc="$2"; shift 2 ;;
      --parent) parent="$2"; shift 2 ;;
      -l|--label|--labels) labels="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) title="$1"; shift ;;
    esac
  done
  
  [[ -z "$title" ]] && die "title required"
  
  local id
  if [[ -n "$parent" ]]; then
    # Hierarchical ID for subtasks
    local parent_file="$TASKS_DIR/${parent}.json"
    [[ -f "$parent_file" ]] || die "parent $parent not found"
    local child_count=$(find "$TASKS_DIR" -name "${parent}.*" 2>/dev/null | wc -l)
    id="${parent}.$((child_count + 1))"
  else
    id=$(gen_id)
  fi
  
  local labels_json="[]"
  [[ -n "$labels" ]] && labels_json=$(echo "$labels" | tr ',' '\n' | jq -R . | jq -s .)
  
  local task_file="$TASKS_DIR/${id}.json"
  jq -n \
    --arg id "$id" \
    --arg title "$title" \
    --arg desc "$desc" \
    --arg type "$type" \
    --argjson priority "$priority" \
    --arg status "open" \
    --arg parent "$parent" \
    --argjson labels "$labels_json" \
    --arg created "$(now)" \
    --arg updated "$(now)" \
    '{id:$id,title:$title,description:$desc,type:$type,priority:$priority,status:$status,parent:$parent,labels:$labels,blockers:[],created:$created,updated:$updated}' \
    > "$task_file"
  
  if $JSON_OUTPUT; then
    cat "$task_file"
  else
    echo -e "${GREEN}created${NC} $id: $title"
  fi
}

cmd_list() {
  require_init
  local status="" priority="" type="" label=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--status) status="$2"; shift 2 ;;
      -p|--priority) priority="$2"; shift 2 ;;
      -t|--type) type="$2"; shift 2 ;;
      -l|--label) label="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  local filter="true"
  [[ -n "$status" ]] && filter="$filter and .status == \"$status\""
  [[ -n "$priority" ]] && filter="$filter and .priority == $priority"
  [[ -n "$type" ]] && filter="$filter and .type == \"$type\""
  [[ -n "$label" ]] && filter="$filter and (.labels | index(\"$label\"))"
  
  local tasks=$(find "$TASKS_DIR" -name "*.json" -exec cat {} \; 2>/dev/null | jq -s "map(select($filter))")
  
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
  
  # Single jq pass: load all tasks, filter to open ones with no open blockers
  local result=$(find "$TASKS_DIR" -name "*.json" -exec cat {} \; 2>/dev/null | jq -s '
    . as $all |
    map(select(.status == "open")) |
    map(select(
      .blockers as $blockers |
      ($blockers | length == 0) or
      ($blockers | all(. as $b | 
        ($all | map(select(.id == $b and .status == "closed")) | length > 0)
      ))
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
  
  local task_file="$TASKS_DIR/${id}.json"
  [[ -f "$task_file" ]] || die "task $id not found"
  
  if $JSON_OUTPUT; then
    cat "$task_file"
  else
    local task=$(cat "$task_file")
    echo -e "${BOLD}$(echo "$task" | jq -r '.id')${NC}: $(echo "$task" | jq -r '.title')"
    echo -e "Status: ${YELLOW}$(echo "$task" | jq -r '.status')${NC}  Priority: ${RED}P$(echo "$task" | jq -r '.priority')${NC}  Type: $(echo "$task" | jq -r '.type')"
    local desc=$(echo "$task" | jq -r '.description')
    [[ -n "$desc" && "$desc" != "null" ]] && echo -e "\n$desc"
    local labels=$(echo "$task" | jq -r '.labels | join(", ")')
    [[ -n "$labels" ]] && echo -e "\nLabels: ${BLUE}$labels${NC}"
    local blockers=$(echo "$task" | jq -r '.blockers | join(", ")')
    [[ -n "$blockers" ]] && echo -e "Blockers: $blockers"
    echo -e "\nCreated: $(echo "$task" | jq -r '.created')"
    echo -e "Updated: $(echo "$task" | jq -r '.updated')"
  fi
}

cmd_update() {
  require_init
  local id="$1"; shift
  [[ -z "$id" ]] && die "id required"
  
  local task_file="$TASKS_DIR/${id}.json"
  [[ -f "$task_file" ]] || die "task $id not found"
  
  local updates=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--status) updates="$updates | .status = \"$2\""; shift 2 ;;
      -p|--priority) updates="$updates | .priority = $2"; shift 2 ;;
      -t|--title) updates="$updates | .title = \"$2\""; shift 2 ;;
      -d|--desc) updates="$updates | .description = \"$2\""; shift 2 ;;
      *) shift ;;
    esac
  done
  
  updates="$updates | .updated = \"$(now)\""
  jq "$updates" "$task_file" > "$task_file.tmp" && mv "$task_file.tmp" "$task_file"
  
  $JSON_OUTPUT && cat "$task_file" || echo -e "${GREEN}updated${NC} $id"
}

cmd_done() {
  require_init
  for id in "$@"; do
    local task_file="$TASKS_DIR/${id}.json"
    [[ -f "$task_file" ]] || { warn "task $id not found"; continue; }
    jq '.status = "closed" | .updated = "'"$(now)"'"' "$task_file" > "$task_file.tmp" && mv "$task_file.tmp" "$task_file"
    $JSON_OUTPUT && cat "$task_file" || echo -e "${GREEN}closed${NC} $id"
  done
}

cmd_reopen() {
  require_init
  for id in "$@"; do
    local task_file="$TASKS_DIR/${id}.json"
    [[ -f "$task_file" ]] || { warn "task $id not found"; continue; }
    jq '.status = "open" | .updated = "'"$(now)"'"' "$task_file" > "$task_file.tmp" && mv "$task_file.tmp" "$task_file"
    $JSON_OUTPUT && cat "$task_file" || echo -e "${GREEN}reopened${NC} $id"
  done
}

cmd_dep() {
  require_init
  local action="${1:-}"; shift || true
  
  case "$action" in
    add)
      local child="$1" parent="$2"
      [[ -z "$child" || -z "$parent" ]] && die "usage: td dep add <child> <parent>"
      local child_file="$TASKS_DIR/${child}.json"
      [[ -f "$child_file" ]] || die "task $child not found"
      jq --arg p "$parent" '.blockers += [$p] | .blockers |= unique | .updated = "'"$(now)"'"' "$child_file" > "$child_file.tmp" && mv "$child_file.tmp" "$child_file"
      $JSON_OUTPUT && cat "$child_file" || echo -e "${GREEN}$child${NC} now blocked by ${YELLOW}$parent${NC}"
      ;;
    rm|remove)
      local child="$1" parent="$2"
      [[ -z "$child" || -z "$parent" ]] && die "usage: td dep rm <child> <parent>"
      local child_file="$TASKS_DIR/${child}.json"
      [[ -f "$child_file" ]] || die "task $child not found"
      jq --arg p "$parent" '.blockers -= [$p] | .updated = "'"$(now)"'"' "$child_file" > "$child_file.tmp" && mv "$child_file.tmp" "$child_file"
      $JSON_OUTPUT && cat "$child_file" || echo -e "${GREEN}removed${NC} dependency $child -> $parent"
      ;;
    tree)
      local id="$1"
      [[ -z "$id" ]] && die "usage: td dep tree <id>"
      # Simple tree view
      _print_tree() {
        local tid="$1" indent="$2"
        local tfile="$TASKS_DIR/${tid}.json"
        [[ -f "$tfile" ]] || return
        local title=$(jq -r '.title' "$tfile")
        local status=$(jq -r '.status' "$tfile")
        echo "${indent}${tid}: ${title} [${status}]"
        # Find children
        for f in "$TASKS_DIR"/${tid}.*.json; do
          [[ -f "$f" ]] || continue
          local cid=$(jq -r '.id' "$f")
          _print_tree "$cid" "  $indent"
        done
      }
      _print_tree "$id" ""
      ;;
    *)
      die "usage: td dep <add|rm|tree> ..."
      ;;
  esac
}

cmd_label() {
  require_init
  local action="${1:-}"; shift || true
  
  case "$action" in
    add)
      local id="$1" label="$2"
      [[ -z "$id" || -z "$label" ]] && die "usage: td label add <id> <label>"
      local task_file="$TASKS_DIR/${id}.json"
      [[ -f "$task_file" ]] || die "task $id not found"
      jq --arg l "$label" '.labels += [$l] | .labels |= unique | .updated = "'"$(now)"'"' "$task_file" > "$task_file.tmp" && mv "$task_file.tmp" "$task_file"
      $JSON_OUTPUT && cat "$task_file" || echo -e "${GREEN}added${NC} label $label to $id"
      ;;
    rm|remove)
      local id="$1" label="$2"
      [[ -z "$id" || -z "$label" ]] && die "usage: td label rm <id> <label>"
      local task_file="$TASKS_DIR/${id}.json"
      [[ -f "$task_file" ]] || die "task $id not found"
      jq --arg l "$label" '.labels -= [$l] | .updated = "'"$(now)"'"' "$task_file" > "$task_file.tmp" && mv "$task_file.tmp" "$task_file"
      $JSON_OUTPUT && cat "$task_file" || echo -e "${GREEN}removed${NC} label $label from $id"
      ;;
    list)
      local id="$1"
      [[ -z "$id" ]] && die "usage: td label list <id>"
      local task_file="$TASKS_DIR/${id}.json"
      [[ -f "$task_file" ]] || die "task $id not found"
      jq -r '.labels[]' "$task_file"
      ;;
    list-all)
      find "$TASKS_DIR" -name "*.json" -exec cat {} \; | jq -r '.labels[]' | sort -u
      ;;
    *)
      die "usage: td label <add|rm|list|list-all> ..."
      ;;
  esac
}

cmd_search() {
  require_init
  local query="$1"
  [[ -z "$query" ]] && die "query required"
  
  local results=$(find "$TASKS_DIR" -name "*.json" -exec cat {} \; 2>/dev/null | \
    jq -s --arg q "$query" 'map(select(.title + .description | test($q; "i")))')
  
  if $JSON_OUTPUT; then
    echo "$results"
  else
    echo "$results" | jq -r '.[] | "\(.id)\t\(.title)"' | \
      while IFS=$'\t' read -r id title; do
        printf "${BOLD}%-12s${NC} %s\n" "$id" "$title"
      done
  fi
}

cmd_compact() {
  require_init
  local days=30 dry_run=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done
  
  local cutoff=$(date -u -d "$days days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-${days}d +"%Y-%m-%dT%H:%M:%SZ")
  local archived=0
  
  for task_file in "$TASKS_DIR"/*.json; do
    [[ -f "$task_file" ]] || continue
    local task=$(cat "$task_file")
    local status=$(echo "$task" | jq -r '.status')
    local updated=$(echo "$task" | jq -r '.updated')
    
    if [[ "$status" == "closed" && "$updated" < "$cutoff" ]]; then
      local id=$(echo "$task" | jq -r '.id')
      if $dry_run; then
        echo "would archive: $id"
      else
        mkdir -p "$TD_DIR/archive"
        mv "$task_file" "$TD_DIR/archive/"
        ((archived++))
      fi
    fi
  done
  
  $dry_run || info "archived $archived tasks"
  $JSON_OUTPUT && echo "{\"archived\":$archived}"
}

cmd_stats() {
  require_init
  
  local total=$(find "$TASKS_DIR" -name "*.json" | wc -l)
  local open=$(find "$TASKS_DIR" -name "*.json" -exec cat {} \; | jq -s 'map(select(.status == "open")) | length')
  local in_progress=$(find "$TASKS_DIR" -name "*.json" -exec cat {} \; | jq -s 'map(select(.status == "in_progress")) | length')
  local closed=$(find "$TASKS_DIR" -name "*.json" -exec cat {} \; | jq -s 'map(select(.status == "closed")) | length')
  
  if $JSON_OUTPUT; then
    jq -n --argjson t "$total" --argjson o "$open" --argjson i "$in_progress" --argjson c "$closed" \
      '{total:$t,open:$o,in_progress:$i,closed:$c}'
  else
    echo -e "Total: ${BOLD}$total${NC}"
    echo -e "Open: ${GREEN}$open${NC}"
    echo -e "In Progress: ${YELLOW}$in_progress${NC}"
    echo -e "Closed: ${BLUE}$closed${NC}"
  fi
}

cmd_help() {
  cat << 'EOF'
td - Todo tracker for AI agents

USAGE:
  td [--json] <command> [args]

COMMANDS:
  init [--stealth]              Initialize .td directory
  create <title> [options]      Create new task
    -p, --priority <0-4>        Priority (default: 2)
    -t, --type <type>           Type: task|bug|feature|epic
    -d, --desc <text>           Description
    -l, --labels <a,b,c>        Labels (comma-separated)
    --parent <id>               Parent task (creates hierarchical ID)
  
  list [filters]                List tasks
    -s, --status <status>       Filter by status
    -p, --priority <n>          Filter by priority
    -l, --label <label>         Filter by label
  
  ready                         List tasks with no open blockers
  show <id>                     Show task details
  update <id> [options]         Update task
    -s, --status <status>       Set status: open|in_progress|blocked|closed
    -p, --priority <n>          Set priority
    -t, --title <text>          Set title
    -d, --desc <text>           Set description
  
  done <id> [id...]             Mark task(s) as closed
  reopen <id> [id...]           Reopen task(s)
  
  dep add <child> <parent>      Add dependency (child blocked by parent)
  dep rm <child> <parent>       Remove dependency
  dep tree <id>                 Show dependency tree
  
  label add <id> <label>        Add label to task
  label rm <id> <label>         Remove label from task
  label list <id>               List labels on task
  label list-all                List all labels in use
  
  search <query>                Search tasks by title/description
  compact [--days N] [--dry-run]  Archive old closed tasks
  stats                         Show statistics

FLAGS:
  --json, -j                    Output JSON (for agents)

STATUSES:
  open, in_progress, blocked, deferred, closed

PRIORITIES:
  0 = critical, 1 = high, 2 = medium, 3 = low, 4 = backlog
EOF
}

# Main dispatch
case "${1:-help}" in
  init) shift; cmd_init "$@" ;;
  create|add|new) shift; cmd_create "$@" ;;
  list|ls) shift; cmd_list "$@" ;;
  ready) shift; cmd_ready "$@" ;;
  show|get) shift; cmd_show "$@" ;;
  update|set) shift; cmd_update "$@" ;;
  done|close|complete) shift; cmd_done "$@" ;;
  reopen) shift; cmd_reopen "$@" ;;
  dep|deps) shift; cmd_dep "$@" ;;
  label|labels) shift; cmd_label "$@" ;;
  search|find) shift; cmd_search "$@" ;;
  compact|gc) shift; cmd_compact "$@" ;;
  stats) shift; cmd_stats "$@" ;;
  help|--help|-h) cmd_help ;;
  version|--version|-v) echo "td $VERSION" ;;
  *) die "unknown command: $1. Run 'td help'" ;;
esac
