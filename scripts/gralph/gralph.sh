#!/usr/bin/env bash

# ============================================
# GRALPH - Autonomous AI Coding Loop
# Supports Claude Code, OpenCode, Codex, and Cursor
# Runs until PRD is complete
# ============================================

set -euo pipefail

# ============================================
# CONFIGURATION & DEFAULTS
# ============================================

VERSION="3.2.0"

# Runtime options
SKIP_TESTS=false
SKIP_LINT=false
AI_ENGINE="claude"  # claude, opencode, cursor, or codex
OPENCODE_MODEL="opencode/minimax-m2.1-free"  # Default model for OpenCode (can be overridden with --opencode-model)
DRY_RUN=false
MAX_ITERATIONS=0  # 0 = unlimited
MAX_RETRIES=3
RETRY_DELAY=5
VERBOSE=false
EXTERNAL_FAIL_TIMEOUT=300

# Git branch options
BRANCH_PER_TASK=false
CREATE_PR=false
BASE_BRANCH=""
PR_DRAFT=false
RUN_BRANCH=""

# Parallel execution (default: parallel)
PARALLEL=true
SEQUENTIAL=false
MAX_PARALLEL=3

# PRD options
PRD_FILE="PRD.md"
PRD_ID=""
PRD_RUN_DIR=""
RESUME_PRD_ID=""


# Colors (detect if terminal supports colors)
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  MAGENTA=$(tput setaf 5)
  CYAN=$(tput setaf 6)
  BOLD=$(tput bold)
  DIM=$(tput dim)
  RESET=$(tput sgr0)
else
  RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" BOLD="" DIM="" RESET=""
fi

# Global state
ai_pid=""
monitor_pid=""
tmpfile=""
CODEX_LAST_MESSAGE_FILE=""
current_step="Thinking"
total_input_tokens=0
total_output_tokens=0
total_actual_cost="0"  # OpenCode provides actual cost
total_duration_ms=0    # Cursor provides duration
iteration=0
retry_count=0
declare -a parallel_pids=()
declare -a task_branches=()
WORKTREE_BASE=""  # Base directory for parallel agent worktrees
ORIGINAL_DIR=""   # Original working directory (for worktree operations)
EXTERNAL_FAIL_DETECTED=false
EXTERNAL_FAIL_REASON=""
EXTERNAL_FAIL_TASK_ID=""
declare -a ACTIVE_PIDS=()
declare -a ACTIVE_TASK_IDS=()
declare -a ACTIVE_STATUS_FILES=()
declare -a ACTIVE_LOG_FILES=()

# ============================================
# UTILITY FUNCTIONS
# ============================================

log_info() {
  echo "${BLUE}[INFO]${RESET} $*"
}

log_success() {
  echo "${GREEN}[OK]${RESET} $*"
}

log_warn() {
  echo "${YELLOW}[WARN]${RESET} $*"
}

log_error() {
  echo "${RED}[ERROR]${RESET} $*" >&2
}

log_debug() {
  if [[ "$VERBOSE" == true ]]; then
    echo "${DIM}[DEBUG] $*${RESET}"
  fi
}

stage_banner() {
  local name=$1
  echo ""
  echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo "${BOLD}${name}${RESET}"
  echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# Slugify text for branch names
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-|-$//g' | cut -c1-50
}

# Extract prd-id from PRD file
extract_prd_id() {
  local prd_file=$1
  grep -m1 '^prd-id:' "$prd_file" 2>/dev/null | sed 's/^prd-id:[[:space:]]*//' | tr -d '\r'
}

# Setup PRD run directory
setup_prd_run_dir() {
  local prd_id=$1
  PRD_RUN_DIR="artifacts/prd/$prd_id"
  mkdir -p "$PRD_RUN_DIR/reports"
  ARTIFACTS_DIR="$PRD_RUN_DIR"
}

# Escape string for safe JSON inclusion
json_escape() {
  local str="$1"
  # Escape backslash first, then double quotes, then control characters
  printf '%s' "$str" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr -d '\n\r'
}

# Resolve repo root (fallback to current directory)
resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Check if a directory can be created/written
ensure_parent_dir_writable() {
  local file_path=$1
  local dir_path
  dir_path=$(dirname "$file_path")
  mkdir -p "$dir_path" 2>/dev/null || return 1
  [[ -w "$dir_path" ]]
}

# Extract a useful error message from a task log file
extract_error_from_log() {
  local log_file=$1
  local err=""
  if [[ -s "$log_file" ]]; then
    err=$(grep -v '^\[DEBUG\]' "$log_file" | tail -1 || true)
    [[ -z "$err" ]] && err=$(tail -1 "$log_file")
  fi
  echo "$err"
}

# Heuristic: detect external/infra/toolchain failures
is_external_failure_error() {
  local msg=$1
  [[ -z "$msg" ]] && return 1
  local lower
  lower=$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]')
  echo "$lower" | grep -Eq 'buninstallfailederror|command not found|enoent|eacces|permission denied|network|timeout|tls|econnreset|etimedout|lockfile|install|certificate|ssl'
}

persist_task_log() {
  local task_id=$1
  local log_file=$2
  [[ -z "$ARTIFACTS_DIR" ]] && return
  local reports_dir="$ORIGINAL_DIR/$ARTIFACTS_DIR/reports"
  mkdir -p "$reports_dir"
  if [[ -s "$log_file" ]]; then
    cp "$log_file" "$reports_dir/$task_id.log" 2>/dev/null || true
  fi
}

write_failed_task_report() {
  local task_id=$1
  local task_title=$2
  local error_msg=$3
  local failure_type=$4
  local branch=$5
  [[ -z "$ARTIFACTS_DIR" ]] && return
  local reports_dir="$ORIGINAL_DIR/$ARTIFACTS_DIR/reports"
  mkdir -p "$reports_dir"
  # Escape strings for valid JSON
  local safe_title safe_error safe_branch
  safe_title=$(json_escape "$task_title")
  safe_error=$(json_escape "$error_msg")
  safe_branch=$(json_escape "$branch")
  cat > "$reports_dir/$task_id.json" << EOF
{
  "taskId": "$task_id",
  "title": "$safe_title",
  "branch": "$safe_branch",
  "status": "failed",
  "failureType": "$failure_type",
  "errorMessage": "$safe_error",
  "commits": 0,
  "changedFiles": "",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

print_blocked_tasks() {
  echo ""
  echo "${RED}Blocked tasks:${RESET}"
  for id in "${!SCHED_STATE[@]}"; do
    if [[ "${SCHED_STATE[$id]}" == "pending" ]]; then
      local reason
      reason=$(scheduler_explain_block "$id")
      echo "  $id: $reason"
    fi
  done
}

external_fail_graceful_stop() {
  local timeout=${1:-300}
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=300
  local deadline=$((SECONDS + timeout))

  while [[ $(scheduler_count_running) -gt 0 && $SECONDS -lt $deadline ]]; do
    sleep 0.5
  done

  if [[ $(scheduler_count_running) -gt 0 ]]; then
    log_warn "External failure timeout reached; terminating remaining tasks."
    for idx in "${!ACTIVE_PIDS[@]}"; do
      local pid="${ACTIVE_PIDS[$idx]}"
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    done
    sleep 2
    for idx in "${!ACTIVE_PIDS[@]}"; do
      local pid="${ACTIVE_PIDS[$idx]}"
      local task_id="${ACTIVE_TASK_IDS[$idx]:-}"
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
      if [[ -n "$task_id" ]]; then
        scheduler_fail_task "$task_id"
        local task_title
        task_title=$(get_task_title_by_id_yaml_v1 "$task_id")
        write_failed_task_report "$task_id" "$task_title" "external-timeout" "external" ""
      fi
      if [[ -n "${ACTIVE_STATUS_FILES[$idx]:-}" ]]; then
        echo "failed" > "${ACTIVE_STATUS_FILES[$idx]}" 2>/dev/null || true
      fi
      if [[ -n "${ACTIVE_LOG_FILES[$idx]:-}" ]]; then
        persist_task_log "$task_id" "${ACTIVE_LOG_FILES[$idx]}"
      fi
    done
  fi
}

# ============================================
# HELP & VERSION
# ============================================

show_help() {
  cat << EOF
${BOLD}GRALPH${RESET} - Autonomous AI Coding Loop (v${VERSION})

${BOLD}USAGE:${RESET}
  ./scripts/gralph/gralph.sh [options]

${BOLD}AI ENGINE OPTIONS:${RESET}
  --claude            Use Claude Code (default)
  --opencode          Use OpenCode
  --opencode-model M  OpenCode model to use (e.g., "openai/gpt-4o", "anthropic/claude-sonnet-4-5")
  --cursor            Use Cursor agent
  --codex             Use Codex CLI

${BOLD}WORKFLOW OPTIONS:${RESET}
  --no-tests          Skip writing and running tests
  --no-lint           Skip linting
  --fast              Skip both tests and linting

${BOLD}EXECUTION OPTIONS:${RESET}
  --sequential        Run tasks one at a time (default: parallel)
  --max-parallel N    Max concurrent tasks (default: 3)
  --max-iterations N  Stop after N iterations (0 = unlimited)
  --max-retries N     Max retries per task on failure (default: 3)
  --retry-delay N     Seconds between retries (default: 5)
  --external-fail-timeout N  Seconds to wait for running tasks on external failure (default: 300)
  --dry-run           Show what would be done without executing

${BOLD}GIT BRANCH OPTIONS:${RESET}
  --branch-per-task   Create a new git branch for each task
  --base-branch NAME  Base branch to create task branches from (default: current)
  --create-pr         Create a pull request after each task (requires gh CLI)
  --draft-pr          Create PRs as drafts

${BOLD}PRD OPTIONS:${RESET}
  --prd FILE          PRD file path (default: PRD.md)
  --resume PRD-ID     Resume a previous run by prd-id

${BOLD}OTHER OPTIONS:${RESET}
  -v, --verbose       Show debug output
  -h, --help          Show this help
  --version           Show version number

${BOLD}EXAMPLES:${RESET}
  ./scripts/gralph/gralph.sh --opencode             # Run with OpenCode (parallel by default)
  ./scripts/gralph/gralph.sh --opencode --sequential  # Run sequentially
  ./scripts/gralph/gralph.sh --opencode --max-parallel 4  # Run 4 tasks concurrently
  ./scripts/gralph/gralph.sh --resume my-feature    # Resume previous run

${BOLD}WORKFLOW:${RESET}
  Prepare -> Execute -> Integrate
  1. Create PRD.md with prd-id line
  2. Run gralph: ./scripts/gralph/gralph.sh --opencode
  3. GRALPH creates artifacts/prd/<prd-id>/ with tasks.yaml
  4. Tasks run in parallel using DAG scheduler + resource locks
  5. Integration merges + semantic review

${BOLD}PRD FORMAT:${RESET}
  PRD.md must include a prd-id line:
    prd-id: my-feature-name

  GRALPH generates tasks.yaml automatically from PRD.md

EOF
}

show_version() {
  echo "GRALPH v${VERSION}"
}

# ============================================
# ARGUMENT PARSING
# ============================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-tests|--skip-tests)
        SKIP_TESTS=true
        shift
        ;;
      --no-lint|--skip-lint)
        SKIP_LINT=true
        shift
        ;;
      --fast)
        SKIP_TESTS=true
        SKIP_LINT=true
        shift
        ;;
      --opencode)
        AI_ENGINE="opencode"
        shift
        ;;
      --opencode-model)
        if [[ -z "${2:-}" ]]; then
          log_error "--opencode-model requires a model name (e.g., 'openai/gpt-4o')"
          exit 1
        fi
        OPENCODE_MODEL="$2"
        shift 2
        ;;
      --claude)
        AI_ENGINE="claude"
        shift
        ;;
      --cursor|--agent)
        AI_ENGINE="cursor"
        shift
        ;;
      --codex)
        AI_ENGINE="codex"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --max-iterations)
        MAX_ITERATIONS="${2:-0}"
        shift 2
        ;;
      --max-retries)
        MAX_RETRIES="${2:-3}"
        shift 2
        ;;
      --retry-delay)
        RETRY_DELAY="${2:-5}"
        shift 2
        ;;
      --external-fail-timeout)
        EXTERNAL_FAIL_TIMEOUT="${2:-300}"
        shift 2
        ;;
      --parallel)
        PARALLEL=true
        SEQUENTIAL=false
        shift
        ;;
      --sequential)
        SEQUENTIAL=true
        PARALLEL=false
        shift
        ;;
      --max-parallel)
        MAX_PARALLEL="${2:-3}"
        shift 2
        ;;
      --branch-per-task)
        BRANCH_PER_TASK=true
        shift
        ;;
      --base-branch)
        BASE_BRANCH="${2:-}"
        shift 2
        ;;
      --create-pr)
        CREATE_PR=true
        shift
        ;;
      --draft-pr)
        PR_DRAFT=true
        shift
        ;;
      --prd)
        PRD_FILE="${2:-PRD.md}"
        shift 2
        ;;
      --resume)
        RESUME_PRD_ID="${2:-}"
        if [[ -z "$RESUME_PRD_ID" ]]; then
          log_error "--resume requires a prd-id"
          exit 1
        fi
        shift 2
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --version)
        show_version
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        echo "Use --help for usage"
        exit 1
        ;;
    esac
  done
}

# ============================================
# PRE-FLIGHT CHECKS
# ============================================

check_requirements() {
  local missing=()

  if ! command -v yq &>/dev/null; then
    log_error "yq is required for YAML parsing. Install from https://github.com/mikefarah/yq"
    exit 1
  fi

  # Handle --resume mode
  if [[ -n "$RESUME_PRD_ID" ]]; then
    PRD_ID="$RESUME_PRD_ID"
    PRD_RUN_DIR="artifacts/prd/$PRD_ID"
    if [[ ! -d "$PRD_RUN_DIR" ]]; then
      log_error "No run found for prd-id: $PRD_ID"
      exit 1
    fi
    if [[ ! -f "$PRD_RUN_DIR/tasks.yaml" ]]; then
      log_error "No tasks.yaml found in $PRD_RUN_DIR"
      exit 1
    fi
    PRD_FILE="$PRD_RUN_DIR/tasks.yaml"
    ARTIFACTS_DIR="$PRD_RUN_DIR"
    log_info "Resuming PRD: $PRD_ID"
  else
    # Normal mode: read PRD and setup run dir
    if [[ ! -f "$PRD_FILE" ]]; then
      log_error "$PRD_FILE not found"
      exit 1
    fi
    
    PRD_ID=$(extract_prd_id "$PRD_FILE")
    if [[ -z "$PRD_ID" ]]; then
      log_error "PRD missing prd-id. Add 'prd-id: your-id' to the PRD file."
      exit 1
    fi
    
    setup_prd_run_dir "$PRD_ID"
    
    # Copy PRD to run dir
    cp "$PRD_FILE" "$PRD_RUN_DIR/PRD.md"
    
    # Generate or reuse tasks.yaml
    if [[ -f "$PRD_RUN_DIR/tasks.yaml" ]]; then
      log_info "Resuming existing run for $PRD_ID"
    else
      log_info "Generating tasks.yaml for $PRD_ID..."
      if ! run_metadata_agent "$PRD_RUN_DIR/PRD.md" "$PRD_RUN_DIR/tasks.yaml"; then
        log_error "Failed to generate tasks.yaml"
        exit 1
      fi
    fi
    
    PRD_FILE="$PRD_RUN_DIR/tasks.yaml"
  fi

  # Validate tasks.yaml
  if ! validate_tasks_yaml_v1; then
    exit 1
  fi

  # Check for AI CLI
  case "$AI_ENGINE" in
    opencode)
      if ! command -v opencode &>/dev/null; then
        log_error "OpenCode CLI not found. Install from https://opencode.ai/docs/"
        exit 1
      fi
      ;;
    codex)
      if ! command -v codex &>/dev/null; then
        log_error "Codex CLI not found. Make sure 'codex' is in your PATH."
        exit 1
      fi
      ;;
    cursor)
      if ! command -v agent &>/dev/null; then
        log_error "Cursor agent CLI not found. Make sure Cursor is installed and 'agent' is in your PATH."
        exit 1
      fi
      ;;
    *)
      if ! command -v claude &>/dev/null; then
        log_error "Claude Code CLI not found. Install from https://github.com/anthropics/claude-code"
        exit 1
      fi
      ;;
  esac

  # Check for jq
  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi

  # Check for gh if PR creation is requested
  if [[ "$CREATE_PR" == true ]] && ! command -v gh &>/dev/null; then
    log_error "GitHub CLI (gh) is required for --create-pr. Install from https://cli.github.com/"
    exit 1
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Missing optional dependencies: ${missing[*]}"
    log_warn "Token tracking may not work properly"
  fi

  # Create progress.txt if missing
if [[ ! -f "scripts/gralph/progress.txt" ]]; then
  log_warn "progress.txt not found, creating it..."
  touch scripts/gralph/progress.txt
fi

  # Set base branch if not specified
  if [[ "$BRANCH_PER_TASK" == true ]] && [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    log_debug "Using base branch: $BASE_BRANCH"
  fi
}

# ============================================
# CLEANUP HANDLER
# ============================================

cleanup() {
  local exit_code=$?
  
  # Restore cursor visibility (in case we were in a progress loop)
  printf "\e[?25h" 2>/dev/null || true
  
  # Kill background processes
  [[ -n "$monitor_pid" ]] && kill "$monitor_pid" 2>/dev/null || true
  [[ -n "$ai_pid" ]] && kill "$ai_pid" 2>/dev/null || true
  
  # Kill parallel processes
  for pid in "${parallel_pids[@]+"${parallel_pids[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
  
  # Kill any remaining child processes
  pkill -P $$ 2>/dev/null || true
  
  # Remove temp file
  [[ -n "$tmpfile" ]] && rm -f "$tmpfile"
  [[ -n "$CODEX_LAST_MESSAGE_FILE" ]] && rm -f "$CODEX_LAST_MESSAGE_FILE"
  
  # Cleanup parallel worktrees
  if [[ -n "$WORKTREE_BASE" ]] && [[ -d "$WORKTREE_BASE" ]]; then
    # Remove all worktrees we created
    for dir in "$WORKTREE_BASE"/agent-*; do
      if [[ -d "$dir" ]]; then
        if git -C "$dir" status --porcelain 2>/dev/null | grep -q .; then
          log_warn "Preserving dirty worktree: $dir"
          continue
        fi
        git worktree remove "$dir" 2>/dev/null || true
      fi
    done
    if ! find "$WORKTREE_BASE" -maxdepth 1 -type d -name 'agent-*' -print -quit 2>/dev/null | grep -q .; then
      rm -rf "$WORKTREE_BASE" 2>/dev/null || true
    else
      log_warn "Preserving worktree base with dirty agents: $WORKTREE_BASE"
    fi
  fi
  
  # Show message on interrupt
  if [[ $exit_code -eq 130 ]]; then
    printf "\n"
    log_warn "Interrupted! Cleaned up."
    
    # Show branches created if any
    if [[ -n "${task_branches[*]+"${task_branches[*]}"}" ]]; then
      log_info "Branches created: ${task_branches[*]}"
    fi
  fi
}

# ============================================
# YAML V1 VALIDATION (DAG + LOCKS)
# ============================================

# Get task ID by index
get_task_id_yaml_v1() {
  local idx=$1
  yq -r ".tasks[$idx].id // \"\"" "$PRD_FILE" 2>/dev/null
}

# Get all task IDs
get_all_task_ids_yaml_v1() {
  yq -r '.tasks[].id' "$PRD_FILE" 2>/dev/null
}

# Get pending task IDs
get_pending_task_ids_yaml_v1() {
  yq -r '.tasks[] | select(.completed != true) | .id' "$PRD_FILE" 2>/dev/null
}

# Get task title by ID
get_task_title_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .title" "$PRD_FILE" 2>/dev/null
}

# Get task dependsOn by ID
get_task_deps_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .dependsOn[]?" "$PRD_FILE" 2>/dev/null
}

# Get task touches by ID
get_task_touches_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .touches[]?" "$PRD_FILE" 2>/dev/null
}

# Get explicit locks by ID (supports legacy mutex field)
get_task_locks_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .locks[]?" "$PRD_FILE" 2>/dev/null
  yq -r ".tasks[] | select(.id == \"$id\") | .mutex[]?" "$PRD_FILE" 2>/dev/null
}

# Infer locks from touches (conservative to preserve safety)
infer_locks_from_touches() {
  local id=$1
  declare -A seen=()
  while IFS= read -r touch; do
    [[ -z "$touch" ]] && continue
    local lock=""

    case "$touch" in
      *package.json|*package-lock.json|*pnpm-lock.yaml|*yarn.lock)
        lock="lockfile"
        ;;
      *db/migrations/*|*db/migrations/**|*migrations/*)
        lock="db-migrations"
        ;;
      *prisma/*|*schema.prisma)
        lock="db-schema"
        ;;
      *router/*|*routes/*)
        lock="router"
        ;;
      *config/*|*.env*|*settings/*)
        lock="global-config"
        ;;
      *)
        local base="${touch%%/*}"
        if [[ -z "$base" || "$base" == "$touch" || "$base" == "." || "$base" == "*" || "$base" == "**" ]]; then
          lock="root"
        else
          lock="$base"
        fi
        ;;
    esac

    if [[ -n "$lock" && -z "${seen[$lock]:-}" ]]; then
      seen[$lock]=1
      echo "$lock"
    fi
  done < <(get_task_touches_by_id_yaml_v1 "$id")
}

# Get effective locks (explicit + inferred)
get_task_effective_locks_yaml_v1() {
  local id=$1
  declare -A seen=()
  while IFS= read -r lock; do
    [[ -z "$lock" ]] && continue
    if [[ -z "${seen[$lock]:-}" ]]; then
      seen[$lock]=1
      echo "$lock"
    fi
  done < <(get_task_locks_by_id_yaml_v1 "$id")

  while IFS= read -r lock; do
    [[ -z "$lock" ]] && continue
    if [[ -z "${seen[$lock]:-}" ]]; then
      seen[$lock]=1
      echo "$lock"
    fi
  done < <(infer_locks_from_touches "$id")
}

# Check if task is completed
is_task_completed_yaml_v1() {
  local id=$1
  local completed
  completed=$(yq -r ".tasks[] | select(.id == \"$id\") | .completed" "$PRD_FILE" 2>/dev/null)
  [[ "$completed" == "true" ]]
}

# Mark task complete by ID
mark_task_complete_by_id_yaml_v1() {
  local id=$1
  yq -i "(.tasks[] | select(.id == \"$id\")).completed = true" "$PRD_FILE"
}

# Validate tasks.yaml v1 schema
validate_tasks_yaml_v1() {
  local errors=()
  
  # Check version (optional)
  local version
  version=$(yq -r '.version // ""' "$PRD_FILE" 2>/dev/null)
  if [[ -n "$version" && "$version" != "1" ]]; then
    errors+=("version must be 1 if specified (got: $version)")
  fi
  
  # Get all task IDs for dependency checking
  local all_ids=()
  while IFS= read -r id; do
    [[ -n "$id" ]] && all_ids+=("$id")
  done < <(get_all_task_ids_yaml_v1)
  
  # Check for duplicate IDs
  local seen_ids=()
  for id in "${all_ids[@]}"; do
    if [[ " ${seen_ids[*]} " =~ " $id " ]]; then
      errors+=("Duplicate id: $id")
    else
      seen_ids+=("$id")
    fi
  done
  
  # Validate each task
  local task_count
  task_count=$(yq -r '.tasks | length' "$PRD_FILE" 2>/dev/null)
  
  for ((i=0; i<task_count; i++)); do
    local id title completed completed_raw
    id=$(yq -r ".tasks[$i].id // \"\"" "$PRD_FILE")
    title=$(yq -r ".tasks[$i].title // \"\"" "$PRD_FILE")
    # Important: do NOT use `// ""` here. In yq/jq semantics, `false // ""` becomes "",
    # which would incorrectly reject valid `completed: false` values.
    completed_raw=$(yq -r ".tasks[$i].completed" "$PRD_FILE")
    # Normalize to support yq/yaml variations (CRLF, True/False)
    completed=$(printf '%s' "$completed_raw" | tr -d '\r' | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    
    # Check required fields
    [[ -z "$id" ]] && errors+=("Task $((i+1)): missing id")
    [[ -z "$title" ]] && errors+=("Task $((i+1)): missing title")
    [[ "$completed" != "true" && "$completed" != "false" ]] && errors+=("Task $id: completed must be true/false")
    
    # Validate dependsOn references
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      if [[ ! " ${all_ids[*]} " =~ " $dep " ]]; then
        errors+=("Task $id: dependsOn '$dep' not found")
      fi
    done < <(yq -r ".tasks[$i].dependsOn[]?" "$PRD_FILE" 2>/dev/null)
    
  done
  
  # Check for cycles
  local cycle_path
  cycle_path=$(detect_cycles_yaml_v1)
  if [[ -n "$cycle_path" ]]; then
    errors+=("Cycle detected: $cycle_path")
  fi
  
  # Report errors
  if [[ ${#errors[@]} -gt 0 ]]; then
  log_error "tasks.yaml validation failed:"
    for err in "${errors[@]}"; do
      echo "  - $err" >&2
    done
    return 1
  fi
  
  log_success "tasks.yaml valid (${#all_ids[@]} tasks)"
  return 0
}

# Detect cycles using DFS
detect_cycles_yaml_v1() {
  local -A state  # unvisited=0, visiting=1, visited=2
  local -A parent
  local cycle_found=""
  
  # Initialize
  local all_ids=()
  while IFS= read -r id; do
    [[ -n "$id" ]] && all_ids+=("$id")
    state[$id]=0
  done < <(get_all_task_ids_yaml_v1)
  
  # DFS function (iterative to avoid bash recursion limits)
  dfs_check() {
    local start=$1
    local stack=("$start")
    local path_stack=("$start")
    
    while [[ ${#stack[@]} -gt 0 ]]; do
      local current="${stack[-1]}"
      
      if [[ ${state[$current]} -eq 0 ]]; then
        state[$current]=1  # visiting
        
        # Get dependencies
        while IFS= read -r dep; do
          [[ -z "$dep" ]] && continue
          
          if [[ ${state[$dep]} -eq 1 ]]; then
            # Found cycle - build path
            local cycle_path="$dep"
            for ((j=${#path_stack[@]}-1; j>=0; j--)); do
              cycle_path="${path_stack[$j]} → $cycle_path"
              [[ "${path_stack[$j]}" == "$dep" ]] && break
            done
            echo "$cycle_path"
            return
          elif [[ ${state[$dep]} -eq 0 ]]; then
            stack+=("$dep")
            path_stack+=("$dep")
            parent[$dep]=$current
          fi
        done < <(get_task_deps_by_id_yaml_v1 "$current")
        
      else
        # Backtrack
        unset 'stack[-1]'
        unset 'path_stack[-1]'
        state[$current]=2  # visited
      fi
    done
  }
  
  # Run DFS from each unvisited node
  for id in "${all_ids[@]}"; do
    if [[ ${state[$id]} -eq 0 ]]; then
      local result
      result=$(dfs_check "$id")
      if [[ -n "$result" ]]; then
        echo "$result"
        return
      fi
    fi
  done
}

# ============================================
# DAG SCHEDULER (YAML V1)
# ============================================

# Global scheduler state (arrays for bash 3.x compat, but we use bash 4+ features)
declare -A SCHED_STATE      # task_id -> pending|running|done|failed
declare -A SCHED_RESOURCES  # lock -> task_id (who holds it)

# Initialize scheduler state
scheduler_init_yaml_v1() {
  SCHED_STATE=()
  SCHED_RESOURCES=()
  
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if is_task_completed_yaml_v1 "$id"; then
      SCHED_STATE[$id]="done"
    else
      SCHED_STATE[$id]="pending"
    fi
  done < <(get_all_task_ids_yaml_v1)
  
}

# Check if task dependencies are satisfied
scheduler_deps_satisfied() {
  local id=$1
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if [[ "${SCHED_STATE[$dep]}" != "done" ]]; then
      return 1
    fi
  done < <(get_task_deps_by_id_yaml_v1 "$id")
  return 0
}

# Check if task can acquire its resources
scheduler_resources_available() {
  local id=$1
  while IFS= read -r lock; do
    [[ -z "$lock" ]] && continue
    # Use :- to provide default empty value (fixes set -u unbound variable)
    if [[ -n "${SCHED_RESOURCES[$lock]:-}" ]]; then
      return 1
    fi
  done < <(get_task_effective_locks_yaml_v1 "$id")
  return 0
}

# Lock resources for a task
scheduler_lock_resources() {
  local id=$1
  while IFS= read -r lock; do
    [[ -z "$lock" ]] && continue
    SCHED_RESOURCES[$lock]=$id
  done < <(get_task_effective_locks_yaml_v1 "$id")
}

# Unlock resources for a task
scheduler_unlock_resources() {
  local id=$1
  while IFS= read -r lock; do
    [[ -z "$lock" ]] && continue
    unset "SCHED_RESOURCES[$lock]"
  done < <(get_task_effective_locks_yaml_v1 "$id")
}

# Get ready tasks (deps satisfied and resources available)
scheduler_get_ready() {
  local ready=()
  for id in "${!SCHED_STATE[@]}"; do
    if [[ "${SCHED_STATE[$id]}" == "pending" ]]; then
      if scheduler_deps_satisfied "$id" && scheduler_resources_available "$id"; then
        ready+=("$id")
      fi
    fi
  done
  printf '%s\n' "${ready[@]}"
}

# Get count of running tasks
scheduler_count_running() {
  local count=0
  for id in "${!SCHED_STATE[@]}"; do
    [[ "${SCHED_STATE[$id]}" == "running" ]] && count=$((count + 1))
  done
  echo "$count"
}

# Get count of pending tasks
scheduler_count_pending() {
  local count=0
  for id in "${!SCHED_STATE[@]}"; do
    [[ "${SCHED_STATE[$id]}" == "pending" ]] && count=$((count + 1))
  done
  echo "$count"
}

# Mark task as running
scheduler_start_task() {
  local id=$1
  SCHED_STATE[$id]="running"
  scheduler_lock_resources "$id"
  log_debug "Task $id: pending → running (resources locked)"
}

# Mark task as done
scheduler_complete_task() {
  local id=$1
  SCHED_STATE[$id]="done"
  scheduler_unlock_resources "$id"
  mark_task_complete_by_id_yaml_v1 "$id"
  log_debug "Task $id: running → done (resources released)"
}

# Mark task as failed
scheduler_fail_task() {
  local id=$1
  SCHED_STATE[$id]="failed"
  scheduler_unlock_resources "$id"
  log_debug "Task $id: running → failed (resources released)"
}

# Explain why a task is blocked
scheduler_explain_block() {
  local id=$1
  local reasons=()
  
  # Check deps
  local blocked_deps=()
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if [[ "${SCHED_STATE[$dep]}" != "done" ]]; then
      blocked_deps+=("$dep (${SCHED_STATE[$dep]:-unknown})")
    fi
  done < <(get_task_deps_by_id_yaml_v1 "$id")
  
  if [[ ${#blocked_deps[@]} -gt 0 ]]; then
    reasons+=("dependsOn: ${blocked_deps[*]}")
  fi
  
  # Check resources
  local blocked_locks=()
  while IFS= read -r lock; do
    [[ -z "$lock" ]] && continue
    # Use :- to provide default empty value (fixes set -u unbound variable)
    if [[ -n "${SCHED_RESOURCES[$lock]:-}" ]]; then
      blocked_locks+=("$lock (held by ${SCHED_RESOURCES[$lock]:-})")
    fi
  done < <(get_task_effective_locks_yaml_v1 "$id")
  
  if [[ ${#blocked_locks[@]} -gt 0 ]]; then
    reasons+=("resources locked: ${blocked_locks[*]}")
  fi
  
  if [[ ${#reasons[@]} -gt 0 ]]; then
    echo "${reasons[*]}"
  fi
}

# Check for deadlock
scheduler_check_deadlock() {
  local pending
  pending=$(scheduler_count_pending)
  local running
  running=$(scheduler_count_running)
  local ready
  ready=$(scheduler_get_ready | wc -l | tr -d ' ')
  
  if [[ "$pending" -gt 0 && "$running" -eq 0 && "$ready" -eq 0 ]]; then
    return 0  # Deadlock!
  fi
  return 1
}

# ============================================
# PIPELINE: Prepare -> Execute -> Integrate
# ============================================

# Artifacts directory for this run
ARTIFACTS_DIR=""

# Initialize artifacts directory
init_artifacts_dir() {
  ARTIFACTS_DIR="artifacts/run-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ARTIFACTS_DIR/reports"
  export ARTIFACTS_DIR
}

# Find PRD file (check common locations)
find_prd_file() {
  local candidates=(
    "PRD.md"
    "prd.md"
    "tasks/prd-*.md"
  )
  for pattern in "${candidates[@]}"; do
    for f in $pattern; do
      [[ -f "$f" ]] && echo "$f" && return 0
    done
  done
  return 1
}

# ============================================
# PREPARE: PRD -> tasks.yaml (Metadata Agent)
# ============================================

run_metadata_agent() {
  local prd_file=$1
  local output_file="${2:-tasks.yaml}"
  local output_dir
  output_dir=$(dirname "$output_file")
  
  log_info "Generating $output_file from $prd_file..."
  
  local prompt
  prompt=$(cat << EOF
You are generating task metadata. Read the PRD and output ONLY a tasks.yaml file.

@$prd_file

Format (YAML v1):
version: 1
branchName: gralph/your-feature-name
tasks:
  - id: TASK-001
    title: "Short task description"
    completed: false
    dependsOn: []
    touches: ["src/path/**"]
    locks: ["lockfile"]        # optional (explicit override)
    mergeNotes: ""             # optional
    verify: []                 # optional

Rules:
1. Each task gets a unique ID (TASK-001, TASK-002, etc.)
2. Order tasks by dependency (database first, then backend, then frontend)
3. Use dependsOn to link tasks that must run after others
4. Include touches for every task (paths/globs it will modify). Be conservative.
5. Locks are inferred from touches. Only add explicit locks when PRD mentions an exclusive/shared hotspot.
6. Avoid legacy "mutex" unless the PRD explicitly references it.
7. Set branchName to a short kebab-case feature name prefixed with "gralph/" (based on the PRD)
8. Keep tasks small and focused (completable in one session)
9. Ensure dependsOn references exist and avoid cycles.

Save the file as $output_file.
Do NOT implement anything - only create the tasks.yaml file.
EOF
)

  local tmpfile
  tmpfile=$(mktemp)
  
  execute_ai_prompt "$prompt" "$tmpfile"
  
  rm -f "$tmpfile"
  
  if [[ ! -f "$output_file" ]]; then
    log_error "Metadata agent failed to create $output_file"
    return 1
  fi
  
  log_success "Generated $output_file"
  return 0
}

# ============================================
# EXECUTE: Task Reports
# ============================================

# Get task mergeNotes by ID
get_task_merge_notes_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .mergeNotes // \"\"" "$PRD_FILE" 2>/dev/null
}

# Save task report after agent completion
save_task_report() {
  local task_id=$1
  local branch=$2
  local worktree_dir=$3
  local status=$4
  
  [[ -z "$ARTIFACTS_DIR" ]] && return
  
  local changed_files
  changed_files=$(git -C "$worktree_dir" diff --name-only "$BASE_BRANCH"..HEAD 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  
  local commit_count
  commit_count=$(git -C "$worktree_dir" rev-list --count "$BASE_BRANCH"..HEAD 2>/dev/null || echo "0")
  
  # Escape strings for valid JSON
  local safe_branch safe_changed
  safe_branch=$(json_escape "$branch")
  safe_changed=$(json_escape "$changed_files")
  
  cat > "$ARTIFACTS_DIR/reports/$task_id.json" << EOF
{
  "taskId": "$task_id",
  "branch": "$safe_branch",
  "status": "$status",
  "commits": $commit_count,
  "changedFiles": "$safe_changed",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# ============================================
# INTEGRATE: Integration Branch + Merge Agent
# ============================================

INTEGRATION_BRANCH=""

create_integration_branch() {
INTEGRATION_BRANCH="gralph/integration-$(date +%Y%m%d-%H%M%S)"
  git checkout -b "$INTEGRATION_BRANCH" "$BASE_BRANCH" >/dev/null 2>&1
  log_info "Created integration branch: $INTEGRATION_BRANCH"
}

# Merge a branch, use AI to resolve conflicts if needed
merge_branch_with_fallback() {
  local branch=$1
  local task_id=$2
  
  if git merge --no-edit "$branch" >/dev/null 2>&1; then
    return 0
  fi
  
  # Conflict - try AI resolution
  log_warn "Conflict merging $branch, attempting AI resolution..."
  
  local conflicted_files
  conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null)
  
  local merge_notes
  merge_notes=$(get_task_merge_notes_yaml_v1 "$task_id")
  
  local prompt
  prompt=$(cat << EOF
You are resolving git merge conflicts for an integration merge.

Conflicted files:
$conflicted_files

Merge notes from task: $merge_notes

Rules:
1. Read the conflict markers (<<<<<<< HEAD, =======, >>>>>>>).
2. Combine BOTH changes intelligently (prefer additive merges over choosing one side).
3. Keep all necessary imports/exports and remove duplicates.
4. Remove all conflict markers and ensure valid syntax.
5. Do not change unrelated files.

Then run:
git add <files>
git commit --no-edit
EOF
)

  local tmpfile
  tmpfile=$(mktemp)
  
  execute_ai_prompt "$prompt" "$tmpfile"
  
  rm -f "$tmpfile"
  
  # Check if resolved
  if git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
    log_error "AI failed to resolve conflicts in $branch"
    git merge --abort 2>/dev/null
    return 1
  fi
  
  log_success "AI resolved conflicts in $branch"
  return 0
}

# ============================================
# INTEGRATE: Semantic Reviewer
# ============================================

run_reviewer_agent() {
  [[ -z "$ARTIFACTS_DIR" ]] && return 0
  [[ -z "$INTEGRATION_BRANCH" ]] && return 0
  
  log_info "Running semantic reviewer..."
  
  local diff_summary
  diff_summary=$(git diff --stat "$BASE_BRANCH".."$INTEGRATION_BRANCH" 2>/dev/null | tail -20)
  
  local reports_summary=""
  for report in "$ARTIFACTS_DIR"/reports/*.json; do
    [[ -f "$report" ]] && reports_summary="$reports_summary\n$(cat "$report")"
  done
  
  local prompt
  prompt=$(cat << EOF
Review the integrated code changes for semantic issues, design inconsistencies, and potential bugs.

Diff summary:
$diff_summary

Task reports:
$reports_summary

Scope (what to check):
- API consistency across tasks
- Type/interface compatibility
- Broken imports/exports or references
- Inconsistent error handling patterns
- Dead code from partial changes

Do NOT focus on formatting or style-only issues.

Severity levels:
- blocker: breaks compilation/runtime, must fix before merge
- critical: logic error or data risk, should fix before merge
- warning: inconsistency or tech debt
- info: optional suggestion

Output a JSON file at: $ARTIFACTS_DIR/review-report.json

Format:
{
  "version": 1,
  "reviewedCommits": ["abc123", "def456"],
  "summary": {"blockers": 0, "critical": 0, "warnings": 0, "info": 0},
  "issues": [
    {
      "id": "ISSUE-001",
      "severity": "blocker|critical|warning|info",
      "title": "Short issue title",
      "file": "path",
      "line": 42,
      "description": "What is wrong",
      "evidence": "Why this is a problem",
      "suggestedFix": "How to fix",
      "relatedTasks": ["TASK-001"]
    }
  ],
  "designConflicts": [
    {"pattern": "Error handling", "description": "Mismatch", "recommendation": "Unify pattern"}
  ],
  "followUps": ["Optional improvements"]
}

If no issues found, set issues to an empty array and all counts to 0.
EOF
)

  local tmpfile
  tmpfile=$(mktemp)
  
  execute_ai_prompt "$prompt" "$tmpfile"
  
  rm -f "$tmpfile"
  
  if [[ -f "$ARTIFACTS_DIR/review-report.json" ]]; then
    local blockers
    blockers=$(jq -r '[.issues[] | select(.severity == "blocker")] | length' "$ARTIFACTS_DIR/review-report.json" 2>/dev/null || echo "0")
    
    if [[ "$blockers" -gt 0 ]]; then
      log_warn "Reviewer found $blockers blocker(s)"
      return 1
    fi
    
    log_success "Review passed (no blockers)"
  fi
  
  return 0
}

# Generate fix tasks from review report
generate_fix_tasks() {
  [[ ! -f "$ARTIFACTS_DIR/review-report.json" ]] && return 0
  
  local blockers
  blockers=$(jq -r '.issues[] | select(.severity == "blocker")' "$ARTIFACTS_DIR/review-report.json" 2>/dev/null)
  
  [[ -z "$blockers" ]] && return 0
  
  log_info "Generating fix tasks from blockers..."
  
  local fix_num=1
  echo "$blockers" | jq -c '.' | while IFS= read -r issue; do
    local desc
    desc=$(echo "$issue" | jq -r '.description')
    local fix
    fix=$(echo "$issue" | jq -r '.suggestedFix')
    
    yq -i ".tasks += [{
      \"id\": \"FIX-$(printf '%03d' $fix_num)\",
      \"title\": \"Fix: $desc\",
      \"completed\": false,
      \"dependsOn\": [],
      \"touches\": []
    }]" "$PRD_FILE"
    
    fix_num=$((fix_num + 1))
  done
  
  log_success "Added fix tasks"
}

# ============================================
# GIT BRANCH MANAGEMENT
# ============================================

get_run_branch_from_tasks_yaml() {
  local name
  name=$(yq -r '.branchName // ""' "$PRD_FILE" 2>/dev/null || echo "")
  [[ "$name" == "null" ]] && name=""
  echo "$name"
}

ensure_run_branch() {
  RUN_BRANCH=$(get_run_branch_from_tasks_yaml)
  [[ -z "$RUN_BRANCH" ]] && return 0

  local base_ref="$BASE_BRANCH"
  if [[ -z "$base_ref" ]]; then
    base_ref=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi

  if git show-ref --verify --quiet "refs/heads/$RUN_BRANCH"; then
    log_info "Switching to run branch: $RUN_BRANCH"
    git checkout "$RUN_BRANCH" >/dev/null 2>&1 || {
      log_error "Failed to checkout run branch: $RUN_BRANCH"
      exit 1
    }
  else
    log_info "Creating run branch: $RUN_BRANCH from $base_ref"
    git checkout "$base_ref" >/dev/null 2>&1 || true
    git pull origin "$base_ref" >/dev/null 2>&1 || true
    git checkout -b "$RUN_BRANCH" >/dev/null 2>&1 || {
      log_error "Failed to create run branch: $RUN_BRANCH"
      exit 1
    }
  fi

  BASE_BRANCH="$RUN_BRANCH"
}

create_task_branch() {
  local task=$1
  local branch_name="gralph/$(slugify "$task")"
  
  log_debug "Creating branch: $branch_name from $BASE_BRANCH"
  
  # Stash any changes (only pop if a new stash was created)
  local stash_before stash_after stashed=false
  stash_before=$(git stash list -1 --format='%gd %s' 2>/dev/null || true)
  git stash push -m "gralph-autostash" >/dev/null 2>&1 || true
  stash_after=$(git stash list -1 --format='%gd %s' 2>/dev/null || true)
  if [[ -n "$stash_after" ]] && [[ "$stash_after" != "$stash_before" ]] && [[ "$stash_after" == *"gralph-autostash"* ]]; then
    stashed=true
  fi
  
  # Create and checkout new branch
  git checkout "$BASE_BRANCH" 2>/dev/null || true
  git pull origin "$BASE_BRANCH" 2>/dev/null || true
  git checkout -b "$branch_name" 2>/dev/null || {
    # Branch might already exist
    git checkout "$branch_name" 2>/dev/null || true
  }
  
  # Pop stash if we stashed
  if [[ "$stashed" == true ]]; then
    git stash pop >/dev/null 2>&1 || true
  fi
  
  task_branches+=("$branch_name")
  echo "$branch_name"
}

create_pull_request() {
  local branch=$1
  local task=$2
  local body="${3:-Automated PR created by GRALPH}"
  
  local draft_flag=""
  [[ "$PR_DRAFT" == true ]] && draft_flag="--draft"
  
  log_info "Creating pull request for $branch..."
  
  # Push branch first
  git push -u origin "$branch" 2>/dev/null || {
    log_warn "Failed to push branch $branch"
    return 1
  }
  
  # Create PR
  local pr_url
  pr_url=$(gh pr create \
    --base "$BASE_BRANCH" \
    --head "$branch" \
    --title "$task" \
    --body "$body" \
    $draft_flag 2>/dev/null) || {
    log_warn "Failed to create PR for $branch"
    return 1
  }
  
  log_success "PR created: $pr_url"
  echo "$pr_url"
}

return_to_base_branch() {
  if [[ "$BRANCH_PER_TASK" == true ]]; then
    git checkout "$BASE_BRANCH" 2>/dev/null || true
  fi
}

# ============================================
# PROGRESS MONITOR
# ============================================

# Get current step from agent output file (for parallel display)
get_agent_current_step() {
  local file=$1
  local step="Thinking"
  
  if [[ ! -f "$file" ]] || [[ ! -s "$file" ]]; then
    echo "$step"
    return
  fi
  
  local content
  content=$(tail -c 3000 "$file" 2>/dev/null || true)
  
  if echo "$content" | grep -qE 'git commit|"command":"git commit'; then
    step="Committing"
  elif echo "$content" | grep -qE 'git add|"command":"git add'; then
    step="Staging"
  elif echo "$content" | grep -qE 'progress\.txt'; then
    step="Logging"
  elif echo "$content" | grep -qE 'PRD\.md|tasks\.yaml'; then
    step="Updating PRD"
  elif echo "$content" | grep -qE 'lint|eslint|biome|prettier'; then
    step="Linting"
  elif echo "$content" | grep -qE 'vitest|jest|bun test|npm test|pytest|go test'; then
    step="Testing"
  elif echo "$content" | grep -qE '\.test\.|\.spec\.|__tests__|_test\.go'; then
    step="Writing tests"
  elif echo "$content" | grep -qE '"tool":"[Ww]rite"|"tool":"[Ee]dit"|"name":"write"|"name":"edit"|"tool_name":"write"|"tool_name":"edit"'; then
    step="Implementing"
  elif echo "$content" | grep -qE '"tool":"[Rr]ead"|"tool":"[Gg]lob"|"tool":"[Gg]rep"|"name":"read"|"name":"glob"|"name":"grep"|"tool_name":"read"'; then
    step="Reading code"
  elif echo "$content" | grep -qE '"tool":"[Bb]ash"|"tool":"[Tt]erminal"|"name":"bash"|"tool_name":"bash"'; then
    step="Running cmd"
  elif echo "$content" | grep -qE '"type":"thinking"|"thinking"'; then
    step="Thinking"
  fi
  
  echo "$step"
}

# Get step color
get_step_color() {
  local step=$1
  case "$step" in
    "Thinking"|"Reading code") echo "$CYAN" ;;
    "Implementing"|"Writing tests") echo "$MAGENTA" ;;
    "Testing"|"Linting"|"Running cmd") echo "$YELLOW" ;;
    "Staging"|"Committing") echo "$GREEN" ;;
    *) echo "$BLUE" ;;
  esac
}

monitor_progress() {
  local file=$1
  local task=$2
  local start_time
  start_time=$(date +%s)
  local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_idx=0

  task="${task:0:40}"

  while true; do
    local elapsed=$(($(date +%s) - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    # Use unified step detection
    current_step=$(get_agent_current_step "$file")

    local spinner_char="${spinstr:$spin_idx:1}"
    local step_color
    step_color=$(get_step_color "$current_step")

    # Use tput for cleaner line clearing
    tput cr 2>/dev/null || printf "\r"
    tput el 2>/dev/null || true
    printf "  %s ${step_color}%-16s${RESET} │ %s ${DIM}[%02d:%02d]${RESET}" "$spinner_char" "$current_step" "$task" "$mins" "$secs"

    spin_idx=$(( (spin_idx + 1) % ${#spinstr} ))
    sleep 0.12
  done
}

# ============================================
# NOTIFICATION (Cross-platform)
# ============================================

notify_done() {
  local message="${1:-GRALPH has completed all tasks!}"
  
  # macOS
  if command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
  fi
  
  # macOS notification
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"GRALPH\"" 2>/dev/null || true
  fi
  
  # Linux (notify-send)
  if command -v notify-send &>/dev/null; then
    notify-send "GRALPH" "$message" 2>/dev/null || true
  fi
  
  # Linux (paplay for sound)
  if command -v paplay &>/dev/null; then
    paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
  fi
  
  # Windows (powershell)
  if command -v powershell.exe &>/dev/null; then
    powershell.exe -Command "[System.Media.SystemSounds]::Asterisk.Play()" 2>/dev/null || true
  fi
}

notify_error() {
  local message="${1:-GRALPH encountered an error}"
  
  # macOS
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"GRALPH - Error\"" 2>/dev/null || true
  fi
  
  # Linux
  if command -v notify-send &>/dev/null; then
    notify-send -u critical "GRALPH - Error" "$message" 2>/dev/null || true
  fi
}

# ============================================
# AI ENGINE ABSTRACTION
# ============================================

# Execute AI prompt with unified interface
# Args:
#   $1 = prompt
#   $2 = output_file
#   $3 = options string (optional): "async" "wd=/path" "log=/path" "tee=/path"
# Example: execute_ai_prompt "$prompt" "$out" "async wd=$worktree_dir log=$logfile"
execute_ai_prompt() {
  local prompt="$1"
  local output_file="$2"
  local options="${3:-}"

  # Parse options
  local async=false
  local working_dir=""
  local log_file=""
  local tee_file=""

  for opt in $options; do
    case "$opt" in
      async) async=true ;;
      wd=*) working_dir="${opt#wd=}" ;;
      log=*) log_file="${opt#log=}" ;;
      tee=*) tee_file="${opt#tee=}" ;;
    esac
  done

  # Build command as an array to avoid eval/quoting issues
  local -a cmd=()
  case "$AI_ENGINE" in
    opencode)
      cmd=(env OPENCODE_PERMISSION='{"*":"allow"}' opencode run --format json)
      [[ -n "$OPENCODE_MODEL" ]] && cmd+=(--model "$OPENCODE_MODEL")
      cmd+=("$prompt")
      ;;
    cursor)
      cmd=(agent --print --force --output-format stream-json "$prompt")
      ;;
    codex)
      cmd=(codex exec --full-auto --json "$prompt")
      ;;
    *)
      cmd=(claude --dangerously-skip-permissions --verbose -p "$prompt" --output-format stream-json)
      ;;
  esac

  run_cmd() {
    if [[ -n "$tee_file" ]]; then
      if [[ -n "$log_file" ]]; then
        "${cmd[@]}" 2>>"$log_file" | tee -a "$tee_file" >"$output_file"
      else
        "${cmd[@]}" 2>&1 | tee -a "$tee_file" >"$output_file"
      fi
      return
    fi

    if [[ -n "$log_file" ]]; then
      "${cmd[@]}" >"$output_file" 2>>"$log_file"
    else
      "${cmd[@]}" >"$output_file"
    fi
  }

  if [[ -n "$working_dir" ]]; then
    if [[ "$async" == true ]]; then
      (cd "$working_dir" && run_cmd) &
      ai_pid=$!
    else
      (cd "$working_dir" && run_cmd)
    fi
  else
    if [[ "$async" == true ]]; then
      run_cmd &
      ai_pid=$!
    else
      run_cmd
    fi
  fi
}

run_ai_command() {
  local prompt=$1
  local output_file=$2
  
  # Special handling for Codex last message file
  if [[ "$AI_ENGINE" == "codex" ]]; then
    CODEX_LAST_MESSAGE_FILE="${output_file}.last"
    rm -f "$CODEX_LAST_MESSAGE_FILE"
  fi
  
  execute_ai_prompt "$prompt" "$output_file" "async"
}

parse_ai_result() {
  local result=$1
  local response=""
  local input_tokens=0
  local output_tokens=0
  local actual_cost="0"
  
  case "$AI_ENGINE" in
    opencode)
      # OpenCode JSON format: uses step_finish for tokens and text events for response
      local step_finish
      step_finish=$(echo "$result" | grep '"type":"step_finish"' | tail -1 || echo "")
      
      if [[ -n "$step_finish" ]]; then
        input_tokens=$(echo "$step_finish" | jq -r '.part.tokens.input // 0' 2>/dev/null || echo "0")
        output_tokens=$(echo "$step_finish" | jq -r '.part.tokens.output // 0' 2>/dev/null || echo "0")
        # OpenCode provides actual cost directly
        actual_cost=$(echo "$step_finish" | jq -r '.part.cost // 0' 2>/dev/null || echo "0")
      fi
      
      # Get text response from text events
      response=$(echo "$result" | grep '"type":"text"' | jq -rs 'map(.part.text // "") | join("")' 2>/dev/null || echo "")
      
      # If no text found, indicate task completed
      if [[ -z "$response" ]]; then
        response="Task completed"
      fi
      ;;
    cursor)
      # Cursor agent: parse stream-json output
      # Cursor doesn't provide token counts, but does provide duration_ms
      
      local result_line
      result_line=$(echo "$result" | grep '"type":"result"' | tail -1)
      
      if [[ -n "$result_line" ]]; then
        response=$(echo "$result_line" | jq -r '.result // "Task completed"' 2>/dev/null || echo "Task completed")
        # Cursor provides duration instead of tokens
        local duration_ms
        duration_ms=$(echo "$result_line" | jq -r '.duration_ms // 0' 2>/dev/null || echo "0")
        # Store duration in output_tokens field for now (we'll handle it specially)
        # Use negative value as marker that this is duration, not tokens
        if [[ "$duration_ms" =~ ^[0-9]+$ ]] && [[ "$duration_ms" -gt 0 ]]; then
          # Encode duration: store as-is, we track separately
          actual_cost="duration:$duration_ms"
        fi
      fi
      
      # Get response from assistant message if result is empty
      if [[ -z "$response" ]] || [[ "$response" == "Task completed" ]]; then
        local assistant_msg
        assistant_msg=$(echo "$result" | grep '"type":"assistant"' | tail -1)
        if [[ -n "$assistant_msg" ]]; then
          response=$(echo "$assistant_msg" | jq -r '.message.content[0].text // .message.content // "Task completed"' 2>/dev/null || echo "Task completed")
        fi
      fi
      
      # Tokens remain 0 for Cursor (not available)
      input_tokens=0
      output_tokens=0
      ;;
    codex)
      if [[ -n "$CODEX_LAST_MESSAGE_FILE" ]] && [[ -f "$CODEX_LAST_MESSAGE_FILE" ]]; then
        response=$(cat "$CODEX_LAST_MESSAGE_FILE" 2>/dev/null || echo "")
        # Codex sometimes prefixes a generic completion line; drop it for readability.
        response=$(printf '%s' "$response" | sed '1{/^Task completed successfully\.[[:space:]]*$/d;}')
      fi
      input_tokens=0
      output_tokens=0
      ;;
    *)
      # Claude Code stream-json parsing
      local result_line
      result_line=$(echo "$result" | grep '"type":"result"' | tail -1)
      
      if [[ -n "$result_line" ]]; then
        response=$(echo "$result_line" | jq -r '.result // "No result text"' 2>/dev/null || echo "Could not parse result")
        input_tokens=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo "0")
        output_tokens=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")
      fi
      ;;
  esac
  
  # Sanitize token counts
  [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
  [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0
  
  echo "$response"
  echo "---TOKENS---"
  echo "$input_tokens"
  echo "$output_tokens"
  echo "$actual_cost"
}

check_for_errors() {
  local result=$1
  
  if echo "$result" | grep -q '"type":"error"'; then
    local error_msg
    error_msg=$(echo "$result" | grep '"type":"error"' | head -1 | jq -r '.error.message // .message // .' 2>/dev/null || echo "Unknown error")
    echo "$error_msg"
    return 1
  fi
  
  return 0
}

# ============================================
# COST CALCULATION
# ============================================

calculate_cost() {
  local input=$1
  local output=$2
  
  if command -v bc &>/dev/null; then
    echo "scale=4; ($input * 0.000003) + ($output * 0.000015)" | bc
  else
    echo "N/A"
  fi
}

# ============================================
# PARALLEL TASK EXECUTION
# ============================================

# Create an isolated worktree for a parallel agent
create_agent_worktree() {
  local task_name="$1"
  local agent_num="$2"
  local branch_name="gralph/agent-${agent_num}-$(slugify "$task_name")"
  local worktree_dir="${WORKTREE_BASE}/agent-${agent_num}"
  
  # Run git commands from original directory
  # All git output goes to stderr so it doesn't interfere with our return value
  (
    cd "$ORIGINAL_DIR" || { echo "Failed to cd to $ORIGINAL_DIR" >&2; exit 1; }
    
    # Prune any stale worktrees first
    git worktree prune >&2 2>/dev/null || true
    
    # Check if branch exists and has a worktree - if so, remove worktree first
    local existing_wt
    existing_wt=$(git worktree list 2>/dev/null | grep "\[$branch_name\]" | awk '{print $1}')
    if [[ -n "$existing_wt" ]]; then
      echo "Removing existing worktree for $branch_name at $existing_wt" >&2
      git worktree remove --force "$existing_wt" >&2 2>/dev/null || true
      git worktree prune >&2 2>/dev/null || true
    fi
    
    # Delete branch if it exists (force)
    git branch -D "$branch_name" >&2 2>/dev/null || true
    
    # Create branch from base
    git branch "$branch_name" "$BASE_BRANCH" >&2 || { echo "Failed to create branch $branch_name from $BASE_BRANCH" >&2; exit 1; }
    
    # Remove existing worktree dir if any
    rm -rf "$worktree_dir" 2>/dev/null || true
    
    # Create worktree
    git worktree add "$worktree_dir" "$branch_name" >&2 || { echo "Failed to create worktree at $worktree_dir" >&2; exit 1; }
  )
  
  # Only output the result - git commands above send their output to stderr
  echo "$worktree_dir|$branch_name"
}

# Cleanup worktree after agent completes
cleanup_agent_worktree() {
  local worktree_dir="$1"
  local branch_name="$2"
  local log_file="${3:-}"
  local dirty=false

  if [[ -d "$worktree_dir" ]]; then
    if git -C "$worktree_dir" status --porcelain 2>/dev/null | grep -q .; then
      dirty=true
    fi
  fi

  if [[ "$dirty" == true ]]; then
    if [[ -n "$log_file" ]]; then
      echo "Worktree left in place due to uncommitted changes: $worktree_dir" >> "$log_file"
    fi
    return 0
  fi
  
  # Run from original directory
  (
    cd "$ORIGINAL_DIR" || exit 1
    git worktree remove -f "$worktree_dir" 2>/dev/null || true
  )
  # Don't delete branch - it may have commits we want to keep/PR
}

# Run a single agent for YAML v1 task (by ID)
run_parallel_agent_yaml_v1() {
  local task_id="$1"
  local agent_num="$2"
  local output_file="$3"
  local status_file="$4"
  local log_file="$5"
  local stream_file="${6:-}"  # Optional: file for streaming output to display progress
  
  local task_title
  task_title=$(get_task_title_by_id_yaml_v1 "$task_id")
  
  
  echo "setting up" > "$status_file"
  echo "Agent $agent_num starting for task: $task_id - $task_title" >> "$log_file"
  echo "[DEBUG] AI_ENGINE=$AI_ENGINE OPENCODE_MODEL=$OPENCODE_MODEL" >> "$log_file"
  
  # Create isolated worktree
  local worktree_info
  worktree_info=$(create_agent_worktree "$task_id" "$agent_num" 2>>"$log_file")
  local worktree_dir="${worktree_info%%|*}"
  local branch_name="${worktree_info##*|}"
  
  
  if [[ ! -d "$worktree_dir" ]]; then
    echo "failed" > "$status_file"
    echo "0 0" > "$output_file"
    return 1
  fi
  
  echo "running" > "$status_file"
  
  # Copy PRD file
  cp "$ORIGINAL_DIR/$PRD_FILE" "$worktree_dir/" 2>/dev/null || true
  touch "$worktree_dir/scripts/gralph/progress.txt"
  
  # Build prompt for this task
  local prompt_base=""
  local prompt_file="$ORIGINAL_DIR/scripts/gralph/prompt.md"
  if [[ -f "$prompt_file" ]]; then
    prompt_base=$(cat "$prompt_file")
  fi

  local touches_list explicit_locks inferred_locks
  touches_list=$(get_task_touches_by_id_yaml_v1 "$task_id" | tr '\n' ',' | sed 's/,$//')
  explicit_locks=$(get_task_locks_by_id_yaml_v1 "$task_id" | tr '\n' ',' | sed 's/,$//')
  inferred_locks=$(infer_locks_from_touches "$task_id" | tr '\n' ',' | sed 's/,$//')
  [[ -z "$touches_list" ]] && touches_list="(none provided)"
  [[ -z "$explicit_locks" ]] && explicit_locks="(none)"
  [[ -z "$inferred_locks" ]] && inferred_locks="(none)"

  local prompt="${prompt_base}

You are working on a specific task. Focus ONLY on this task:

TASK ID: $task_id
TASK: $task_title
DECLARED TOUCHES: $touches_list
EXPLICIT LOCKS (locks/mutex): $explicit_locks
INFERRED LOCKS (from touches): $inferred_locks

Instructions:
1. Implement this specific task completely
2. Write tests if appropriate
3. Update scripts/gralph/progress.txt with what you did
4. Commit your changes with a descriptive message

Do NOT modify PRD.md or tasks.yaml or mark tasks complete - that will be handled separately.
Focus only on implementing: $task_title"

  local tmpfile
  tmpfile=$(mktemp)
  local result="" success=false retry=0
  
  while [[ $retry -lt $MAX_RETRIES ]]; do
    log_debug "Retry $retry, running $AI_ENGINE in $worktree_dir"
    
    # Clear stream file on each retry
    [[ -n "$stream_file" ]] && : > "$stream_file"
    
    # Build options for execute_ai_prompt
    local ai_opts="wd=$worktree_dir log=$log_file"
    [[ -n "$stream_file" ]] && ai_opts="$ai_opts tee=$stream_file"
    
    execute_ai_prompt "$prompt" "$tmpfile" "$ai_opts"
    
    result=$(cat "$tmpfile" 2>/dev/null || echo "")
    if [[ -n "$result" ]]; then
      if check_for_errors "$result" >/dev/null 2>&1; then
        success=true
        break
      fi
    fi
    ((++retry))
    sleep "$RETRY_DELAY"
  done
  
  rm -f "$tmpfile"
  
  if [[ "$success" == true ]]; then
    local commit_count
    commit_count=$(git -C "$worktree_dir" rev-list --count "$BASE_BRANCH"..HEAD 2>/dev/null || echo "0")
    if [[ "$commit_count" -eq 0 ]]; then
      echo "failed" > "$status_file"
      echo "0 0" > "$output_file"
      cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
      return 1
    fi
    
    if [[ "$CREATE_PR" == true ]]; then
      (cd "$worktree_dir" && git push -u origin "$branch_name" 2>>"$log_file" || true)
      gh pr create --base "$BASE_BRANCH" --head "$branch_name" --title "$task_title" \
        --body "Automated: $task_id" ${PR_DRAFT:+--draft} 2>>"$log_file" || true
    fi
    
    # Save task report BEFORE cleanup (while worktree still exists)
    if [[ -n "$ARTIFACTS_DIR" ]]; then
      local changed_files
      changed_files=$(git -C "$worktree_dir" diff --name-only "$BASE_BRANCH"..HEAD 2>/dev/null | tr '\n' ',' | sed 's/,$//')
      
# Read progress notes from worktree
  local progress_notes=""
  if [[ -f "$worktree_dir/scripts/gralph/progress.txt" ]]; then
    progress_notes=$(cat "$worktree_dir/scripts/gralph/progress.txt" 2>/dev/null | tail -50)
  fi
  safe_notes=$(json_escape "$progress_notes")
      
      mkdir -p "$ORIGINAL_DIR/$ARTIFACTS_DIR/reports"
      cat > "$ORIGINAL_DIR/$ARTIFACTS_DIR/reports/$task_id.json" << EOF
{
  "taskId": "$task_id",
  "title": "$safe_title",
  "branch": "$safe_branch",
  "status": "done",
  "commits": $commit_count,
  "changedFiles": "$safe_changed",
  "progressNotes": "$safe_notes",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
      
# Append to main progress.txt
  if [[ -f "$worktree_dir/progress.txt" ]] && [[ -s "$worktree_dir/progress.txt" ]]; then
    echo "" >> "$ORIGINAL_DIR/scripts/gralph/progress.txt"
    echo "### $task_id - $task_title ($(date +%Y-%m-%d))" >> "$ORIGINAL_DIR/scripts/gralph/progress.txt"
    tail -20 "$worktree_dir/progress.txt" >> "$ORIGINAL_DIR/scripts/gralph/progress.txt"
  fi
    fi
    
    echo "done" > "$status_file"
    echo "0 0 $branch_name $task_id" > "$output_file"
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
    return 0
  else
    echo "failed" > "$status_file"
    echo "0 0" > "$output_file"
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
    return 1
  fi
}

# DAG-aware parallel execution for YAML v1
run_parallel_tasks_yaml_v1() {
  stage_banner "Execute"
  log_info "Running DAG-aware parallel execution (max $MAX_PARALLEL agents)..."
  
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE
  
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_FILE CREATE_PR PR_DRAFT OPENCODE_MODEL
  
  # Initialize artifacts
  init_artifacts_dir
  export ARTIFACTS_DIR
  log_info "Artifacts: $ARTIFACTS_DIR"
  
  # Initialize scheduler
  scheduler_init_yaml_v1

  # Reset external failure tracking
  EXTERNAL_FAIL_DETECTED=false
  EXTERNAL_FAIL_REASON=""
  EXTERNAL_FAIL_TASK_ID=""
  
  local pending running
  pending=$(scheduler_count_pending)
  log_info "Tasks: $pending pending"
  
  local completed_branches=()
  local completed_task_ids=()
  local agent_num=0
  
  # Main scheduler loop
  while true; do
    pending=$(scheduler_count_pending)
    running=$(scheduler_count_running)
    
    # Exit conditions
    if [[ "$pending" -eq 0 && "$running" -eq 0 ]]; then
      break
    fi
    
    # Check for deadlock
    if scheduler_check_deadlock; then
      log_error "DEADLOCK: No progress possible"
      echo ""
      echo "${RED}Blocked tasks:${RESET}"
      for id in "${!SCHED_STATE[@]}"; do
        if [[ "${SCHED_STATE[$id]}" == "pending" ]]; then
          local reason
          reason=$(scheduler_explain_block "$id")
          echo "  $id: $reason"
        fi
      done
      return 1
    fi
    
    # Get ready tasks
    local ready_tasks=()
    while IFS= read -r id; do
      [[ -n "$id" ]] && ready_tasks+=("$id")
    done < <(scheduler_get_ready)
    
    # Fill slots up to MAX_PARALLEL
    local slots_available=$((MAX_PARALLEL - running))
    local tasks_to_start=()
    
    for ((i=0; i<${#ready_tasks[@]} && i<slots_available; i++)); do
      tasks_to_start+=("${ready_tasks[$i]}")
    done
    
    if [[ ${#tasks_to_start[@]} -eq 0 && "$running" -gt 0 ]]; then
      # Wait for running tasks
      sleep 0.5
      continue
    fi
    
    if [[ ${#tasks_to_start[@]} -eq 0 ]]; then
      sleep 0.5
      continue
    fi
    
    # Start batch of agents
    echo ""
    echo "${BOLD}Starting ${#tasks_to_start[@]} agent(s)${RESET}"
    
    local batch_pids=()
    local batch_ids=()
    local batch_titles=()
    local batch_agent_nums=()
    local status_files=()
    local output_files=()
    local log_files=()
    local stream_files=()
    
    for task_id in "${tasks_to_start[@]}"; do
      ((++agent_num))
      ((++iteration))
      
      scheduler_start_task "$task_id"
      
      local status_file=$(mktemp)
      local output_file=$(mktemp)
      local log_file=$(mktemp)
      local stream_file=$(mktemp)
      
      status_files+=("$status_file")
      output_files+=("$output_file")
      log_files+=("$log_file")
      stream_files+=("$stream_file")
      batch_ids+=("$task_id")
      batch_agent_nums+=("$agent_num")
      
      local title
      title=$(get_task_title_by_id_yaml_v1 "$task_id")
      batch_titles+=("$title")
      
      # Print initial line for this agent (will be updated in-place)
      printf "  ${CYAN}◉${RESET} Agent %d: %s (%s)\n" "$agent_num" "${title:0:40}" "$task_id"
      
      (run_parallel_agent_yaml_v1 "$task_id" "$agent_num" "$output_file" "$status_file" "$log_file" "$stream_file") &
      local spawned_pid=$!
      batch_pids+=("$spawned_pid")
      
    done

    # Track active batch for potential graceful stop
    ACTIVE_PIDS=("${batch_pids[@]}")
    ACTIVE_TASK_IDS=("${batch_ids[@]}")
    ACTIVE_STATUS_FILES=("${status_files[@]}")
    ACTIVE_LOG_FILES=("${log_files[@]}")
    
    # Wait for this batch with progress - show each agent on its own line
    local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_idx=0
    local start_time=$SECONDS
    local num_agents=${#batch_pids[@]}
    # Fixed width for clean line overwrite (avoids flicker from clearing)
    local line_width=78
    
    # Print initial status lines for each agent
    for ((j=0; j<num_agents; j++)); do
      printf "  ${DIM}○${RESET} Agent %d: ${DIM}Initializing...${RESET}\n" "${batch_agent_nums[$j]}"
    done
    
    # Hide cursor during progress updates to prevent flickering
    printf "\e[?25l"
    
    while true; do
      local all_done=true
      local done_count=0 failed_count=0
      local running_count=0
      
      # Move cursor up to the first agent line
      printf "\033[%dA" "$num_agents"
      
      for ((j=0; j<num_agents; j++)); do
        local status
        status=$(cat "${status_files[$j]}" 2>/dev/null || echo "waiting")
        local pid_alive="no"
        if kill -0 "${batch_pids[$j]}" 2>/dev/null; then
          pid_alive="yes"
        fi
        
        local agent_n="${batch_agent_nums[$j]}"
        local disp_title="${batch_titles[$j]}"
        local disp_task_id="${batch_ids[$j]}"
        local elapsed=$((SECONDS - start_time))
        local spinner_char="${spinner_chars:$spin_idx:1}"
        local line=""
        
        case "$status" in
          done)
            done_count=$((done_count + 1))
            line=$(printf "  ${GREEN}✓${RESET} Agent %d: ${DIM}%s${RESET} (%s) ${GREEN}done${RESET}" "$agent_n" "${disp_title:0:35}" "$disp_task_id")
            ;;
          failed)
            failed_count=$((failed_count + 1))
            line=$(printf "  ${RED}✗${RESET} Agent %d: ${DIM}%s${RESET} (%s) ${RED}failed${RESET}" "$agent_n" "${disp_title:0:35}" "$disp_task_id")
            ;;
          running)
            running_count=$((running_count + 1))
            if [[ "$pid_alive" == "yes" ]]; then
              all_done=false
            fi
            local step
            step=$(get_agent_current_step "${stream_files[$j]}")
            local step_color
            step_color=$(get_step_color "$step")
            line=$(printf "  ${CYAN}%s${RESET} Agent %d: ${step_color}%-14s${RESET} │ %-30s ${DIM}[%02d:%02d]${RESET}" \
              "$spinner_char" "$agent_n" "$step" "${disp_title:0:30}" $((elapsed/60)) $((elapsed%60)))
            ;;
          "setting up")
            running_count=$((running_count + 1))
            if [[ "$pid_alive" == "yes" ]]; then
              all_done=false
            fi
            line=$(printf "  ${YELLOW}%s${RESET} Agent %d: ${YELLOW}Setting up${RESET}    │ %-30s ${DIM}[%02d:%02d]${RESET}" \
              "$spinner_char" "$agent_n" "${disp_title:0:30}" $((elapsed/60)) $((elapsed%60)))
            ;;
          *)
            if [[ "$pid_alive" == "yes" ]]; then
              all_done=false
              running_count=$((running_count + 1))
            fi
            line=$(printf "  ${DIM}%s${RESET} Agent %d: ${DIM}Waiting${RESET}        │ %-30s" "$spinner_char" "$agent_n" "${disp_title:0:30}")
            ;;
        esac
        
        # Print line with padding to overwrite any previous content (no flicker)
        printf "\r%-${line_width}s\n" "$line"
      done
      
      if [[ "$all_done" == true ]]; then
        break
      fi
      
      spin_idx=$(((spin_idx+1) % ${#spinner_chars}))
      sleep 0.3
    done
    
    # Restore cursor visibility
    printf "\e[?25h"
    
    # Wait for processes
    for pid in "${batch_pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
    
    # Process results
    for ((j=0; j<${#batch_ids[@]}; j++)); do
      local task_id="${batch_ids[$j]}"
      local log_file="${log_files[$j]}"
      local status
      status=$(cat "${status_files[$j]}" 2>/dev/null || echo "unknown")
      local title
      title=$(get_task_title_by_id_yaml_v1 "$task_id")

      # Persist task log for both done and failed tasks
      persist_task_log "$task_id" "$log_file"
      
      if [[ "$status" == "done" ]]; then
        scheduler_complete_task "$task_id"
        local branch
        branch=$(awk '{print $3}' "${output_files[$j]}" 2>/dev/null)
        [[ -n "$branch" ]] && completed_branches+=("$branch")
        completed_task_ids+=("$task_id")
        
        # Note: task report is now saved by the agent before cleanup
        
        printf "  ${GREEN}✓${RESET} %s (%s)\n" "${title:0:45}" "$task_id"
      else
        scheduler_fail_task "$task_id"
        printf "  ${RED}✗${RESET} %s (%s)\n" "${title:0:45}" "$task_id"
        # Show last non-DEBUG line as error (if any)
        local err_msg
        err_msg=$(extract_error_from_log "$log_file")
        [[ -n "$err_msg" ]] && echo "${DIM}    Error: ${err_msg}${RESET}"

        local failure_type="unknown"
        if [[ -n "$err_msg" ]]; then
          if is_external_failure_error "$err_msg"; then
            failure_type="external"
          else
            failure_type="internal"
          fi
        fi

        write_failed_task_report "$task_id" "$title" "$err_msg" "$failure_type" ""

        if [[ "$failure_type" == "external" && "$EXTERNAL_FAIL_DETECTED" != true ]]; then
          EXTERNAL_FAIL_DETECTED=true
          EXTERNAL_FAIL_TASK_ID="$task_id"
          EXTERNAL_FAIL_REASON="$err_msg"
        fi
      fi
      
      rm -f "${status_files[$j]}" "${output_files[$j]}" "${log_files[$j]}" "${stream_files[$j]}"
    done

    if [[ "$EXTERNAL_FAIL_DETECTED" == true ]]; then
      log_error "External failure detected: $EXTERNAL_FAIL_TASK_ID - $EXTERNAL_FAIL_REASON"
      print_blocked_tasks
      external_fail_graceful_stop "$EXTERNAL_FAIL_TIMEOUT"
      return 1
    fi

    # Clear active batch trackers
    ACTIVE_PIDS=()
    ACTIVE_TASK_IDS=()
    ACTIVE_STATUS_FILES=()
    ACTIVE_LOG_FILES=()
    
    # Check max iterations
    if [[ $MAX_ITERATIONS -gt 0 && $iteration -ge $MAX_ITERATIONS ]]; then
      log_warn "Reached max iterations ($MAX_ITERATIONS)"
      break
    fi
  done
  
  # Cleanup worktree base
  rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  
  # Merge branches if not using PRs
  if [[ ${#completed_branches[@]} -gt 0 && "$CREATE_PR" != true ]]; then
    stage_banner "Integrate"
    
    # Create integration branch
    create_integration_branch
    
    echo ""
    echo "${BOLD}Merging ${#completed_branches[@]} branch(es) to integration...${RESET}"
    
    local merge_success=true
    for ((i=0; i<${#completed_branches[@]}; i++)); do
      local branch="${completed_branches[$i]}"
      local task_id="${completed_task_ids[$i]:-}"
      
      if merge_branch_with_fallback "$branch" "$task_id"; then
        printf "  ${GREEN}✓${RESET} %s\n" "$branch"
        git branch -d "$branch" >/dev/null 2>&1 || true
      else
        printf "  ${RED}✗${RESET} %s (unresolved conflict)\n" "$branch"
        merge_success=false
      fi
    done
    
    if [[ "$merge_success" == true ]]; then
      # Run reviewer
      if run_reviewer_agent; then
        # Merge integration to base
        echo ""
        log_info "Merging integration to $BASE_BRANCH..."
        git checkout "$BASE_BRANCH" >/dev/null 2>&1
        if git merge --no-edit "$INTEGRATION_BRANCH" >/dev/null 2>&1; then
          log_success "Integration merged to $BASE_BRANCH"
          git branch -d "$INTEGRATION_BRANCH" >/dev/null 2>&1 || true
        else
          log_warn "Merge to base failed, integration branch preserved: $INTEGRATION_BRANCH"
        fi
      else
        # Reviewer found blockers - generate fix tasks
        generate_fix_tasks
        log_warn "Review found issues. Fix tasks added to tasks.yaml"
        log_info "Integration branch preserved: $INTEGRATION_BRANCH"
      fi
    else
      log_warn "Some merges failed. Integration branch preserved: $INTEGRATION_BRANCH"
    fi
  fi
  
  # Show artifacts location
  if [[ -n "$ARTIFACTS_DIR" && -d "$ARTIFACTS_DIR" ]]; then
    echo ""
    log_info "Artifacts saved to: $ARTIFACTS_DIR"
  fi
  
  return 0
}

# ============================================
# SUMMARY
# ============================================

show_summary() {
  echo ""
  echo "${BOLD}============================================${RESET}"
  echo "${GREEN}PRD complete!${RESET} Finished $iteration task(s)."
  echo "${BOLD}============================================${RESET}"
  echo ""
  echo "${BOLD}>>> Cost Summary${RESET}"
  
  # Cursor doesn't provide token usage, but does provide duration
  if [[ "$AI_ENGINE" == "cursor" ]]; then
    echo "${DIM}Token usage not available (Cursor CLI doesn't expose this data)${RESET}"
    if [[ "$total_duration_ms" -gt 0 ]]; then
      local dur_sec=$((total_duration_ms / 1000))
      local dur_min=$((dur_sec / 60))
      local dur_sec_rem=$((dur_sec % 60))
      if [[ "$dur_min" -gt 0 ]]; then
        echo "Total API time: ${dur_min}m ${dur_sec_rem}s"
      else
        echo "Total API time: ${dur_sec}s"
      fi
    fi
  else
    echo "Input tokens:  $total_input_tokens"
    echo "Output tokens: $total_output_tokens"
    echo "Total tokens:  $((total_input_tokens + total_output_tokens))"
    
    # Show actual cost if available (OpenCode provides this), otherwise estimate
    if [[ "$AI_ENGINE" == "opencode" ]] && command -v bc &>/dev/null; then
      local has_actual_cost
      has_actual_cost=$(echo "$total_actual_cost > 0" | bc 2>/dev/null || echo "0")
      if [[ "$has_actual_cost" == "1" ]]; then
        echo "Actual cost:   \$${total_actual_cost}"
      else
        local cost
        cost=$(calculate_cost "$total_input_tokens" "$total_output_tokens")
        echo "Est. cost:     \$$cost"
      fi
    else
      local cost
      cost=$(calculate_cost "$total_input_tokens" "$total_output_tokens")
      echo "Est. cost:     \$$cost"
    fi
  fi
  
  # Show branches if created
  if [[ -n "${task_branches[*]+"${task_branches[*]}"}" ]]; then
    echo ""
    echo "${BOLD}>>> Branches Created${RESET}"
    for branch in "${task_branches[@]}"; do
      echo "  - $branch"
    done
  fi
  
  echo "${BOLD}============================================${RESET}"
}

# ============================================
# MAIN
# ============================================

main() {
  parse_args "$@"

  if [[ "$DRY_RUN" == true ]] && [[ "$MAX_ITERATIONS" -eq 0 ]]; then
    MAX_ITERATIONS=1
  fi
  
  # Set up cleanup trap
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP
  
  # Check requirements
  stage_banner "Prepare"
  check_requirements

  # Ensure we are on a run branch if tasks.yaml defines one
  ensure_run_branch

  # Show banner
  echo "${BOLD}============================================${RESET}"
  echo "${BOLD}GRALPH${RESET} - Running until PRD is complete"
  local engine_display
  case "$AI_ENGINE" in
    opencode) engine_display="${CYAN}OpenCode${RESET}" ;;
    cursor) engine_display="${YELLOW}Cursor Agent${RESET}" ;;
    codex) engine_display="${BLUE}Codex${RESET}" ;;
    *) engine_display="${MAGENTA}Claude Code${RESET}" ;;
  esac
  echo "Engine: $engine_display"
  echo "PRD: ${CYAN}$PRD_ID${RESET} (${PRD_RUN_DIR})"
  
  local mode_parts=()
  [[ "$SKIP_TESTS" == true ]] && mode_parts+=("no-tests")
  [[ "$SKIP_LINT" == true ]] && mode_parts+=("no-lint")
  [[ "$DRY_RUN" == true ]] && mode_parts+=("dry-run")
  [[ "$SEQUENTIAL" == true ]] && mode_parts+=("sequential") || mode_parts+=("parallel:$MAX_PARALLEL")
  [[ "$BRANCH_PER_TASK" == true ]] && mode_parts+=("branch-per-task")
  [[ -n "$RUN_BRANCH" ]] && mode_parts+=("run-branch:$RUN_BRANCH")
  [[ "$CREATE_PR" == true ]] && mode_parts+=("create-pr")
  [[ $MAX_ITERATIONS -gt 0 ]] && mode_parts+=("max:$MAX_ITERATIONS")
  
  if [[ ${#mode_parts[@]} -gt 0 ]]; then
    echo "Mode: ${YELLOW}${mode_parts[*]}${RESET}"
  fi
  echo "${BOLD}============================================${RESET}"

  # Run DAG scheduler (sequential = max 1 parallel)
  if [[ "$SEQUENTIAL" == true ]]; then
    MAX_PARALLEL=1
  fi
  
  local result=0
  run_parallel_tasks_yaml_v1 || result=$?
  
  if [[ "$result" -ne 0 ]]; then
    notify_error "GRALPH stopped due to external failure or deadlock"
    exit "$result"
  fi
  
  show_summary
  notify_done
  exit 0
}

# Run main
main "$@"
