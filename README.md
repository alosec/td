# td - Todo for Agents

Minimal todo tracker for AI coding agents. Inspired by [beads](https://github.com/steveyegge/beads) but aiming for:
- **<1k LOC** (all implementations)
- **<100ms response time** (for agent use)
- **Zero or minimal deps** (bash + common tools)

## Implementations

Five different storage backends, same CLI interface:

| Implementation | LOC | `ready` (50 tasks) | Storage | Dependencies |
|---------------|-----|-------------------|---------|--------------|
| **sqlite** | 408 | **13ms** ✅ | 48K | bash, sqlite3 |
| **json-files** | 494 | 125ms | 212K | bash, jq |
| **jsonl** | 372 | 230ms | 20K | bash, jq |
| **flat-file** | 560 | 735ms | 8K | bash only |
| **markdown** | 528 | 1032ms | 208K | bash, jq |

**Winner: sqlite** — Fastest by 10x, reasonable storage, proper queries.

## Quick Start

```bash
# Install (picks sqlite implementation)
curl -fsSL https://raw.githubusercontent.com/alosec/td/main/install.sh | bash

# Or clone and symlink
git clone https://github.com/alosec/td
ln -s $(pwd)/td/td /usr/local/bin/td

# Initialize
td init

# Tell your agent
echo "Use 'td' for task tracking. Run 'td help' for commands." >> AGENTS.md
```

## Commands

```bash
td init [--stealth]              # Initialize .td directory
td create <title> [options]       # Create task
  -p, --priority <0-4>            # Priority (0=critical, 4=backlog)
  -t, --type <type>               # task|bug|feature|epic
  -d, --desc <text>               # Description
  -l, --labels <a,b,c>            # Comma-separated labels
  --parent <id>                   # Parent task (creates hierarchical ID)

td list [filters]                 # List all tasks
  -s, --status <status>           # open|in_progress|blocked|closed
  -p, --priority <n>              # Filter by priority
  -l, --label <label>             # Filter by label

td ready                          # Tasks with no open blockers (sorted by priority)
td show <id>                      # Show task details
td update <id> [options]          # Update task fields
td done <id> [id...]              # Mark task(s) closed
td reopen <id> [id...]            # Reopen closed task(s)

td dep add <child> <parent>       # child is blocked by parent
td dep rm <child> <parent>        # Remove dependency
td dep tree <id>                  # Show task hierarchy

td label add <id> <label>         # Add label
td label rm <id> <label>          # Remove label
td label list <id>                # List task's labels
td label list-all                 # All labels in use

td search <query>                 # Search by title/description
td compact                        # Archive old closed tasks / vacuum
td stats                          # Show statistics
```

## JSON Output

All commands support `--json` or `-j` for machine-readable output:

```bash
td --json ready
td -j create "Fix bug" -p 0
td --json show td-a1b2
```

## Hierarchical Tasks

Create subtasks with `--parent`:

```bash
td create "Auth System" -t epic -p 1     # Returns: td-a3f8
td create "Login UI" --parent td-a3f8    # Auto-assigned: td-a3f8.1
td create "Backend" --parent td-a3f8     # Auto-assigned: td-a3f8.2
td dep tree td-a3f8                       # Show hierarchy
```

## Stealth Mode

Don't commit .td to shared repos:

```bash
td init --stealth    # Adds .td/ to .gitignore
```

## Implementation Details

### sqlite (recommended)
- Single `.td/tasks.db` file
- Real SQL queries = fast filtering
- Includes `export`/`import` commands for JSONL (git-friendly diffs)
- Binary file = potential merge conflicts (use export/import)

### json-files
- One JSON file per task in `.td/tasks/`
- Git-friendly (per-task history)
- Zero merge conflicts
- Requires `jq`

### jsonl
- Append-only log in `.td/tasks.jsonl`
- Event sourcing pattern
- `compact` command to dedupe
- Requires `jq`

### markdown
- Each task is a `.md` file with YAML frontmatter
- Human-readable AND machine-parseable
- Edit tasks with any text editor
- Slower due to parsing overhead

### flat-file
- Single TSV file, **zero external dependencies**
- Pure bash + coreutils
- Slowest for JSON output
- Most portable

## Agent Instructions

Add to your `AGENTS.md`:

```markdown
## Task Tracking

Use `td` for persistent task tracking across sessions.

**Find work:**
- `td ready` — Tasks with no blockers, sorted by priority

**Track progress:**
- `td update <id> --status in_progress` — Claim task
- `td done <id>` — Complete task

**Discover work:**
- `td create "Found bug" -t bug -p 1` — File new task
- `td dep add <new> <current>` — Link if discovered during other work

**Always use `--json` for parsing output.**
```

## License

MIT
