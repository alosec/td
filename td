#!/usr/bin/env bash
# td - Todo tracker for AI agents
# Implementation: SQLite (single db file)
# Target: <1k LOC, <100ms response time
set -euo pipefail

VERSION="0.1.0"
TD_DIR=".td"
DB_FILE="$TD_DIR/tasks.db"

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
  DB_FILE="$TD_DIR/tasks.db"
}

# sql_json: returns JSON array directly (use for queries returning JSON)
sql_json() { sqlite3 "$DB_FILE" "$1"; }
sql_exec() { sqlite3 "$DB_FILE" <<< "$1"; }

JSON_OUTPUT=false
[[ "${1:-}" == "--json" ]] && { JSON_OUTPUT=true; shift; }
[[ "${1:-}" == "-j" ]] && { JSON_OUTPUT=true; shift; }

cmd_init() {
  local stealth=false
  [[ "${1:-}" == "--stealth" ]] && stealth=true
  
  [[ -d "$TD_DIR" ]] && die "already initialized"
  mkdir -p "$TD_DIR"
  
  sqlite3 "$DB_FILE" << 'SQL'
CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT DEFAULT '',
  type TEXT DEFAULT 'task',
  priority INTEGER DEFAULT 2,
  status TEXT DEFAULT 'open',
  parent TEXT DEFAULT '',
  created TEXT NOT NULL,
  updated TEXT NOT NULL
);

CREATE TABLE labels (
  task_id TEXT,
  label TEXT,
  PRIMARY KEY (task_id, label),
  FOREIGN KEY (task_id) REFERENCES tasks(id)
);

CREATE TABLE blockers (
  task_id TEXT,
  blocker_id TEXT,
  PRIMARY KEY (task_id, blocker_id),
  FOREIGN KEY (task_id) REFERENCES tasks(id)
);

CREATE INDEX idx_status ON tasks(status);
CREATE INDEX idx_priority ON tasks(priority);
CREATE INDEX idx_parent ON tasks(parent);
SQL
  
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
    local child_count=$(sql_exec "SELECT COUNT(*) FROM tasks WHERE parent='$parent';")
    id="${parent}.$((child_count + 1))"
  else
    id=$(gen_id)
  fi
  
  local ts=$(now)
  sql_exec "INSERT INTO tasks (id, title, description, type, priority, status, parent, created, updated) VALUES ('$id', '${title//\'/\'\'}', '${desc//\'/\'\'}', '$type', $priority, 'open', '$parent', '$ts', '$ts');"
  
  if [[ -n "$labels" ]]; then
    IFS=',' read -ra LBLS <<< "$labels"
    for lbl in "${LBLS[@]}"; do
      sql_exec "INSERT OR IGNORE INTO labels (task_id, label) VALUES ('$id', '$lbl');"
    done
  fi
  
  if $JSON_OUTPUT; then
    sql_json "SELECT json_object('id', id, 'title', title, 'description', description, 'type', type, 'priority', priority, 'status', status, 'parent', parent, 'created', created, 'updated', updated) FROM tasks WHERE id='$id';"
  else
    echo -e "${GREEN}created${NC} $id: $title"
  fi
}

cmd_list() {
  require_init
  local where="1=1"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--status) where="$where AND status='$2'"; shift 2 ;;
      -p|--priority) where="$where AND priority=$2"; shift 2 ;;
      -l|--label) where="$where AND id IN (SELECT task_id FROM labels WHERE label='$2')"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  if $JSON_OUTPUT; then
    sql_json "SELECT json_group_array(json_object('id', id, 'title', title, 'description', description, 'type', type, 'priority', priority, 'status', status, 'parent', parent, 'labels', COALESCE((SELECT json_group_array(label) FROM labels WHERE task_id=id), '[]'), 'blockers', COALESCE((SELECT json_group_array(blocker_id) FROM blockers WHERE task_id=id), '[]'), 'created', created, 'updated', updated)) FROM tasks WHERE $where ORDER BY priority, created;"
  else
    sql_exec ".mode tabs
.headers off
SELECT id, '[' || status || ']', 'P' || priority, title FROM tasks WHERE $where ORDER BY priority, created;" | \
      while IFS=$'\t' read -r id status pri title; do
        printf "${BOLD}%-12s${NC} ${YELLOW}%-12s${NC} ${RED}%-4s${NC} %s\n" "$id" "$status" "$pri" "$title"
      done
  fi
}

cmd_ready() {
  require_init
  
  # Tasks that are open and have no open blockers
  local query="
    SELECT id, title, priority FROM tasks 
    WHERE status = 'open' 
    AND id NOT IN (
      SELECT b.task_id FROM blockers b 
      JOIN tasks t ON b.blocker_id = t.id 
      WHERE t.status != 'closed'
    )
    ORDER BY priority, created
  "
  
  if $JSON_OUTPUT; then
    sql_json "SELECT json_group_array(json_object('id', id, 'title', title, 'priority', priority)) FROM ($query);"
  else
    sql_exec ".mode tabs
.headers off
$query" | while IFS=$'\t' read -r id title pri; do
      printf "${GREEN}%-12s${NC} ${RED}P%-3s${NC} %s\n" "$id" "$pri" "$title"
    done
  fi
}

cmd_show() {
  require_init
  local id="$1"
  [[ -z "$id" ]] && die "id required"
  
  local exists=$(sql_exec "SELECT COUNT(*) FROM tasks WHERE id='$id';")
  [[ "$exists" -eq 0 ]] && die "task $id not found"
  
  if $JSON_OUTPUT; then
    sql_json "SELECT json_object('id', id, 'title', title, 'description', description, 'type', type, 'priority', priority, 'status', status, 'parent', parent, 'labels', COALESCE((SELECT json_group_array(label) FROM labels WHERE task_id=id), '[]'), 'blockers', COALESCE((SELECT json_group_array(blocker_id) FROM blockers WHERE task_id=id), '[]'), 'created', created, 'updated', updated) FROM tasks WHERE id='$id';"
  else
    sql_exec ".mode line
SELECT id, title, status, priority, type, description, created, updated FROM tasks WHERE id='$id';"
    local labels=$(sql_exec "SELECT GROUP_CONCAT(label) FROM labels WHERE task_id='$id';")
    [[ -n "$labels" ]] && echo "labels = $labels"
    local blockers=$(sql_exec "SELECT GROUP_CONCAT(blocker_id) FROM blockers WHERE task_id='$id';")
    [[ -n "$blockers" ]] && echo "blockers = $blockers"
  fi
}

cmd_update() {
  require_init
  local id="$1"; shift
  [[ -z "$id" ]] && die "id required"
  
  local sets="updated='$(now)'"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--status) sets="$sets, status='$2'"; shift 2 ;;
      -p|--priority) sets="$sets, priority=$2"; shift 2 ;;
      -t|--title) sets="$sets, title='${2//\'/\'\'}'"; shift 2 ;;
      -d|--desc) sets="$sets, description='${2//\'/\'\'}'"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  sql_exec "UPDATE tasks SET $sets WHERE id='$id';"
  $JSON_OUTPUT && cmd_show "$id" || echo -e "${GREEN}updated${NC} $id"
}

cmd_done() {
  require_init
  local ts=$(now)
  for id in "$@"; do
    sql_exec "UPDATE tasks SET status='closed', updated='$ts' WHERE id='$id';"
    $JSON_OUTPUT || echo -e "${GREEN}closed${NC} $id"
  done
  $JSON_OUTPUT && sql_json "SELECT json_group_array(json_object('id', id, 'status', status)) FROM tasks WHERE id IN ($(printf "'%s'," "$@" | sed 's/,$//'));"
}

cmd_reopen() {
  require_init
  local ts=$(now)
  for id in "$@"; do
    sql_exec "UPDATE tasks SET status='open', updated='$ts' WHERE id='$id';"
    $JSON_OUTPUT || echo -e "${GREEN}reopened${NC} $id"
  done
}

cmd_dep() {
  require_init
  local action="${1:-}"; shift || true
  
  case "$action" in
    add)
      local child="$1" parent="$2"
      [[ -z "$child" || -z "$parent" ]] && die "usage: td dep add <child> <parent>"
      sql_exec "INSERT OR IGNORE INTO blockers (task_id, blocker_id) VALUES ('$child', '$parent');"
      sql_exec "UPDATE tasks SET updated='$(now)' WHERE id='$child';"
      $JSON_OUTPUT || echo -e "${GREEN}$child${NC} blocked by ${YELLOW}$parent${NC}"
      ;;
    rm)
      local child="$1" parent="$2"
      sql_exec "DELETE FROM blockers WHERE task_id='$child' AND blocker_id='$parent';"
      sql_exec "UPDATE tasks SET updated='$(now)' WHERE id='$child';"
      ;;
    tree)
      local id="$1"
      echo "$id"
      sql_exec "SELECT '  ' || id FROM tasks WHERE parent='$id' ORDER BY id;"
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
      sql_exec "INSERT OR IGNORE INTO labels (task_id, label) VALUES ('$id', '$label');"
      sql_exec "UPDATE tasks SET updated='$(now)' WHERE id='$id';"
      $JSON_OUTPUT || echo -e "${GREEN}added${NC} label $label"
      ;;
    rm)
      local id="$1" label="$2"
      sql_exec "DELETE FROM labels WHERE task_id='$id' AND label='$label';"
      ;;
    list)
      sql_exec "SELECT label FROM labels WHERE task_id='$1';"
      ;;
    list-all)
      sql_exec "SELECT DISTINCT label FROM labels ORDER BY label;"
      ;;
    *) die "usage: td label <add|rm|list|list-all>" ;;
  esac
}

cmd_search() {
  require_init
  local query="$1"
  if $JSON_OUTPUT; then
    sql_json "SELECT json_group_array(json_object('id', id, 'title', title, 'status', status)) FROM tasks WHERE title LIKE '%$query%' OR description LIKE '%$query%';"
  else
    sql_exec "SELECT id, title FROM tasks WHERE title LIKE '%$query%' OR description LIKE '%$query%';"
  fi
}

cmd_compact() {
  require_init
  info "vacuuming database..."
  sql_exec "VACUUM;"
  info "done"
}

cmd_stats() {
  require_init
  sql_json "SELECT json_object('total', (SELECT COUNT(*) FROM tasks), 'open', (SELECT COUNT(*) FROM tasks WHERE status='open'), 'in_progress', (SELECT COUNT(*) FROM tasks WHERE status='in_progress'), 'closed', (SELECT COUNT(*) FROM tasks WHERE status='closed'));"
}

cmd_export() {
  require_init
  # Export to JSONL for git-friendly diffs
  sql_json "SELECT json_object('id', id, 'title', title, 'description', description, 'type', type, 'priority', priority, 'status', status, 'parent', parent, 'labels', COALESCE((SELECT json_group_array(label) FROM labels WHERE task_id=tasks.id), '[]'), 'blockers', COALESCE((SELECT json_group_array(blocker_id) FROM blockers WHERE task_id=tasks.id), '[]'), 'created', created, 'updated', updated) FROM tasks ORDER BY id;" | jq -c '.[]' 2>/dev/null || cat
}

cmd_import() {
  require_init
  local file="${1:--}"
  info "importing from $file..."
  
  cat "$file" | while read -r line; do
    local id=$(echo "$line" | jq -r '.id')
    local title=$(echo "$line" | jq -r '.title' | sed "s/'/''/g")
    local desc=$(echo "$line" | jq -r '.description' | sed "s/'/''/g")
    local type=$(echo "$line" | jq -r '.type')
    local priority=$(echo "$line" | jq -r '.priority')
    local status=$(echo "$line" | jq -r '.status')
    local parent=$(echo "$line" | jq -r '.parent')
    local created=$(echo "$line" | jq -r '.created')
    local updated=$(echo "$line" | jq -r '.updated')
    
    sql_exec "INSERT OR REPLACE INTO tasks VALUES ('$id', '$title', '$desc', '$type', $priority, '$status', '$parent', '$created', '$updated');"
    
    # Labels
    sql_exec "DELETE FROM labels WHERE task_id='$id';"
    echo "$line" | jq -r '.labels[]' 2>/dev/null | while read -r lbl; do
      sql_exec "INSERT INTO labels VALUES ('$id', '$lbl');"
    done
    
    # Blockers
    sql_exec "DELETE FROM blockers WHERE task_id='$id';"
    echo "$line" | jq -r '.blockers[]' 2>/dev/null | while read -r blk; do
      sql_exec "INSERT INTO blockers VALUES ('$id', '$blk');"
    done
  done
  
  info "import complete"
}

cmd_help() {
  cat << 'EOF'
td - Todo tracker for AI agents (SQLite implementation)

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
  compact                 Vacuum database
  export                  Export to JSONL (git-friendly)
  import <file>           Import from JSONL
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
  export) shift; cmd_export "$@" ;;
  import) shift; cmd_import "$@" ;;
  stats) shift; cmd_stats "$@" ;;
  help|--help|-h) cmd_help ;;
  version|--version) echo "td $VERSION (sqlite)" ;;
  *) die "unknown command: $1" ;;
esac
