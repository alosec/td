#!/usr/bin/env bash
# td - Todo tracker for AI agents
# Implementation: Markdown files (one .md per task, YAML frontmatter)
# Target: <1k LOC, <100ms response time
set -euo pipefail

VERSION="0.1.0"
TD_DIR=".td"
TASKS_DIR="$TD_DIR/tasks"

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
  TASKS_DIR="$TD_DIR/tasks"
}

# Parse YAML frontmatter field
get_field() {
  local file="$1" field="$2"
  sed -n '/^---$/,/^---$/p' "$file" | grep "^$field:" | sed "s/^$field: *//" | tr -d '"'
}

# Parse array field from frontmatter
get_array() {
  local file="$1" field="$2"
  sed -n '/^---$/,/^---$/p' "$file" | sed -n "/^$field:/,/^[a-z]/p" | grep "^  - " | sed 's/^  - //'
}

# Get body after frontmatter
get_body() {
  local file="$1"
  sed '1,/^---$/d' "$file" | sed '1,/^---$/d'
}

# Convert task file to JSON
task_to_json() {
  local file="$1"
  local id=$(get_field "$file" "id")
  local title=$(get_field "$file" "title")
  local status=$(get_field "$file" "status")
  local priority=$(get_field "$file" "priority")
  local type=$(get_field "$file" "type")
  local parent=$(get_field "$file" "parent")
  local created=$(get_field "$file" "created")
  local updated=$(get_field "$file" "updated")
  local desc=$(get_body "$file" | tr '\n' ' ' | sed 's/  */ /g')
  
  local labels=$(get_array "$file" "labels" | jq -R . | jq -s . 2>/dev/null || echo "[]")
  local blockers=$(get_array "$file" "blockers" | jq -R . | jq -s . 2>/dev/null || echo "[]")
  
  jq -n \
    --arg id "$id" \
    --arg title "$title" \
    --arg desc "$desc" \
    --arg type "${type:-task}" \
    --argjson priority "${priority:-2}" \
    --arg status "${status:-open}" \
    --arg parent "${parent:-}" \
    --argjson labels "$labels" \
    --argjson blockers "$blockers" \
    --arg created "$created" \
    --arg updated "$updated" \
    '{id:$id,title:$title,description:$desc,type:$type,priority:$priority,status:$status,parent:$parent,labels:$labels,blockers:$blockers,created:$created,updated:$updated}'
}

# Write task to markdown file
write_task() {
  local file="$1" id="$2" title="$3" desc="$4" type="$5" priority="$6" status="$7" parent="$8" created="$9" updated="${10}"
  shift 10
  local labels=("$@")
  
  {
    echo "---"
    echo "id: $id"
    echo "title: \"$title\""
    echo "type: $type"
    echo "priority: $priority"
    echo "status: $status"
    [[ -n "$parent" ]] && echo "parent: $parent"
    echo "created: $created"
    echo "updated: $updated"
    if [[ ${#labels[@]} -gt 0 ]]; then
      echo "labels:"
      for l in "${labels[@]}"; do
        echo "  - $l"
      done
    fi
    echo "blockers:"
    echo "---"
    echo ""
    echo "$desc"
  } > "$file"
}

JSON_OUTPUT=false
[[ "${1:-}" == "--json" ]] && { JSON_OUTPUT=true; shift; }
[[ "${1:-}" == "-j" ]] && { JSON_OUTPUT=true; shift; }

cmd_init() {
  local stealth=false
  [[ "${1:-}" == "--stealth" ]] && stealth=true
  
  [[ -d "$TD_DIR" ]] && die "already initialized"
  mkdir -p "$TASKS_DIR"
  
  $stealth && echo ".td/" >> .gitignore
  info "initialized .td/"
  $JSON_OUTPUT && echo '{"success":true}'
}

cmd_create() {
  require_init
  local title="" priority=2 type="task" desc="" parent=""
  local -a labels=()
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--priority) priority="$2"; shift 2 ;;
      -t|--type) type="$2"; shift 2 ;;
      -d|--desc) desc="$2"; shift 2 ;;
      --parent) parent="$2"; shift 2 ;;
      -l|--labels) IFS=',' read -ra labels <<< "$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) title="$1"; shift ;;
    esac
  done
  
  [[ -z "$title" ]] && die "title required"
  
  local id
  if [[ -n "$parent" ]]; then
    local child_count=$(find "$TASKS_DIR" -name "${parent}.*.md" 2>/dev/null | wc -l)
    id="${parent}.$((child_count + 1))"
  else
    id=$(gen_id)
  fi
  
  local ts=$(now)
  local task_file="$TASKS_DIR/${id}.md"
  
  write_task "$task_file" "$id" "$title" "$desc" "$type" "$priority" "open" "$parent" "$ts" "$ts" "${labels[@]}"
  
  if $JSON_OUTPUT; then
    task_to_json "$task_file"
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
  
  local results="[]"
  for f in "$TASKS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    local t=$(task_to_json "$f")
    
    # Filter
    [[ -n "$status" && "$(echo "$t" | jq -r '.status')" != "$status" ]] && continue
    [[ -n "$priority" && "$(echo "$t" | jq -r '.priority')" != "$priority" ]] && continue
    
    results=$(echo "$results" | jq --argjson t "$t" '. + [$t]')
  done
  
  results=$(echo "$results" | jq 'sort_by(.priority)')
  
  if $JSON_OUTPUT; then
    echo "$results"
  else
    echo "$results" | jq -r '.[] | "\(.id)\t[\(.status)]\tP\(.priority)\t\(.title)"' | \
      while IFS=$'\t' read -r id st pri title; do
        printf "${BOLD}%-12s${NC} ${YELLOW}%-12s${NC} ${RED}%-4s${NC} %s\n" "$id" "$st" "$pri" "$title"
      done
  fi
}

cmd_ready() {
  require_init
  
  # Build list of open tasks quickly (no jq in loop)
  local -a ready_tasks=()
  for f in "$TASKS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    local status=$(get_field "$f" "status")
    [[ "$status" != "open" ]] && continue
    
    # Check blockers directly from file
    local blocked=false
    for blocker in $(get_array "$f" "blockers"); do
      local bf="$TASKS_DIR/${blocker}.md"
      if [[ -f "$bf" ]]; then
        local bs=$(get_field "$bf" "status")
        [[ "$bs" != "closed" ]] && blocked=true && break
      fi
    done
    
    $blocked || ready_tasks+=("$f")
  done
  
  if $JSON_OUTPUT; then
    local results="["
    local first=true
    for f in "${ready_tasks[@]}"; do
      $first || results+=","
      first=false
      results+=$(task_to_json "$f")
    done
    echo "${results}]" | jq 'sort_by(.priority)'
  else
    # Quick output without full JSON conversion
    for f in "${ready_tasks[@]}"; do
      local id=$(get_field "$f" "id")
      local title=$(get_field "$f" "title")
      local pri=$(get_field "$f" "priority")
      printf "${GREEN}%-12s${NC} ${RED}P%-3s${NC} %s\n" "$id" "$pri" "$title"
    done | sort -t'P' -k2 -n
  fi
}

cmd_show() {
  require_init
  local id="$1"
  [[ -z "$id" ]] && die "id required"
  
  local f="$TASKS_DIR/${id}.md"
  [[ -f "$f" ]] || die "task $id not found"
  
  if $JSON_OUTPUT; then
    task_to_json "$f"
  else
    cat "$f"
  fi
}

cmd_update() {
  require_init
  local id="$1"; shift
  [[ -z "$id" ]] && die "id required"
  
  local f="$TASKS_DIR/${id}.md"
  [[ -f "$f" ]] || die "task $id not found"
  
  # Read existing
  local title=$(get_field "$f" "title")
  local type=$(get_field "$f" "type")
  local priority=$(get_field "$f" "priority")
  local status=$(get_field "$f" "status")
  local parent=$(get_field "$f" "parent")
  local created=$(get_field "$f" "created")
  local desc=$(get_body "$f")
  local -a labels=($(get_array "$f" "labels"))
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--status) status="$2"; shift 2 ;;
      -p|--priority) priority="$2"; shift 2 ;;
      -t|--title) title="$2"; shift 2 ;;
      -d|--desc) desc="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  write_task "$f" "$id" "$title" "$desc" "$type" "$priority" "$status" "$parent" "$created" "$(now)" "${labels[@]}"
  
  $JSON_OUTPUT && task_to_json "$f" || echo -e "${GREEN}updated${NC} $id"
}

cmd_done() {
  require_init
  for id in "$@"; do
    local f="$TASKS_DIR/${id}.md"
    [[ -f "$f" ]] || continue
    
    local title=$(get_field "$f" "title")
    local type=$(get_field "$f" "type")
    local priority=$(get_field "$f" "priority")
    local parent=$(get_field "$f" "parent")
    local created=$(get_field "$f" "created")
    local desc=$(get_body "$f")
    local -a labels=($(get_array "$f" "labels"))
    
    write_task "$f" "$id" "$title" "$desc" "$type" "$priority" "closed" "$parent" "$created" "$(now)" "${labels[@]}"
    $JSON_OUTPUT || echo -e "${GREEN}closed${NC} $id"
  done
}

cmd_reopen() {
  require_init
  for id in "$@"; do
    local f="$TASKS_DIR/${id}.md"
    [[ -f "$f" ]] || continue
    
    local title=$(get_field "$f" "title")
    local type=$(get_field "$f" "type")
    local priority=$(get_field "$f" "priority")
    local parent=$(get_field "$f" "parent")
    local created=$(get_field "$f" "created")
    local desc=$(get_body "$f")
    local -a labels=($(get_array "$f" "labels"))
    
    write_task "$f" "$id" "$title" "$desc" "$type" "$priority" "open" "$parent" "$created" "$(now)" "${labels[@]}"
    $JSON_OUTPUT || echo -e "${GREEN}reopened${NC} $id"
  done
}

cmd_dep() {
  require_init
  local action="${1:-}"; shift || true
  
  case "$action" in
    add)
      local child="$1" parent="$2"
      local f="$TASKS_DIR/${child}.md"
      [[ -f "$f" ]] || die "task $child not found"
      
      # Read and add blocker
      local content=$(cat "$f")
      if grep -q "^blockers:" "$f"; then
        # Add to existing blockers
        sed -i "/^blockers:/a\  - $parent" "$f"
      fi
      sed -i "s/^updated:.*/updated: $(now)/" "$f"
      $JSON_OUTPUT || echo -e "${GREEN}$child${NC} blocked by ${YELLOW}$parent${NC}"
      ;;
    rm)
      local child="$1" parent="$2"
      local f="$TASKS_DIR/${child}.md"
      sed -i "/^  - $parent$/d" "$f"
      sed -i "s/^updated:.*/updated: $(now)/" "$f"
      ;;
    tree)
      local id="$1"
      echo "$id"
      for f in "$TASKS_DIR"/${id}.*.md; do
        [[ -f "$f" ]] || continue
        local cid=$(get_field "$f" "id")
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
      local f="$TASKS_DIR/${id}.md"
      [[ -f "$f" ]] || die "task $id not found"
      sed -i "/^labels:/a\  - $label" "$f"
      sed -i "s/^updated:.*/updated: $(now)/" "$f"
      $JSON_OUTPUT || echo -e "${GREEN}added${NC} label $label"
      ;;
    rm)
      local id="$1" label="$2"
      local f="$TASKS_DIR/${id}.md"
      sed -i "/^  - $label$/d" "$f"
      ;;
    list)
      get_array "$TASKS_DIR/${1}.md" "labels"
      ;;
    list-all)
      for f in "$TASKS_DIR"/*.md; do
        [[ -f "$f" ]] && get_array "$f" "labels"
      done | sort -u
      ;;
    *) die "usage: td label <add|rm|list|list-all>" ;;
  esac
}

cmd_search() {
  require_init
  local query="$1"
  local results="[]"
  
  for f in "$TASKS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    if grep -qi "$query" "$f" 2>/dev/null; then
      local t=$(task_to_json "$f")
      results=$(echo "$results" | jq --argjson t "$t" '. + [$t]')
    fi
  done
  
  echo "$results"
}

cmd_compact() {
  require_init
  local days=30
  [[ "${1:-}" == "--days" ]] && days="$2"
  
  local cutoff=$(date -u -d "$days days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-${days}d +"%Y-%m-%dT%H:%M:%SZ")
  local archived=0
  
  mkdir -p "$TD_DIR/archive"
  for f in "$TASKS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    local status=$(get_field "$f" "status")
    local updated=$(get_field "$f" "updated")
    
    if [[ "$status" == "closed" && "$updated" < "$cutoff" ]]; then
      mv "$f" "$TD_DIR/archive/"
      ((archived++))
    fi
  done
  
  info "archived $archived tasks"
}

cmd_stats() {
  require_init
  local total=0 open=0 in_progress=0 closed=0
  
  for f in "$TASKS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    ((total++))
    local status=$(get_field "$f" "status")
    case "$status" in
      open) ((open++)) ;;
      in_progress) ((in_progress++)) ;;
      closed) ((closed++)) ;;
    esac
  done
  
  if $JSON_OUTPUT; then
    jq -n --argjson t "$total" --argjson o "$open" --argjson i "$in_progress" --argjson c "$closed" \
      '{total:$t,open:$o,in_progress:$i,closed:$c}'
  else
    echo "Total: $total | Open: $open | In Progress: $in_progress | Closed: $closed"
  fi
}

cmd_edit() {
  require_init
  local id="$1"
  local f="$TASKS_DIR/${id}.md"
  [[ -f "$f" ]] || die "task $id not found"
  ${EDITOR:-vim} "$f"
}

cmd_help() {
  cat << 'EOF'
td - Todo tracker for AI agents (Markdown implementation)

USAGE:
  td [--json] <command> [args]

COMMANDS:
  init [--stealth]        Initialize .td directory
  create <title> [opts]   Create task (-p priority, -t type, -d desc, --parent id)
  list [-s status] [-p n] List tasks
  ready                   Tasks with no open blockers
  show <id>               Show task (prints markdown file)
  edit <id>               Edit task in $EDITOR
  update <id> [opts]      Update task (-s status, -p priority)
  done <id>...            Mark task(s) closed
  reopen <id>...          Reopen task(s)
  dep add <c> <p>         Add dependency
  dep rm <c> <p>          Remove dependency
  dep tree <id>           Show children
  label add <id> <l>      Add label
  label rm <id> <l>       Remove label
  search <query>          Search tasks
  compact [--days N]      Archive old closed tasks
  stats                   Show statistics

FLAGS:
  --json, -j              Output JSON

Each task is stored as a markdown file with YAML frontmatter.
Human-readable AND machine-parseable.
EOF
}

case "${1:-help}" in
  init) shift; cmd_init "$@" ;;
  create|add) shift; cmd_create "$@" ;;
  list|ls) shift; cmd_list "$@" ;;
  ready) shift; cmd_ready "$@" ;;
  show) shift; cmd_show "$@" ;;
  edit) shift; cmd_edit "$@" ;;
  update) shift; cmd_update "$@" ;;
  done|close) shift; cmd_done "$@" ;;
  reopen) shift; cmd_reopen "$@" ;;
  dep) shift; cmd_dep "$@" ;;
  label) shift; cmd_label "$@" ;;
  search) shift; cmd_search "$@" ;;
  compact) shift; cmd_compact "$@" ;;
  stats) shift; cmd_stats "$@" ;;
  help|--help|-h) cmd_help ;;
  version|--version) echo "td $VERSION (markdown)" ;;
  *) die "unknown command: $1" ;;
esac
