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

VERSION="3.1.0"

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

# Parallel execution
PARALLEL=false
MAX_PARALLEL=3

# PRD source options
PRD_SOURCE="markdown"  # markdown, yaml, github
PRD_FILE="PRD.md"
GITHUB_REPO=""
GITHUB_LABEL=""

# Skills init options
SKILLS_INIT=false
SKILLS_BASE_URL="${GRALPH_SKILLS_BASE_URL:-${RALPH_SKILLS_BASE_URL:-https://raw.githubusercontent.com/frizynn/central-ralph/main/skills}}"

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

# Slugify text for branch names
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-|-$//g' | cut -c1-50
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

# Return candidate skill files to check for existence
get_skill_file_candidates() {
  local engine=$1
  local skill=$2
  local repo_root
  repo_root=$(resolve_repo_root)

  case "$engine" in
    claude)
      echo "$repo_root/.claude/skills/$skill/SKILL.md"
      echo "$HOME/.claude/skills/$skill/SKILL.md"
      ;;
    codex)
      echo "$repo_root/.codex/skills/$skill/SKILL.md"
      echo "$HOME/.codex/skills/$skill/SKILL.md"
      ;;
    opencode)
      echo "$repo_root/.opencode/skill/$skill/SKILL.md"
      echo "$HOME/.config/opencode/skill/$skill/SKILL.md"
      ;;
    cursor)
      echo "$repo_root/.cursor/rules/${skill}.mdc"
      echo "$repo_root/.cursor/commands/${skill}.md"
      ;;
  esac
}

# Pick install target (prefer project path, fallback to user path)
get_skill_install_target() {
  local engine=$1
  local skill=$2
  local repo_root
  repo_root=$(resolve_repo_root)

  local project_target=""
  local user_target=""

  case "$engine" in
    claude)
      project_target="$repo_root/.claude/skills/$skill/SKILL.md"
      user_target="$HOME/.claude/skills/$skill/SKILL.md"
      ;;
    codex)
      project_target="$repo_root/.codex/skills/$skill/SKILL.md"
      user_target="$HOME/.codex/skills/$skill/SKILL.md"
      ;;
    opencode)
      project_target="$repo_root/.opencode/skill/$skill/SKILL.md"
      user_target="$HOME/.config/opencode/skill/$skill/SKILL.md"
      ;;
    cursor)
      project_target="$repo_root/.cursor/rules/${skill}.mdc"
      ;;
  esac

  if [[ -n "$project_target" ]] && ensure_parent_dir_writable "$project_target"; then
    echo "$project_target"
    return 0
  fi

  if [[ -n "$user_target" ]] && ensure_parent_dir_writable "$user_target"; then
    echo "$user_target"
    return 0
  fi

  echo ""
  return 1
}

skill_exists() {
  local engine=$1
  local skill=$2

  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] && return 0
  done < <(get_skill_file_candidates "$engine" "$skill")

  return 1
}

download_skill_content() {
  local skill=$1
  local base_url="${SKILLS_BASE_URL%/}"
  local url="${base_url}/${skill}/SKILL.md"
  local tmpfile
  tmpfile=$(mktemp)
  local repo_root
  repo_root=$(resolve_repo_root)
  local local_skill_path="${repo_root}/skills/${skill}/SKILL.md"

  if command -v curl &>/dev/null; then
    if ! curl -fsSL "$url" -o "$tmpfile"; then
      if [[ -f "$local_skill_path" ]]; then
        cp "$local_skill_path" "$tmpfile"
        log_warn "Falling back to local skill source for '$skill'" >&2
        echo "$tmpfile"
        return 0
      fi
      return 1
    fi
  elif command -v wget &>/dev/null; then
    if ! wget -qO "$tmpfile" "$url"; then
      if [[ -f "$local_skill_path" ]]; then
        cp "$local_skill_path" "$tmpfile"
        log_warn "Falling back to local skill source for '$skill'" >&2
        echo "$tmpfile"
        return 0
      fi
      return 1
    fi
  else
    log_error "Missing downloader: install curl or wget"
    return 1
  fi

  echo "$tmpfile"
}

install_skill_if_missing() {
  local engine=$1
  local skill=$2

  if skill_exists "$engine" "$skill"; then
    log_info "Skill '$skill' already installed for $engine, skipping"
    return 0
  fi

  local target
  target=$(get_skill_install_target "$engine" "$skill")
  if [[ -z "$target" ]]; then
    log_warn "No writable install path for $engine skill '$skill'"
    return 1
  fi

  local tmpfile
  if ! tmpfile=$(download_skill_content "$skill"); then
    log_error "Failed to download skill '$skill' from ${SKILLS_BASE_URL}"
    return 1
  fi

  if mv "$tmpfile" "$target"; then
    log_success "Installed '$skill' for $engine at $target"
    return 0
  fi

  log_error "Failed to install '$skill' for $engine at $target"
  return 1
}

ensure_skills_for_engine() {
  local engine=$1
  local mode=$2
  local skills=("prd" "ralph" "task-metadata" "dag-planner" "parallel-safe-implementation" "merge-integrator" "semantic-reviewer")
  local missing=false

  if [[ "$engine" == "cursor" ]]; then
    log_warn "Cursor skills are not officially supported; installing as rules is best-effort."
  fi

  for skill in "${skills[@]}"; do
    if skill_exists "$engine" "$skill"; then
      log_info "Skill '$skill' found for $engine"
      continue
    fi

    missing=true
    if [[ "$mode" == "install" ]]; then
      install_skill_if_missing "$engine" "$skill" || true
    else
      log_warn "Missing skill '$skill' for $engine (run --init to install)"
    fi
  done

  if [[ "$mode" == "install" ]] && [[ "$missing" == false ]]; then
    log_success "All skills already present for $engine"
  fi
}

# ============================================
# HELP & VERSION
# ============================================

show_help() {
  cat << EOF
${BOLD}GRALPH${RESET} - Autonomous AI Coding Loop (v${VERSION})

${BOLD}USAGE:${RESET}
  ./gralph.sh [options]

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
  --max-iterations N  Stop after N iterations (0 = unlimited)
  --max-retries N     Max retries per task on failure (default: 3)
  --retry-delay N     Seconds between retries (default: 5)
  --external-fail-timeout N  Seconds to wait for running tasks on external failure (default: 300)
  --dry-run           Show what would be done without executing

${BOLD}PARALLEL EXECUTION:${RESET}
  --parallel          Run independent tasks in parallel
  --max-parallel N    Max concurrent tasks (default: 3)

${BOLD}GIT BRANCH OPTIONS:${RESET}
  --branch-per-task   Create a new git branch for each task
  --base-branch NAME  Base branch to create task branches from (default: current)
  --create-pr         Create a pull request after each task (requires gh CLI)
  --draft-pr          Create PRs as drafts

${BOLD}PRD SOURCE OPTIONS:${RESET}
  --prd FILE          PRD file path (default: PRD.md)
  --yaml FILE         Use YAML task file instead of markdown
  --github REPO       Fetch tasks from GitHub issues (e.g., owner/repo)
  --github-label TAG  Filter GitHub issues by label

${BOLD}OTHER OPTIONS:${RESET}
  --init              Install missing skills for the current AI engine and exit
  --skills-url URL    Override skills base URL (default: GitHub raw)
  -v, --verbose       Show debug output
  -h, --help          Show this help
  --version           Show version number

${BOLD}EXAMPLES:${RESET}
  ./gralph.sh                              # Run with Claude Code
  ./gralph.sh --codex                      # Run with Codex CLI
  ./gralph.sh --opencode                   # Run with OpenCode
  ./gralph.sh --opencode --opencode-model openai/gpt-4o  # OpenCode with specific model
  ./gralph.sh --cursor                     # Run with Cursor agent
  ./gralph.sh --branch-per-task --create-pr  # Feature branch workflow
  ./gralph.sh --parallel --max-parallel 4  # Run 4 tasks concurrently
  ./gralph.sh --yaml tasks.yaml            # Use YAML task file
  ./gralph.sh --github owner/repo          # Fetch from GitHub issues

${BOLD}PRD FORMATS:${RESET}
  Markdown (PRD.md):
    - [ ] Task description

  YAML (tasks.yaml):
    tasks:
      - title: Task description
        completed: false
        parallel_group: 1  # Optional: tasks with same group run in parallel

  GitHub Issues:
    Uses open issues from the specified repository

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
      --init)
        SKILLS_INIT=true
        shift
        ;;
      --skills-url)
        SKILLS_BASE_URL="${2:-$SKILLS_BASE_URL}"
        shift 2
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
        PRD_SOURCE="markdown"
        shift 2
        ;;
      --yaml)
        PRD_FILE="${2:-tasks.yaml}"
        PRD_SOURCE="yaml"
        shift 2
        ;;
      --github)
        GITHUB_REPO="${2:-}"
        PRD_SOURCE="github"
        shift 2
        ;;
      --github-label)
        GITHUB_LABEL="${2:-}"
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

  # Check for PRD source
  case "$PRD_SOURCE" in
    markdown)
      if [[ ! -f "$PRD_FILE" ]]; then
        log_error "$PRD_FILE not found in current directory"
        exit 1
      fi
      ;;
    yaml)
      if ! command -v yq &>/dev/null; then
        log_error "yq is required for YAML parsing. Install from https://github.com/mikefarah/yq"
        exit 1
      fi
      
      # Auto-generate tasks.yaml from PRD if it doesn't exist
      if [[ ! -f "$PRD_FILE" ]]; then
        local prd_file
        if prd_file=$(find_prd_file); then
          log_info "Found $prd_file, generating tasks.yaml..."
          if ! run_metadata_agent "$prd_file"; then
            log_error "Failed to generate tasks.yaml from PRD"
            exit 1
          fi
        else
          log_error "$PRD_FILE not found and no PRD.md to convert"
          exit 1
        fi
      fi
      
      # Validate v1 schema if version: 1
      if is_yaml_v1; then
        if ! validate_tasks_yaml_v1; then
          exit 1
        fi
      fi
      ;;
    github)
      if [[ -z "$GITHUB_REPO" ]]; then
        log_error "GitHub repository not specified. Use --github owner/repo"
        exit 1
      fi
      if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) is required. Install from https://cli.github.com/"
        exit 1
      fi
      ;;
  esac

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
  if [[ ! -f "progress.txt" ]]; then
    log_warn "progress.txt not found, creating it..."
    touch progress.txt
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
# TASK SOURCES - MARKDOWN
# ============================================

get_tasks_markdown() {
  grep '^\- \[ \]' "$PRD_FILE" 2>/dev/null | sed 's/^- \[ \] //' || true
}

get_next_task_markdown() {
  grep -m1 '^\- \[ \]' "$PRD_FILE" 2>/dev/null | sed 's/^- \[ \] //' | cut -c1-50 || echo ""
}

count_remaining_markdown() {
  grep -c '^\- \[ \]' "$PRD_FILE" 2>/dev/null || echo "0"
}

count_completed_markdown() {
  grep -c '^\- \[x\]' "$PRD_FILE" 2>/dev/null || echo "0"
}

mark_task_complete_markdown() {
  local task=$1
  # For macOS sed (BRE), we need to:
  # - Escape: [ ] \ . * ^ $ /
  # - NOT escape: { } ( ) + ? | (these are literal in BRE)
  local escaped_task
  escaped_task=$(printf '%s\n' "$task" | sed 's/[[\.*^$/]/\\&/g')
  sed -i.bak "s/^- \[ \] ${escaped_task}/- [x] ${escaped_task}/" "$PRD_FILE"
  rm -f "${PRD_FILE}.bak"
}

# ============================================
# TASK SOURCES - YAML
# ============================================

get_tasks_yaml() {
  yq -r '.tasks[] | select(.completed != true) | .title' "$PRD_FILE" 2>/dev/null || true
}

get_next_task_yaml() {
  yq -r '.tasks[] | select(.completed != true) | .title' "$PRD_FILE" 2>/dev/null | head -1 | cut -c1-50 || echo ""
}

count_remaining_yaml() {
  yq -r '[.tasks[] | select(.completed != true)] | length' "$PRD_FILE" 2>/dev/null || echo "0"
}

count_completed_yaml() {
  yq -r '[.tasks[] | select(.completed == true)] | length' "$PRD_FILE" 2>/dev/null || echo "0"
}

mark_task_complete_yaml() {
  local task=$1
  yq -i "(.tasks[] | select(.title == \"$task\")).completed = true" "$PRD_FILE"
}

get_parallel_group_yaml() {
  local task=$1
  yq -r ".tasks[] | select(.title == \"$task\") | .parallel_group // 0" "$PRD_FILE" 2>/dev/null || echo "0"
}

get_tasks_in_group_yaml() {
  local group=$1
  yq -r ".tasks[] | select(.completed != true and (.parallel_group // 0) == $group) | .title" "$PRD_FILE" 2>/dev/null || true
}

# ============================================
# YAML V1 VALIDATION (DAG + MUTEX)
# ============================================

# Check if tasks.yaml uses v1 format
is_yaml_v1() {
  local version
  version=$(yq -r '.version // 0' "$PRD_FILE" 2>/dev/null)
  [[ "$version" == "1" ]]
}

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

# Get task mutex by ID
get_task_mutex_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .mutex[]?" "$PRD_FILE" 2>/dev/null
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

# Load mutex catalog
load_mutex_catalog() {
  local catalog_file="${ORIGINAL_DIR:-$(pwd)}/mutex-catalog.json"
  if [[ ! -f "$catalog_file" ]]; then
    # Return empty if no catalog (allow any mutex)
    echo ""
    return
  fi
  # Return list of valid mutex names
  jq -r '.mutex | keys[]' "$catalog_file" 2>/dev/null
}

# Check if mutex is valid (in catalog or matches contract:* pattern)
is_valid_mutex() {
  local mutex=$1
  local catalog=$2
  
  # contract:* pattern is always valid
  if [[ "$mutex" == contract:* ]]; then
    return 0
  fi
  
  # Check against catalog
  if [[ -z "$catalog" ]]; then
    # No catalog = allow all
    return 0
  fi
  
  echo "$catalog" | grep -qx "$mutex"
}

# Validate tasks.yaml v1 schema
validate_tasks_yaml_v1() {
  local errors=()
  
  # Check version
  local version
  version=$(yq -r '.version // "missing"' "$PRD_FILE" 2>/dev/null)
  if [[ "$version" != "1" ]]; then
    errors+=("version must be 1 (got: $version)")
  fi
  
  # Load mutex catalog
  local mutex_catalog
  mutex_catalog=$(load_mutex_catalog)
  
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
    
    # Validate mutex
    while IFS= read -r mutex; do
      [[ -z "$mutex" ]] && continue
      if ! is_valid_mutex "$mutex" "$mutex_catalog"; then
        errors+=("Task $id: unknown mutex '$mutex'")
      fi
    done < <(yq -r ".tasks[$i].mutex[]?" "$PRD_FILE" 2>/dev/null)
  done
  
  # Check for cycles
  local cycle_path
  cycle_path=$(detect_cycles_yaml_v1)
  if [[ -n "$cycle_path" ]]; then
    errors+=("Cycle detected: $cycle_path")
  fi
  
  # Report errors
  if [[ ${#errors[@]} -gt 0 ]]; then
    log_error "tasks.yaml v1 validation failed:"
    for err in "${errors[@]}"; do
      echo "  - $err" >&2
    done
    return 1
  fi
  
  log_success "tasks.yaml v1 valid (${#all_ids[@]} tasks)"
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
declare -A SCHED_LOCKED     # mutex -> task_id (who holds it)

# Initialize scheduler state
scheduler_init_yaml_v1() {
  SCHED_STATE=()
  SCHED_LOCKED=()
  
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

# Check if task can acquire its mutex
scheduler_mutex_available() {
  local id=$1
  while IFS= read -r mutex; do
    [[ -z "$mutex" ]] && continue
    # Use :- to provide default empty value (fixes set -u unbound variable)
    if [[ -n "${SCHED_LOCKED[$mutex]:-}" ]]; then
      return 1
    fi
  done < <(get_task_mutex_by_id_yaml_v1 "$id")
  return 0
}

# Lock mutex for a task
scheduler_lock_mutex() {
  local id=$1
  while IFS= read -r mutex; do
    [[ -z "$mutex" ]] && continue
    SCHED_LOCKED[$mutex]=$id
  done < <(get_task_mutex_by_id_yaml_v1 "$id")
}

# Unlock mutex for a task
scheduler_unlock_mutex() {
  local id=$1
  while IFS= read -r mutex; do
    [[ -z "$mutex" ]] && continue
    unset "SCHED_LOCKED[$mutex]"
  done < <(get_task_mutex_by_id_yaml_v1 "$id")
}

# Get ready tasks (deps satisfied and mutex available)
scheduler_get_ready() {
  local ready=()
  for id in "${!SCHED_STATE[@]}"; do
    if [[ "${SCHED_STATE[$id]}" == "pending" ]]; then
      if scheduler_deps_satisfied "$id" && scheduler_mutex_available "$id"; then
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
  scheduler_lock_mutex "$id"
  log_debug "Task $id: pending → running (mutex locked)"
}

# Mark task as done
scheduler_complete_task() {
  local id=$1
  SCHED_STATE[$id]="done"
  scheduler_unlock_mutex "$id"
  mark_task_complete_by_id_yaml_v1 "$id"
  log_debug "Task $id: running → done (mutex released)"
}

# Mark task as failed
scheduler_fail_task() {
  local id=$1
  SCHED_STATE[$id]="failed"
  scheduler_unlock_mutex "$id"
  log_debug "Task $id: running → failed (mutex released)"
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
  
  # Check mutex
  local blocked_mutex=()
  while IFS= read -r mutex; do
    [[ -z "$mutex" ]] && continue
    # Use :- to provide default empty value (fixes set -u unbound variable)
    if [[ -n "${SCHED_LOCKED[$mutex]:-}" ]]; then
      blocked_mutex+=("$mutex (held by ${SCHED_LOCKED[$mutex]:-})")
    fi
  done < <(get_task_mutex_by_id_yaml_v1 "$id")
  
  if [[ ${#blocked_mutex[@]} -gt 0 ]]; then
    reasons+=("mutex: ${blocked_mutex[*]}")
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
# PIPELINE AGENTS (PRD → TASKS → RUN → REVIEW)
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
# STAGE 0: PRD → tasks.yaml (Metadata Agent)
# ============================================

run_metadata_agent() {
  local prd_file=$1
  local output_file="tasks.yaml"
  
  log_info "Generating tasks.yaml from $prd_file..."
  
  local prompt="Read the PRD file and convert it to tasks.yaml v1 format.

@$prd_file

Create a tasks.yaml file with this EXACT format:

version: 1
tasks:
  - id: TASK-001
    title: \"First task description\"
    completed: false
    dependsOn: []
    mutex: []
  - id: TASK-002
    title: \"Second task description\"  
    completed: false
    dependsOn: [\"TASK-001\"]
    mutex: []

Rules:
1. Each task gets a unique ID (TASK-001, TASK-002, etc.)
2. Order tasks by dependency (database first, then backend, then frontend)
3. Use dependsOn to link tasks that must run after others
4. Use mutex for shared resources: db-migrations, lockfile, router, global-config
5. Keep tasks small and focused (completable in one session)

Save the file as tasks.yaml in the current directory.
Do NOT implement anything - only create the tasks.yaml file."

  local tmpfile
  tmpfile=$(mktemp)
  
  execute_ai_prompt "$prompt" "$tmpfile"
  
  rm -f "$tmpfile"
  
  if [[ ! -f "$output_file" ]]; then
    log_error "Metadata agent failed to create tasks.yaml"
    return 1
  fi
  
  log_success "Generated tasks.yaml"
  return 0
}

# ============================================
# STAGE 2: Task Reports
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
# STAGE 3: Integration Branch + Merge Agent
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
  
  local prompt="Resolve git merge conflicts in these files:

$conflicted_files

Merge notes from task: $merge_notes

For each file:
1. Read the conflict markers (<<<<<<< HEAD, =======, >>>>>>>)
2. Combine BOTH changes intelligently
3. Remove all conflict markers
4. Ensure valid syntax

Then run:
git add <files>
git commit --no-edit"

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
# STAGE 5: Semantic Reviewer
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
  
  local prompt="Review the integrated code changes for issues.

Diff summary:
$diff_summary

Task reports:
$reports_summary

Check for:
1. Type mismatches between modules
2. Broken imports or references
3. Inconsistent patterns (error handling, naming)
4. Missing exports

Create a file review-report.json with this format:
{
  \"issues\": [
    {\"severity\": \"blocker|critical|warning\", \"file\": \"path\", \"description\": \"...\", \"suggestedFix\": \"...\"}
  ],
  \"summary\": \"Brief overall assessment\"
}

If no issues found, create an empty issues array.
Save to $ARTIFACTS_DIR/review-report.json"

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
      \"mutex\": []
    }]" "$PRD_FILE"
    
    fix_num=$((fix_num + 1))
  done
  
  log_success "Added fix tasks"
}

# ============================================
# TASK SOURCES - GITHUB ISSUES
# ============================================

get_tasks_github() {
  local args=(--repo "$GITHUB_REPO" --state open --json number,title)
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq '.[] | "\(.number):\(.title)"' 2>/dev/null || true
}

get_next_task_github() {
  local args=(--repo "$GITHUB_REPO" --state open --limit 1 --json number,title)
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq '.[0] | "\(.number):\(.title)"' 2>/dev/null | cut -c1-50 || echo ""
}

count_remaining_github() {
  local args=(--repo "$GITHUB_REPO" --state open --json number)
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq 'length' 2>/dev/null || echo "0"
}

count_completed_github() {
  local args=(--repo "$GITHUB_REPO" --state closed --json number)
  [[ -n "$GITHUB_LABEL" ]] && args+=(--label "$GITHUB_LABEL")

  gh issue list "${args[@]}" \
    --jq 'length' 2>/dev/null || echo "0"
}

mark_task_complete_github() {
  local task=$1
  # Extract issue number from "number:title" format
  local issue_num="${task%%:*}"
  gh issue close "$issue_num" --repo "$GITHUB_REPO" 2>/dev/null || true
}

get_github_issue_body() {
  local task=$1
  local issue_num="${task%%:*}"
  gh issue view "$issue_num" --repo "$GITHUB_REPO" --json body --jq '.body' 2>/dev/null || echo ""
}

# ============================================
# UNIFIED TASK INTERFACE
# ============================================

get_next_task() {
  case "$PRD_SOURCE" in
    markdown) get_next_task_markdown ;;
    yaml) get_next_task_yaml ;;
    github) get_next_task_github ;;
  esac
}

get_all_tasks() {
  case "$PRD_SOURCE" in
    markdown) get_tasks_markdown ;;
    yaml) get_tasks_yaml ;;
    github) get_tasks_github ;;
  esac
}

count_remaining_tasks() {
  case "$PRD_SOURCE" in
    markdown) count_remaining_markdown ;;
    yaml) count_remaining_yaml ;;
    github) count_remaining_github ;;
  esac
}

count_completed_tasks() {
  case "$PRD_SOURCE" in
    markdown) count_completed_markdown ;;
    yaml) count_completed_yaml ;;
    github) count_completed_github ;;
  esac
}

mark_task_complete() {
  local task=$1
  case "$PRD_SOURCE" in
    markdown) mark_task_complete_markdown "$task" ;;
    yaml) mark_task_complete_yaml "$task" ;;
    github) mark_task_complete_github "$task" ;;
  esac
}

# ============================================
# GIT BRANCH MANAGEMENT
# ============================================

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
# PROMPT BUILDER
# ============================================

build_prompt() {
  local task_override="${1:-}"
  local prompt=""
  
  # Add context based on PRD source
  case "$PRD_SOURCE" in
    markdown)
      prompt="@${PRD_FILE} @progress.txt"
      ;;
    yaml)
      prompt="@${PRD_FILE} @progress.txt"
      ;;
    github)
      # For GitHub issues, we include the issue body
      local issue_body=""
      if [[ -n "$task_override" ]]; then
        issue_body=$(get_github_issue_body "$task_override")
      fi
      prompt="Task from GitHub Issue: $task_override

Issue Description:
$issue_body

@progress.txt"
      ;;
  esac
  
  prompt="$prompt
1. Find the highest-priority incomplete task and implement it."

  local step=2
  
  if [[ "$SKIP_TESTS" == false ]]; then
    prompt="$prompt
$step. Write tests for the feature.
$((step+1)). Run tests and ensure they pass before proceeding."
    step=$((step+2))
  fi

  if [[ "$SKIP_LINT" == false ]]; then
    prompt="$prompt
$step. Run linting and ensure it passes before proceeding."
    step=$((step+1))
  fi

  # Adjust completion step based on PRD source
  case "$PRD_SOURCE" in
    markdown)
      prompt="$prompt
$step. Update the PRD to mark the task as complete (change '- [ ]' to '- [x]')."
      ;;
    yaml)
      prompt="$prompt
$step. Update ${PRD_FILE} to mark the task as completed (set completed: true)."
      ;;
    github)
      prompt="$prompt
$step. The task will be marked complete automatically. Just note the completion in progress.txt."
      ;;
  esac
  
  step=$((step+1))
  
  prompt="$prompt
$step. Append your progress to progress.txt.
$((step+1)). Commit your changes with a descriptive message.
ONLY WORK ON A SINGLE TASK."

  if [[ "$SKIP_TESTS" == false ]]; then
    prompt="$prompt Do not proceed if tests fail."
  fi
  if [[ "$SKIP_LINT" == false ]]; then
    prompt="$prompt Do not proceed if linting fails."
  fi

  prompt="$prompt
If ALL tasks in the PRD are complete, output <promise>COMPLETE</promise>."

  echo "$prompt"
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
# SINGLE TASK EXECUTION
# ============================================

run_single_task() {
  local task_name="${1:-}"
  local task_num="${2:-$iteration}"
  
  retry_count=0
  
  echo ""
  echo "${BOLD}>>> Task $task_num${RESET}"
  
  local remaining completed
  remaining=$(count_remaining_tasks | tr -d '[:space:]')
  completed=$(count_completed_tasks | tr -d '[:space:]')
  remaining=${remaining:-0}
  completed=${completed:-0}
  echo "${DIM}    Completed: $completed | Remaining: $remaining${RESET}"
  echo "--------------------------------------------"

  # Get current task for display
  local current_task
  if [[ -n "$task_name" ]]; then
    current_task="$task_name"
  else
    current_task=$(get_next_task)
  fi
  
  if [[ -z "$current_task" ]]; then
    log_info "No more tasks found"
    return 2
  fi
  
  current_step="Thinking"

  # Create branch if needed
  local branch_name=""
  if [[ "$BRANCH_PER_TASK" == true ]]; then
    branch_name=$(create_task_branch "$current_task")
    log_info "Working on branch: $branch_name"
  fi

  # Temp file for AI output
  tmpfile=$(mktemp)

  # Build the prompt
  local prompt
  prompt=$(build_prompt "$current_task")

  if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN - Would execute:"
    echo "${DIM}$prompt${RESET}"
    rm -f "$tmpfile"
    tmpfile=""
    return_to_base_branch
    return 0
  fi

  # Run with retry logic
  while [[ $retry_count -lt $MAX_RETRIES ]]; do
    # Start AI command
    run_ai_command "$prompt" "$tmpfile"

    # Start progress monitor in background
    monitor_progress "$tmpfile" "${current_task:0:40}" &
    monitor_pid=$!

    # Wait for AI to finish
    wait "$ai_pid" 2>/dev/null || true

    # Stop the monitor
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    monitor_pid=""

    # Show completion
    tput cr 2>/dev/null || printf "\r"
    tput el 2>/dev/null || true

    # Read result
    local result
    result=$(cat "$tmpfile" 2>/dev/null || echo "")

    # Check for empty response
    if [[ -z "$result" ]]; then
      ((++retry_count))
      log_error "Empty response (attempt $retry_count/$MAX_RETRIES)"
      if [[ $retry_count -lt $MAX_RETRIES ]]; then
        log_info "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        continue
      fi
      rm -f "$tmpfile"
      tmpfile=""
      return_to_base_branch
      return 1
    fi

    # Check for API errors
    local error_msg
    if ! error_msg=$(check_for_errors "$result"); then
      ((++retry_count))
      log_error "API error: $error_msg (attempt $retry_count/$MAX_RETRIES)"
      if [[ $retry_count -lt $MAX_RETRIES ]]; then
        log_info "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        continue
      fi
      rm -f "$tmpfile"
      tmpfile=""
      return_to_base_branch
      return 1
    fi

    # Parse the result
    local parsed
    parsed=$(parse_ai_result "$result")
    local response
    response=$(echo "$parsed" | sed '/^---TOKENS---$/,$d')
    local token_data
    token_data=$(echo "$parsed" | sed -n '/^---TOKENS---$/,$p' | tail -3)
    local input_tokens
    input_tokens=$(echo "$token_data" | sed -n '1p')
    local output_tokens
    output_tokens=$(echo "$token_data" | sed -n '2p')
    local actual_cost
    actual_cost=$(echo "$token_data" | sed -n '3p')

    printf "  ${GREEN}✓${RESET} %-16s │ %s\n" "Done" "${current_task:0:40}"
    
    if [[ -n "$response" ]]; then
      echo ""
      echo "$response"
    fi

    # Sanitize values
    [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0

    # Update totals
    total_input_tokens=$((total_input_tokens + input_tokens))
    total_output_tokens=$((total_output_tokens + output_tokens))
    
    # Track actual cost for OpenCode, or duration for Cursor
    if [[ -n "$actual_cost" ]]; then
      if [[ "$actual_cost" == duration:* ]]; then
        # Cursor duration tracking
        local dur_ms="${actual_cost#duration:}"
        [[ "$dur_ms" =~ ^[0-9]+$ ]] && total_duration_ms=$((total_duration_ms + dur_ms))
      elif [[ "$actual_cost" != "0" ]] && command -v bc &>/dev/null; then
        # OpenCode cost tracking
        total_actual_cost=$(echo "scale=6; $total_actual_cost + $actual_cost" | bc 2>/dev/null || echo "$total_actual_cost")
      fi
    fi

    rm -f "$tmpfile"
    tmpfile=""
    if [[ "$AI_ENGINE" == "codex" ]] && [[ -n "$CODEX_LAST_MESSAGE_FILE" ]]; then
      rm -f "$CODEX_LAST_MESSAGE_FILE"
      CODEX_LAST_MESSAGE_FILE=""
    fi

    # Mark task complete for GitHub issues (since AI can't do it)
    if [[ "$PRD_SOURCE" == "github" ]]; then
      mark_task_complete "$current_task"
    fi

    # Create PR if requested
    if [[ "$CREATE_PR" == true ]] && [[ -n "$branch_name" ]]; then
      create_pull_request "$branch_name" "$current_task" "Automated implementation by GRALPH"
    fi

    # Return to base branch
    return_to_base_branch

    # Check for completion - verify by actually counting remaining tasks
    local remaining_count
    remaining_count=$(count_remaining_tasks | tr -d '[:space:]' | head -1)
    remaining_count=${remaining_count:-0}
    [[ "$remaining_count" =~ ^[0-9]+$ ]] || remaining_count=0
    
    if [[ "$remaining_count" -eq 0 ]]; then
      return 2  # All tasks actually complete
    fi
    
    # AI might claim completion but tasks remain - continue anyway
    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
      log_debug "AI claimed completion but $remaining_count tasks remain, continuing..."
    fi

    return 0
  done

  return_to_base_branch
  return 1
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

# Run a single agent in its own isolated worktree
run_parallel_agent() {
  local task_name="$1"
  local agent_num="$2"
  local output_file="$3"
  local status_file="$4"
  local log_file="$5"
  local stream_file="${6:-}"  # Optional: file for streaming output to display progress
  
  echo "setting up" > "$status_file"
  
  # Log setup info
  echo "Agent $agent_num starting for task: $task_name" >> "$log_file"
  echo "ORIGINAL_DIR=$ORIGINAL_DIR" >> "$log_file"
  echo "WORKTREE_BASE=$WORKTREE_BASE" >> "$log_file"
  echo "BASE_BRANCH=$BASE_BRANCH" >> "$log_file"
  
  # Create isolated worktree for this agent
  local worktree_info
  worktree_info=$(create_agent_worktree "$task_name" "$agent_num" 2>>"$log_file")
  local worktree_dir="${worktree_info%%|*}"
  local branch_name="${worktree_info##*|}"
  
  echo "Worktree dir: $worktree_dir" >> "$log_file"
  echo "Branch name: $branch_name" >> "$log_file"
  
  if [[ ! -d "$worktree_dir" ]]; then
    echo "failed" > "$status_file"
    echo "ERROR: Worktree directory does not exist: $worktree_dir" >> "$log_file"
    echo "0 0" > "$output_file"
    return 1
  fi
  
  echo "running" > "$status_file"
  
  # Copy PRD file to worktree from original directory
  if [[ "$PRD_SOURCE" == "markdown" ]] || [[ "$PRD_SOURCE" == "yaml" ]]; then
    cp "$ORIGINAL_DIR/$PRD_FILE" "$worktree_dir/" 2>/dev/null || true
  fi
  
  # Ensure progress.txt exists in worktree
  touch "$worktree_dir/progress.txt"
  
  # Build prompt for this specific task
  local prompt="You are working on a specific task. Focus ONLY on this task:

TASK: $task_name

Instructions:
1. Implement this specific task completely
2. Write tests if appropriate
3. Update progress.txt with what you did
4. Commit your changes with a descriptive message

Do NOT modify PRD.md or mark tasks complete - that will be handled separately.
Focus only on implementing: $task_name"

  # Temp file for AI output
  local tmpfile
  tmpfile=$(mktemp)
  
  # Run AI agent in the worktree directory
  local result=""
  local success=false
  local retry=0
  
  while [[ $retry -lt $MAX_RETRIES ]]; do
    # Clear stream file on each retry
    [[ -n "$stream_file" ]] && : > "$stream_file"
    
    # Build options for execute_ai_prompt
    local ai_opts="wd=$worktree_dir log=$log_file"
    [[ -n "$stream_file" ]] && ai_opts="$ai_opts tee=$stream_file"
    
    execute_ai_prompt "$prompt" "$tmpfile" "$ai_opts"
    
    result=$(cat "$tmpfile" 2>/dev/null || echo "")
    
    if [[ -n "$result" ]]; then
      local error_msg
      if ! error_msg=$(check_for_errors "$result"); then
        ((++retry))
        echo "API error: $error_msg (attempt $retry/$MAX_RETRIES)" >> "$log_file"
        sleep "$RETRY_DELAY"
        continue
      fi
      success=true
      break
    fi
    
    ((++retry))
    echo "Retry $retry/$MAX_RETRIES after empty response" >> "$log_file"
    sleep "$RETRY_DELAY"
  done
  
  rm -f "$tmpfile"
  
  if [[ "$success" == true ]]; then
    # Parse tokens
    local parsed input_tokens output_tokens
    local CODEX_LAST_MESSAGE_FILE="${tmpfile}.last"
    parsed=$(parse_ai_result "$result")
    local token_data
    token_data=$(echo "$parsed" | sed -n '/^---TOKENS---$/,$p' | tail -3)
    input_tokens=$(echo "$token_data" | sed -n '1p')
    output_tokens=$(echo "$token_data" | sed -n '2p')
    [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0
    rm -f "${tmpfile}.last"

    # Ensure at least one commit exists before marking success
    local commit_count
    commit_count=$(git -C "$worktree_dir" rev-list --count "$BASE_BRANCH"..HEAD 2>/dev/null || echo "0")
    [[ "$commit_count" =~ ^[0-9]+$ ]] || commit_count=0
    if [[ "$commit_count" -eq 0 ]]; then
      echo "ERROR: No new commits created; treating task as failed." >> "$log_file"
      echo "failed" > "$status_file"
      echo "0 0" > "$output_file"
      cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
      return 1
    fi
    
    # Create PR if requested
    if [[ "$CREATE_PR" == true ]]; then
      (
        cd "$worktree_dir"
        git push -u origin "$branch_name" 2>>"$log_file" || true
        gh pr create \
          --base "$BASE_BRANCH" \
          --head "$branch_name" \
          --title "$task_name" \
          --body "Automated implementation by GRALPH (Agent $agent_num)" \
          ${PR_DRAFT:+--draft} 2>>"$log_file" || true
      )
    fi
    
    # Save task report BEFORE cleanup (while worktree still exists)
    if [[ -n "$ARTIFACTS_DIR" ]]; then
      local changed_files
      changed_files=$(git -C "$worktree_dir" diff --name-only "$BASE_BRANCH"..HEAD 2>/dev/null | tr '\n' ',' | sed 's/,$//')
      
      # Read progress notes from worktree
      local progress_notes=""
      if [[ -f "$worktree_dir/progress.txt" ]]; then
        progress_notes=$(cat "$worktree_dir/progress.txt" 2>/dev/null | tail -50)
      fi
      
      local task_id_slug
      task_id_slug=$(echo "$task_name" | sed 's/[^a-zA-Z0-9]/-/g' | cut -c1-30)
      
      # Escape strings for valid JSON
      local safe_title safe_branch safe_changed safe_notes
      safe_title=$(json_escape "$task_name")
      safe_branch=$(json_escape "$branch_name")
      safe_changed=$(json_escape "$changed_files")
      safe_notes=$(json_escape "$progress_notes")
      
      mkdir -p "$ORIGINAL_DIR/$ARTIFACTS_DIR/reports"
      cat > "$ORIGINAL_DIR/$ARTIFACTS_DIR/reports/agent-${agent_num}-${task_id_slug}.json" << EOF
{
  "taskId": "agent-$agent_num",
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
        echo "" >> "$ORIGINAL_DIR/progress.txt"
        echo "### Agent $agent_num - $task_name ($(date +%Y-%m-%d))" >> "$ORIGINAL_DIR/progress.txt"
        tail -20 "$worktree_dir/progress.txt" >> "$ORIGINAL_DIR/progress.txt"
      fi
    fi
    
    # Write success output
    echo "done" > "$status_file"
    echo "$input_tokens $output_tokens $branch_name" > "$output_file"
    
    # Cleanup worktree (but keep branch)
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
    
    return 0
  else
    echo "failed" > "$status_file"
    echo "0 0" > "$output_file"
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
    return 1
  fi
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
  touch "$worktree_dir/progress.txt"
  
  # Build prompt for this task
  local prompt="You are working on a specific task. Focus ONLY on this task:

TASK ID: $task_id
TASK: $task_title

Instructions:
1. Implement this specific task completely
2. Write tests if appropriate
3. Update progress.txt with what you did
4. Commit your changes with a descriptive message

Do NOT modify tasks.yaml or mark tasks complete - that will be handled separately.
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
      if [[ -f "$worktree_dir/progress.txt" ]]; then
        progress_notes=$(cat "$worktree_dir/progress.txt" 2>/dev/null | tail -50)
      fi
      
      # Escape strings for valid JSON
      local safe_title safe_branch safe_changed safe_notes
      safe_title=$(json_escape "$task_title")
      safe_branch=$(json_escape "$branch_name")
      safe_changed=$(json_escape "$changed_files")
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
        echo "" >> "$ORIGINAL_DIR/progress.txt"
        echo "### $task_id - $task_title ($(date +%Y-%m-%d))" >> "$ORIGINAL_DIR/progress.txt"
        tail -20 "$worktree_dir/progress.txt" >> "$ORIGINAL_DIR/progress.txt"
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
  log_info "Running DAG-aware parallel execution (max $MAX_PARALLEL agents)..."
  
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE
  
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT OPENCODE_MODEL
  
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
    echo ""
    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo "${BOLD}Integration Phase${RESET}"
    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
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
      echo ""
      echo "${BOLD}Review Phase${RESET}"
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

run_parallel_tasks() {
  log_info "Running ${BOLD}$MAX_PARALLEL parallel agents${RESET} (each in isolated worktree)..."
  
  local all_tasks=()
  
  # Get all pending tasks
  while IFS= read -r task; do
    [[ -n "$task" ]] && all_tasks+=("$task")
  done < <(get_all_tasks)
  
  if [[ ${#all_tasks[@]} -eq 0 ]]; then
    log_info "No tasks to run"
    return 2
  fi
  
  local total_tasks=${#all_tasks[@]}
  log_info "Found $total_tasks tasks to process"
  
  # Store original directory for git operations from subshells
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR
  
  # Set up worktree base directory
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE
  log_debug "Worktree base: $WORKTREE_BASE"
  
  # Ensure we have a base branch set
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH
  log_info "Base branch: $BASE_BRANCH"
  
  # Export variables needed by subshell agents
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT OPENCODE_MODEL
  
  local batch_num=0
  local completed_branches=()
  local groups=("all")

  if [[ "$PRD_SOURCE" == "yaml" ]]; then
    groups=()
    while IFS= read -r group; do
      [[ -n "$group" ]] && groups+=("$group")
    done < <(yq -r '.tasks[] | select(.completed != true) | (.parallel_group // 0)' "$PRD_FILE" 2>/dev/null | sort -n | uniq)
  fi

  for group in "${groups[@]}"; do
    local tasks=()
    local group_label=""

    if [[ "$PRD_SOURCE" == "yaml" ]]; then
      while IFS= read -r task; do
        [[ -n "$task" ]] && tasks+=("$task")
      done < <(get_tasks_in_group_yaml "$group")
      [[ ${#tasks[@]} -eq 0 ]] && continue
      group_label=" (group $group)"
    else
      tasks=("${all_tasks[@]}")
    fi

    local batch_start=0
    local total_group_tasks=${#tasks[@]}

    while [[ $batch_start -lt $total_group_tasks ]]; do
      ((++batch_num))
      local batch_end=$((batch_start + MAX_PARALLEL))
      [[ $batch_end -gt $total_group_tasks ]] && batch_end=$total_group_tasks
      local batch_size=$((batch_end - batch_start))

      echo ""
      echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
      echo "${BOLD}Batch $batch_num${group_label}: Spawning $batch_size parallel agents${RESET}"
      echo "${DIM}Each agent runs in its own git worktree with isolated workspace${RESET}"
      echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
      echo ""

      # Setup arrays for this batch
      parallel_pids=()
      local batch_tasks=()
      local batch_agent_nums=()
      local status_files=()
      local output_files=()
      local log_files=()
      local stream_files=()

      # Start all agents in the batch
      for ((i = batch_start; i < batch_end; i++)); do
        local task="${tasks[$i]}"
        local agent_num=$((iteration + 1))
        ((++iteration))

        local status_file=$(mktemp)
        local output_file=$(mktemp)
        local log_file=$(mktemp)
        local stream_file=$(mktemp)

        batch_tasks+=("$task")
        batch_agent_nums+=("$agent_num")
        status_files+=("$status_file")
        output_files+=("$output_file")
        log_files+=("$log_file")
        stream_files+=("$stream_file")

        echo "waiting" > "$status_file"

        # Show initial status
        printf "  ${CYAN}◉${RESET} Agent %d: %s\n" "$agent_num" "${task:0:50}"

        # Run agent in background
        (
          run_parallel_agent "$task" "$agent_num" "$output_file" "$status_file" "$log_file" "$stream_file"
        ) &
        parallel_pids+=($!)
      done

      # Print initial status lines for each agent
      for ((j=0; j<batch_size; j++)); do
        printf "  ${DIM}○${RESET} Agent %d: ${DIM}Initializing...${RESET}\n" "${batch_agent_nums[$j]}"
      done
      
      # Fixed width for clean line overwrite (avoids flicker)
      local line_width=78

      # Monitor progress with a spinner - show each agent on its own line
      local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
      local spin_idx=0
      local start_time=$SECONDS

      # Hide cursor during progress updates to prevent flickering
      printf "\e[?25l"

      while true; do
        # Check if all processes are done
        local all_done=true
        local done_count=0
        local failed_count=0

        # Move cursor up to the first agent line
        printf "\033[%dA" "$batch_size"

        for ((j = 0; j < batch_size; j++)); do
          local pid="${parallel_pids[$j]}"
          local status=$(cat "${status_files[$j]}" 2>/dev/null || echo "waiting")
          local task="${batch_tasks[$j]}"
          local agent_n="${batch_agent_nums[$j]}"
          local elapsed=$((SECONDS - start_time))
          local spinner_char="${spinner_chars:$spin_idx:1}"
          local line=""

          case "$status" in
            done)
              done_count=$((done_count + 1))
              line=$(printf "  ${GREEN}✓${RESET} Agent %d: ${DIM}%s${RESET} ${GREEN}done${RESET}" "$agent_n" "${task:0:40}")
              ;;
            failed)
              failed_count=$((failed_count + 1))
              line=$(printf "  ${RED}✗${RESET} Agent %d: ${DIM}%s${RESET} ${RED}failed${RESET}" "$agent_n" "${task:0:40}")
              ;;
            running)
              if kill -0 "$pid" 2>/dev/null; then
                all_done=false
              fi
              local step
              step=$(get_agent_current_step "${stream_files[$j]}")
              local step_color
              step_color=$(get_step_color "$step")
              line=$(printf "  ${CYAN}%s${RESET} Agent %d: ${step_color}%-14s${RESET} │ %-30s ${DIM}[%02d:%02d]${RESET}" \
                "$spinner_char" "$agent_n" "$step" "${task:0:30}" $((elapsed/60)) $((elapsed%60)))
              ;;
            "setting up")
              if kill -0 "$pid" 2>/dev/null; then
                all_done=false
              fi
              line=$(printf "  ${YELLOW}%s${RESET} Agent %d: ${YELLOW}Setting up${RESET}    │ %-30s ${DIM}[%02d:%02d]${RESET}" \
                "$spinner_char" "$agent_n" "${task:0:30}" $((elapsed/60)) $((elapsed%60)))
              ;;
            *)
              if kill -0 "$pid" 2>/dev/null; then
                all_done=false
              fi
              line=$(printf "  ${DIM}%s${RESET} Agent %d: ${DIM}Waiting${RESET}        │ %-30s" "$spinner_char" "$agent_n" "${task:0:30}")
              ;;
          esac

          # Print line with padding to overwrite previous content (no flicker)
          printf "\r%-${line_width}s\n" "$line"
        done

        [[ "$all_done" == true ]] && break

        spin_idx=$(( (spin_idx + 1) % ${#spinner_chars} ))
        sleep 0.3
      done

      # Restore cursor visibility
      printf "\e[?25h"

      # Wait for all processes to fully complete
      for pid in "${parallel_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done

      # Show final status for this batch
      echo ""
      echo "${BOLD}Batch $batch_num Results:${RESET}"
      for ((j = 0; j < batch_size; j++)); do
        local task="${batch_tasks[$j]}"
        local status_file="${status_files[$j]}"
        local output_file="${output_files[$j]}"
        local log_file="${log_files[$j]}"
        local status=$(cat "$status_file" 2>/dev/null || echo "unknown")
        local agent_num=$((iteration - batch_size + j + 1))

        local icon color branch_info=""
        case "$status" in
          done)
            icon="✓"
            color="$GREEN"
            # Collect tokens and branch name
            local output_data=$(cat "$output_file" 2>/dev/null || echo "0 0")
            local in_tok=$(echo "$output_data" | awk '{print $1}')
            local out_tok=$(echo "$output_data" | awk '{print $2}')
            local branch=$(echo "$output_data" | awk '{print $3}')
            [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
            [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
            total_input_tokens=$((total_input_tokens + in_tok))
            total_output_tokens=$((total_output_tokens + out_tok))
            if [[ -n "$branch" ]]; then
              completed_branches+=("$branch")
              branch_info=" → ${CYAN}$branch${RESET}"
            fi

            # Mark task complete in PRD
            if [[ "$PRD_SOURCE" == "markdown" ]]; then
              mark_task_complete_markdown "$task"
            elif [[ "$PRD_SOURCE" == "yaml" ]]; then
              mark_task_complete_yaml "$task"
            elif [[ "$PRD_SOURCE" == "github" ]]; then
              mark_task_complete_github "$task"
            fi
            ;;
          failed)
            icon="✗"
            color="$RED"
            if [[ -s "$log_file" ]]; then
              branch_info=" ${DIM}(error below)${RESET}"
            fi
            ;;
          *)
            icon="?"
            color="$YELLOW"
            ;;
        esac

        printf "  ${color}%s${RESET} Agent %d: %s%s\n" "$icon" "$agent_num" "${task:0:45}" "$branch_info"

        # Show log for failed agents
        if [[ "$status" == "failed" ]] && [[ -s "$log_file" ]]; then
          echo "${DIM}    ┌─ Agent $agent_num log:${RESET}"
          sed 's/^/    │ /' "$log_file" | head -20
          local log_lines=$(wc -l < "$log_file")
          if [[ $log_lines -gt 20 ]]; then
            echo "${DIM}    │ ... ($((log_lines - 20)) more lines)${RESET}"
          fi
          echo "${DIM}    └─${RESET}"
        fi

        # Cleanup temp files
        rm -f "$status_file" "$output_file" "$log_file" "${stream_files[$j]}"
      done

      batch_start=$batch_end

      # Check if we've hit max iterations
      if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
        log_warn "Reached max iterations ($MAX_ITERATIONS)"
        break
      fi
    done

    if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
      break
    fi
  done
  
  # Cleanup worktree base
  if ! find "$WORKTREE_BASE" -maxdepth 1 -type d -name 'agent-*' -print -quit 2>/dev/null | grep -q .; then
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  else
    log_warn "Preserving worktree base with dirty agents: $WORKTREE_BASE"
  fi
  
  # Handle completed branches
  if [[ ${#completed_branches[@]} -gt 0 ]]; then
    echo ""
    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    if [[ "$CREATE_PR" == true ]]; then
      # PRs were created, just show the branches
      echo "${BOLD}Branches created by agents:${RESET}"
      for branch in "${completed_branches[@]}"; do
        echo "  ${CYAN}•${RESET} $branch"
      done
    else
      # Auto-merge branches back to main
      echo "${BOLD}Merging agent branches into ${BASE_BRANCH}...${RESET}"
      echo ""

      if ! git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
        log_warn "Could not checkout $BASE_BRANCH; leaving agent branches unmerged."
        echo "${BOLD}Branches created by agents:${RESET}"
        for branch in "${completed_branches[@]}"; do
          echo "  ${CYAN}•${RESET} $branch"
        done
        return 0
      fi
      
      local merge_failed=()
      
      for branch in "${completed_branches[@]}"; do
        printf "  Merging ${CYAN}%s${RESET}..." "$branch"
        
        # Attempt to merge
        if git merge --no-edit "$branch" >/dev/null 2>&1; then
          printf " ${GREEN}✓${RESET}\n"
          # Delete the branch after successful merge
          git branch -d "$branch" >/dev/null 2>&1 || true
        else
          printf " ${YELLOW}conflict${RESET}"
          merge_failed+=("$branch")
          # Don't abort yet - try AI resolution
        fi
      done
      
      # Use AI to resolve merge conflicts
      if [[ ${#merge_failed[@]} -gt 0 ]]; then
        echo ""
        echo "${BOLD}Using AI to resolve ${#merge_failed[@]} merge conflict(s)...${RESET}"
        echo ""
        
        local still_failed=()
        
        for branch in "${merge_failed[@]}"; do
          printf "  Resolving ${CYAN}%s${RESET}..." "$branch"
          
          # Get list of conflicted files
          local conflicted_files
          conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null)
          
          if [[ -z "$conflicted_files" ]]; then
            # No conflicts found (maybe already resolved or aborted)
            git merge --abort 2>/dev/null || true
            git merge --no-edit "$branch" >/dev/null 2>&1 || {
              printf " ${RED}✗${RESET}\n"
              still_failed+=("$branch")
              git merge --abort 2>/dev/null || true
              continue
            }
            printf " ${GREEN}✓${RESET}\n"
            git branch -d "$branch" >/dev/null 2>&1 || true
            continue
          fi
          
          # Build prompt for AI to resolve conflicts
          local resolve_prompt="You are resolving a git merge conflict. The following files have conflicts:

$conflicted_files

For each conflicted file:
1. Read the file to see the conflict markers (<<<<<<< HEAD, =======, >>>>>>> branch)
2. Understand what both versions are trying to do
3. Edit the file to resolve the conflict by combining both changes intelligently
4. Remove all conflict markers
5. Make sure the resulting code is valid and compiles

After resolving all conflicts:
1. Run 'git add' on each resolved file
2. Run 'git commit --no-edit' to complete the merge

Be careful to preserve functionality from BOTH branches. The goal is to integrate all features."

          # Run AI to resolve conflicts
          local resolve_tmpfile
          resolve_tmpfile=$(mktemp)
          
          execute_ai_prompt "$resolve_prompt" "$resolve_tmpfile"
          
          rm -f "$resolve_tmpfile"
          
          # Check if merge was completed
          if ! git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            # No more conflicts - merge succeeded
            printf " ${GREEN}✓ (AI resolved)${RESET}\n"
            git branch -d "$branch" >/dev/null 2>&1 || true
          else
            # Still has conflicts
            printf " ${RED}✗ (AI couldn't resolve)${RESET}\n"
            still_failed+=("$branch")
            git merge --abort 2>/dev/null || true
          fi
        done
        
        if [[ ${#still_failed[@]} -gt 0 ]]; then
          echo ""
          echo "${YELLOW}Some conflicts could not be resolved automatically:${RESET}"
          for branch in "${still_failed[@]}"; do
            echo "  ${YELLOW}•${RESET} $branch"
          done
          echo ""
          echo "${DIM}Resolve conflicts manually: git merge <branch>${RESET}"
        else
          echo ""
          echo "${GREEN}All branches merged successfully!${RESET}"
        fi
      else
        echo ""
        echo "${GREEN}All branches merged successfully!${RESET}"
      fi
    fi
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

  if [[ "$SKILLS_INIT" == true ]]; then
    ensure_skills_for_engine "$AI_ENGINE" "install"
    exit 0
  fi

  if [[ "$DRY_RUN" == true ]] && [[ "$MAX_ITERATIONS" -eq 0 ]]; then
    MAX_ITERATIONS=1
  fi
  
  # Set up cleanup trap
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP
  
  # Check requirements
  check_requirements

  # Warn if skills are missing
  ensure_skills_for_engine "$AI_ENGINE" "warn"
  
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
  echo "Source: ${CYAN}$PRD_SOURCE${RESET} (${PRD_FILE:-$GITHUB_REPO})"
  
  local mode_parts=()
  [[ "$SKIP_TESTS" == true ]] && mode_parts+=("no-tests")
  [[ "$SKIP_LINT" == true ]] && mode_parts+=("no-lint")
  [[ "$DRY_RUN" == true ]] && mode_parts+=("dry-run")
  [[ "$PARALLEL" == true ]] && mode_parts+=("parallel:$MAX_PARALLEL")
  [[ "$BRANCH_PER_TASK" == true ]] && mode_parts+=("branch-per-task")
  [[ "$CREATE_PR" == true ]] && mode_parts+=("create-pr")
  [[ $MAX_ITERATIONS -gt 0 ]] && mode_parts+=("max:$MAX_ITERATIONS")
  
  if [[ ${#mode_parts[@]} -gt 0 ]]; then
    echo "Mode: ${YELLOW}${mode_parts[*]}${RESET}"
  fi
  echo "${BOLD}============================================${RESET}"

  # Run in parallel or sequential mode
  if [[ "$PARALLEL" == true ]]; then
    local parallel_result=0
    # Use DAG scheduler for YAML v1, otherwise legacy parallel
    if [[ "$PRD_SOURCE" == "yaml" ]] && is_yaml_v1; then
      run_parallel_tasks_yaml_v1 || parallel_result=$?
    else
      run_parallel_tasks || parallel_result=$?
    fi
    if [[ "$parallel_result" -ne 0 ]]; then
      notify_error "GRALPH stopped due to external failure or deadlock"
      exit "$parallel_result"
    fi
    show_summary
    notify_done
    exit 0
  fi

  # Sequential main loop
  while true; do
    ((++iteration))
    local result_code=0
    run_single_task "" "$iteration" || result_code=$?
    
    case $result_code in
      0)
        # Success, continue
        ;;
      1)
        # Error, but continue to next task
        log_warn "Task failed after $MAX_RETRIES attempts, continuing..."
        ;;
      2)
        # All tasks complete
        show_summary
        notify_done
        exit 0
        ;;
    esac
    
    # Check max iterations
    if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
      log_warn "Reached max iterations ($MAX_ITERATIONS)"
      show_summary
      notify_done "GRALPH stopped after $MAX_ITERATIONS iterations"
      exit 0
    fi
    
    # Small delay between iterations
    sleep 1
  done
}

# Run main
main "$@"
