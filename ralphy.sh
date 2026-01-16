#!/bin/bash

# ============================================
# Ralphy - Autonomous AI Coding Loop
# Supports both Claude Code and OpenCode
# Runs until PRD is complete
# ============================================

set -euo pipefail

# ============================================
# CONFIGURATION & DEFAULTS
# ============================================

VERSION="3.0.1"

# Runtime options
SKIP_TESTS=false
SKIP_LINT=false
USE_OPENCODE=false
DRY_RUN=false
MAX_ITERATIONS=0  # 0 = unlimited
MAX_RETRIES=3
RETRY_DELAY=5
VERBOSE=false

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
current_step="Thinking"
total_input_tokens=0
total_output_tokens=0
total_actual_cost="0"  # OpenCode provides actual cost
iteration=0
retry_count=0
declare -a parallel_pids=()
declare -a task_branches=()
WORKTREE_BASE=""  # Base directory for parallel agent worktrees
ORIGINAL_DIR=""   # Original working directory (for worktree operations)

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

# ============================================
# HELP & VERSION
# ============================================

show_help() {
  cat << EOF
${BOLD}Ralphy${RESET} - Autonomous AI Coding Loop (v${VERSION})

${BOLD}USAGE:${RESET}
  ./ralphy.sh [options]

${BOLD}AI ENGINE OPTIONS:${RESET}
  --opencode          Use OpenCode instead of Claude Code
  --claude            Use Claude Code (default)

${BOLD}WORKFLOW OPTIONS:${RESET}
  --no-tests          Skip writing and running tests
  --no-lint           Skip linting
  --fast              Skip both tests and linting

${BOLD}EXECUTION OPTIONS:${RESET}
  --max-iterations N  Stop after N iterations (0 = unlimited)
  --max-retries N     Max retries per task on failure (default: 3)
  --retry-delay N     Seconds between retries (default: 5)
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
  -v, --verbose       Show debug output
  -h, --help          Show this help
  --version           Show version number

${BOLD}EXAMPLES:${RESET}
  ./ralphy.sh                              # Run with Claude Code
  ./ralphy.sh --opencode                   # Run with OpenCode
  ./ralphy.sh --branch-per-task --create-pr  # Feature branch workflow
  ./ralphy.sh --parallel --max-parallel 4  # Run 4 tasks concurrently
  ./ralphy.sh --yaml tasks.yaml            # Use YAML task file
  ./ralphy.sh --github owner/repo          # Fetch from GitHub issues

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
  echo "Ralphy v${VERSION}"
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
        USE_OPENCODE=true
        shift
        ;;
      --claude)
        USE_OPENCODE=false
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
      if [[ ! -f "$PRD_FILE" ]]; then
        log_error "$PRD_FILE not found in current directory"
        exit 1
      fi
      if ! command -v yq &>/dev/null; then
        log_error "yq is required for YAML parsing. Install from https://github.com/mikefarah/yq"
        exit 1
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
  if [[ "$USE_OPENCODE" == true ]]; then
    if ! command -v opencode &>/dev/null; then
      log_error "OpenCode CLI not found. Install from https://opencode.ai/docs/"
      exit 1
    fi
  else
    if ! command -v claude &>/dev/null; then
      log_error "Claude Code CLI not found. Install from https://github.com/anthropics/claude-code"
      exit 1
    fi
  fi

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
  
  # Cleanup parallel worktrees
  if [[ -n "$WORKTREE_BASE" ]] && [[ -d "$WORKTREE_BASE" ]]; then
    # Remove all worktrees we created
    for dir in "$WORKTREE_BASE"/agent-*; do
      [[ -d "$dir" ]] && git worktree remove -f "$dir" 2>/dev/null || true
    done
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
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
  # Escape special regex characters
  local escaped_task
  escaped_task=$(printf '%s\n' "$task" | sed 's/[[\.*^$()+?{|]/\\&/g')
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
  yq -r ".tasks[] | select(.completed != true and .parallel_group == $group) | .title" "$PRD_FILE" 2>/dev/null || true
}

# ============================================
# TASK SOURCES - GITHUB ISSUES
# ============================================

get_tasks_github() {
  local label_filter=""
  [[ -n "$GITHUB_LABEL" ]] && label_filter="--label \"$GITHUB_LABEL\""
  
  gh issue list --repo "$GITHUB_REPO" --state open $label_filter --json number,title \
    --jq '.[] | "\(.number):\(.title)"' 2>/dev/null || true
}

get_next_task_github() {
  local label_filter=""
  [[ -n "$GITHUB_LABEL" ]] && label_filter="--label \"$GITHUB_LABEL\""
  
  gh issue list --repo "$GITHUB_REPO" --state open $label_filter --limit 1 --json number,title \
    --jq '.[0] | "\(.number):\(.title)"' 2>/dev/null | cut -c1-50 || echo ""
}

count_remaining_github() {
  local label_filter=""
  [[ -n "$GITHUB_LABEL" ]] && label_filter="--label \"$GITHUB_LABEL\""
  
  gh issue list --repo "$GITHUB_REPO" --state open $label_filter --json number \
    --jq 'length' 2>/dev/null || echo "0"
}

count_completed_github() {
  local label_filter=""
  [[ -n "$GITHUB_LABEL" ]] && label_filter="--label \"$GITHUB_LABEL\""
  
  gh issue list --repo "$GITHUB_REPO" --state closed $label_filter --json number \
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
  local branch_name="ralphy/$(slugify "$task")"
  
  log_debug "Creating branch: $branch_name from $BASE_BRANCH"
  
  # Stash any changes
  git stash push -m "ralphy-autostash" 2>/dev/null || true
  
  # Create and checkout new branch
  git checkout "$BASE_BRANCH" 2>/dev/null || true
  git pull origin "$BASE_BRANCH" 2>/dev/null || true
  git checkout -b "$branch_name" 2>/dev/null || {
    # Branch might already exist
    git checkout "$branch_name" 2>/dev/null || true
  }
  
  # Pop stash if we stashed
  git stash pop 2>/dev/null || true
  
  task_branches+=("$branch_name")
  echo "$branch_name"
}

create_pull_request() {
  local branch=$1
  local task=$2
  local body="${3:-Automated PR created by Ralphy}"
  
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

    # Check latest output for step indicators
    if [[ -f "$file" ]] && [[ -s "$file" ]]; then
      local content
      content=$(tail -c 5000 "$file" 2>/dev/null || true)

      if echo "$content" | grep -qE 'git commit|"command":"git commit'; then
        current_step="Committing"
      elif echo "$content" | grep -qE 'git add|"command":"git add'; then
        current_step="Staging"
      elif echo "$content" | grep -qE 'progress\.txt'; then
        current_step="Logging"
      elif echo "$content" | grep -qE 'PRD\.md|tasks\.yaml'; then
        current_step="Updating PRD"
      elif echo "$content" | grep -qE 'lint|eslint|biome|prettier'; then
        current_step="Linting"
      elif echo "$content" | grep -qE 'vitest|jest|bun test|npm test|pytest|go test'; then
        current_step="Testing"
      elif echo "$content" | grep -qE '\.test\.|\.spec\.|__tests__|_test\.go'; then
        current_step="Writing tests"
      elif echo "$content" | grep -qE '"tool":"[Ww]rite"|"tool":"[Ee]dit"|"name":"write"|"name":"edit"'; then
        current_step="Implementing"
      elif echo "$content" | grep -qE '"tool":"[Rr]ead"|"tool":"[Gg]lob"|"tool":"[Gg]rep"|"name":"read"|"name":"glob"|"name":"grep"'; then
        current_step="Reading code"
      fi
    fi

    local spinner_char="${spinstr:$spin_idx:1}"
    local step_color=""
    
    # Color-code steps
    case "$current_step" in
      "Thinking"|"Reading code") step_color="$CYAN" ;;
      "Implementing"|"Writing tests") step_color="$MAGENTA" ;;
      "Testing"|"Linting") step_color="$YELLOW" ;;
      "Staging"|"Committing") step_color="$GREEN" ;;
      *) step_color="$BLUE" ;;
    esac

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
  local message="${1:-Ralphy has completed all tasks!}"
  
  # macOS
  if command -v afplay &>/dev/null; then
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
  fi
  
  # macOS notification
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"Ralphy\"" 2>/dev/null || true
  fi
  
  # Linux (notify-send)
  if command -v notify-send &>/dev/null; then
    notify-send "Ralphy" "$message" 2>/dev/null || true
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
  local message="${1:-Ralphy encountered an error}"
  
  # macOS
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$message\" with title \"Ralphy - Error\"" 2>/dev/null || true
  fi
  
  # Linux
  if command -v notify-send &>/dev/null; then
    notify-send -u critical "Ralphy - Error" "$message" 2>/dev/null || true
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

run_ai_command() {
  local prompt=$1
  local output_file=$2
  
  if [[ "$USE_OPENCODE" == true ]]; then
    # OpenCode: use 'run' command with JSON format and permissive settings
    OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
      --format json \
      "$prompt" > "$output_file" 2>&1 &
  else
    # Claude Code: use existing approach
    claude --dangerously-skip-permissions \
      --verbose \
      --output-format stream-json \
      -p "$prompt" > "$output_file" 2>&1 &
  fi
  
  ai_pid=$!
}

parse_ai_result() {
  local result=$1
  local response=""
  local input_tokens=0
  local output_tokens=0
  local actual_cost="0"
  
  if [[ "$USE_OPENCODE" == true ]]; then
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
  else
    # Claude Code stream-json parsing
    local result_line
    result_line=$(echo "$result" | grep '"type":"result"' | tail -1)
    
    if [[ -n "$result_line" ]]; then
      response=$(echo "$result_line" | jq -r '.result // "No result text"' 2>/dev/null || echo "Could not parse result")
      input_tokens=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo "0")
      output_tokens=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")
    fi
  fi
  
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
  
  local remaining
  remaining=$(count_remaining_tasks)
  local completed
  completed=$(count_completed_tasks)
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
      ((retry_count++))
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
      ((retry_count++))
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
    
    # Track actual cost for OpenCode
    if [[ -n "$actual_cost" ]] && [[ "$actual_cost" != "0" ]] && command -v bc &>/dev/null; then
      total_actual_cost=$(echo "scale=6; $total_actual_cost + $actual_cost" | bc 2>/dev/null || echo "$total_actual_cost")
    fi

    rm -f "$tmpfile"
    tmpfile=""

    # Mark task complete for GitHub issues (since AI can't do it)
    if [[ "$PRD_SOURCE" == "github" ]]; then
      mark_task_complete "$current_task"
    fi

    # Create PR if requested
    if [[ "$CREATE_PR" == true ]] && [[ -n "$branch_name" ]]; then
      create_pull_request "$branch_name" "$current_task" "Automated implementation by Ralphy"
    fi

    # Return to base branch
    return_to_base_branch

    # Check for completion
    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
      return 2  # Special code for "all done"
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
  local branch_name="ralphy/agent-${agent_num}-$(slugify "$task_name")"
  local worktree_dir="${WORKTREE_BASE}/agent-${agent_num}"
  
  # Run git commands from original directory
  # Errors go to stderr which will be captured by caller's log redirect
  (
    cd "$ORIGINAL_DIR" || { echo "Failed to cd to $ORIGINAL_DIR" >&2; exit 1; }
    
    # Prune any stale worktrees first
    git worktree prune 2>&1
    
    # Delete branch if it exists (force)
    git branch -D "$branch_name" 2>/dev/null || true
    
    # Create branch from base
    git branch "$branch_name" "$BASE_BRANCH" 2>&1 || { echo "Failed to create branch $branch_name from $BASE_BRANCH" >&2; exit 1; }
    
    # Remove existing worktree dir if any
    rm -rf "$worktree_dir" 2>/dev/null || true
    
    # Create worktree
    git worktree add "$worktree_dir" "$branch_name" 2>&1 || { echo "Failed to create worktree at $worktree_dir" >&2; exit 1; }
  )
  
  echo "$worktree_dir|$branch_name"
}

# Cleanup worktree after agent completes
cleanup_agent_worktree() {
  local worktree_dir="$1"
  local branch_name="$2"
  
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
    if [[ "$USE_OPENCODE" == true ]]; then
      (
        cd "$worktree_dir"
        OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
          --format json \
          "$prompt"
      ) > "$tmpfile" 2>>"$log_file"
    else
      (
        cd "$worktree_dir"
        claude --dangerously-skip-permissions \
          -p "$prompt" \
          --output-format stream-json
      ) > "$tmpfile" 2>>"$log_file"
    fi
    
    result=$(cat "$tmpfile" 2>/dev/null || echo "")
    
    if [[ -n "$result" ]]; then
      success=true
      break
    fi
    
    ((retry++))
    echo "Retry $retry/$MAX_RETRIES after empty response" >> "$log_file"
    sleep "$RETRY_DELAY"
  done
  
  rm -f "$tmpfile"
  
  if [[ "$success" == true ]]; then
    # Parse tokens
    local parsed input_tokens output_tokens
    parsed=$(parse_ai_result "$result")
    local token_data
    token_data=$(echo "$parsed" | sed -n '/^---TOKENS---$/,$p' | tail -3)
    input_tokens=$(echo "$token_data" | sed -n '1p')
    output_tokens=$(echo "$token_data" | sed -n '2p')
    [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0
    
    # Create PR if requested
    if [[ "$CREATE_PR" == true ]]; then
      (
        cd "$worktree_dir"
        git push -u origin "$branch_name" 2>>"$log_file" || true
        gh pr create \
          --base "$BASE_BRANCH" \
          --head "$branch_name" \
          --title "$task_name" \
          --body "Automated implementation by Ralphy (Agent $agent_num)" \
          ${PR_DRAFT:+--draft} 2>>"$log_file" || true
      )
    fi
    
    # Write success output
    echo "done" > "$status_file"
    echo "$input_tokens $output_tokens $branch_name" > "$output_file"
    
    # Cleanup worktree (but keep branch)
    cleanup_agent_worktree "$worktree_dir" "$branch_name"
    
    return 0
  else
    echo "failed" > "$status_file"
    echo "0 0" > "$output_file"
    cleanup_agent_worktree "$worktree_dir" "$branch_name"
    return 1
  fi
}

run_parallel_tasks() {
  log_info "Running ${BOLD}$MAX_PARALLEL parallel agents${RESET} (each in isolated worktree)..."
  
  local tasks=()
  
  # Get all pending tasks
  while IFS= read -r task; do
    [[ -n "$task" ]] && tasks+=("$task")
  done < <(get_all_tasks)
  
  if [[ ${#tasks[@]} -eq 0 ]]; then
    log_info "No tasks to run"
    return 2
  fi
  
  local total_tasks=${#tasks[@]}
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
  export USE_OPENCODE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT
  
  # Process tasks in batches
  local batch_start=0
  local batch_num=0
  local completed_branches=()
  
  while [[ $batch_start -lt $total_tasks ]]; do
    ((batch_num++))
    local batch_end=$((batch_start + MAX_PARALLEL))
    [[ $batch_end -gt $total_tasks ]] && batch_end=$total_tasks
    local batch_size=$((batch_end - batch_start))
    
    echo ""
    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo "${BOLD}Batch $batch_num: Spawning $batch_size parallel agents${RESET}"
    echo "${DIM}Each agent runs in its own git worktree with isolated workspace${RESET}"
    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    
    # Setup arrays for this batch
    parallel_pids=()
    local batch_tasks=()
    local status_files=()
    local output_files=()
    local log_files=()
    
    # Start all agents in the batch
    for ((i = batch_start; i < batch_end; i++)); do
      local task="${tasks[$i]}"
      local agent_num=$((i + 1))
      ((iteration++))
      
      local status_file=$(mktemp)
      local output_file=$(mktemp)
      local log_file=$(mktemp)
      
      batch_tasks+=("$task")
      status_files+=("$status_file")
      output_files+=("$output_file")
      log_files+=("$log_file")
      
      echo "waiting" > "$status_file"
      
      # Show initial status
      printf "  ${CYAN}◉${RESET} Agent %d: %s\n" "$agent_num" "${task:0:50}"
      
      # Run agent in background
      (
        run_parallel_agent "$task" "$agent_num" "$output_file" "$status_file" "$log_file"
      ) &
      parallel_pids+=($!)
    done
    
    echo ""
    
    # Monitor progress with a spinner
    local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_idx=0
    local start_time=$SECONDS
    
    while true; do
      # Check if all processes are done
      local all_done=true
      local setting_up=0
      local running=0
      local done_count=0
      local failed_count=0
      
      for ((j = 0; j < batch_size; j++)); do
        local pid="${parallel_pids[$j]}"
        local status_file="${status_files[$j]}"
        local status=$(cat "$status_file" 2>/dev/null || echo "waiting")
        
        case "$status" in
          "setting up")
            all_done=false
            ((setting_up++))
            ;;
          running)
            all_done=false
            ((running++))
            ;;
          done)
            ((done_count++))
            ;;
          failed)
            ((failed_count++))
            ;;
          *)
            # Check if process is still running
            if kill -0 "$pid" 2>/dev/null; then
              all_done=false
            fi
            ;;
        esac
      done
      
      [[ "$all_done" == true ]] && break
      
      # Update spinner
      local elapsed=$((SECONDS - start_time))
      local spin_char="${spinner_chars:$spin_idx:1}"
      spin_idx=$(( (spin_idx + 1) % ${#spinner_chars} ))
      
      printf "\r  ${CYAN}%s${RESET} Agents: ${BLUE}%d setup${RESET} | ${YELLOW}%d running${RESET} | ${GREEN}%d done${RESET} | ${RED}%d failed${RESET} | %02d:%02d " \
        "$spin_char" "$setting_up" "$running" "$done_count" "$failed_count" $((elapsed / 60)) $((elapsed % 60))
      
      sleep 0.3
    done
    
    # Clear the spinner line
    printf "\r%100s\r" ""
    
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
      local agent_num=$((batch_start + j + 1))
      
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
      rm -f "$status_file" "$output_file" "$log_file"
    done
    
    batch_start=$batch_end
    
    # Check if we've hit max iterations
    if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
      log_warn "Reached max iterations ($MAX_ITERATIONS)"
      break
    fi
  done
  
  # Cleanup worktree base
  rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  
  # Show branches created
  if [[ ${#completed_branches[@]} -gt 0 ]]; then
    echo ""
    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo "${BOLD}Branches created by agents:${RESET}"
    for branch in "${completed_branches[@]}"; do
      echo "  ${CYAN}•${RESET} $branch"
    done
    if [[ "$CREATE_PR" != true ]]; then
      echo ""
      echo "${DIM}Tip: Use --create-pr to automatically create PRs for each branch${RESET}"
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
  echo "Input tokens:  $total_input_tokens"
  echo "Output tokens: $total_output_tokens"
  echo "Total tokens:  $((total_input_tokens + total_output_tokens))"
  
  # Show actual cost if available (OpenCode provides this), otherwise estimate
  if [[ "$USE_OPENCODE" == true ]] && command -v bc &>/dev/null; then
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
  
  # Set up cleanup trap
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP
  
  # Check requirements
  check_requirements
  
  # Show banner
  echo "${BOLD}============================================${RESET}"
  echo "${BOLD}Ralphy${RESET} - Running until PRD is complete"
  echo "Engine: $([ "$USE_OPENCODE" = true ] && echo "${CYAN}OpenCode${RESET}" || echo "${MAGENTA}Claude Code${RESET}")"
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
    run_parallel_tasks
    show_summary
    notify_done
    exit 0
  fi

  # Sequential main loop
  while true; do
    ((iteration++))
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
      notify_done "Ralphy stopped after $MAX_ITERATIONS iterations"
      exit 0
    fi
    
    # Small delay between iterations
    sleep 1
  done
}

# Run main
main "$@"
