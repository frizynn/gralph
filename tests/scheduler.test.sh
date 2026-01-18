#!/usr/bin/env bash
# Tests for DAG scheduler

set -euo pipefail

# Skip if yq not installed
if ! command -v yq &>/dev/null; then
  echo "SKIP: yq not installed"
  exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
export PRD_FILE="$TMPDIR/tasks.yaml"
export ORIGINAL_DIR="$TMPDIR"

# Minimal scheduler state simulation
declare -A SCHED_STATE
declare -A SCHED_LOCKED

# Helper functions (copied from gralph.sh for isolation)
get_all_task_ids_yaml_v1() {
  yq -r '.tasks[].id' "$PRD_FILE" 2>/dev/null
}

get_task_deps_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .dependsOn[]?" "$PRD_FILE" 2>/dev/null
}

get_task_mutex_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .mutex[]?" "$PRD_FILE" 2>/dev/null
}

is_task_completed_yaml_v1() {
  local id=$1
  local completed
  completed=$(yq -r ".tasks[] | select(.id == \"$id\") | .completed" "$PRD_FILE" 2>/dev/null)
  [[ "$completed" == "true" ]]
}

scheduler_init() {
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

scheduler_deps_satisfied() {
  local id=$1
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "${SCHED_STATE[$dep]}" != "done" ]] && return 1
  done < <(get_task_deps_by_id_yaml_v1 "$id")
  return 0
}

scheduler_mutex_available() {
  local id=$1
  while IFS= read -r mutex; do
    [[ -z "$mutex" ]] && continue
    [[ -n "${SCHED_LOCKED[$mutex]:-}" ]] && return 1
  done < <(get_task_mutex_by_id_yaml_v1 "$id")
  return 0
}

scheduler_get_ready() {
  for id in "${!SCHED_STATE[@]}"; do
    if [[ "${SCHED_STATE[$id]}" == "pending" ]]; then
      if scheduler_deps_satisfied "$id" && scheduler_mutex_available "$id"; then
        echo "$id"
      fi
    fi
  done
}

# Test 1: Tasks with dependencies run in order
test_dependency_order() {
  cat > "$PRD_FILE" << 'EOF'
version: 1
tasks:
  - id: A
    title: First
    completed: false
    dependsOn: []
    mutex: []
  - id: B
    title: Depends on A
    completed: false
    dependsOn: ["A"]
    mutex: []
EOF
  
  scheduler_init
  
  # Only A should be ready initially
  local ready
  ready=$(scheduler_get_ready | tr '\n' ' ' | xargs)
  [[ "$ready" == "A" ]] || { echo "FAIL: expected A ready, got '$ready'"; return 1; }
  
  # Mark A done
  SCHED_STATE[A]="done"
  
  # Now B should be ready
  ready=$(scheduler_get_ready | tr '\n' ' ' | xargs)
  [[ "$ready" == "B" ]] || { echo "FAIL: expected B ready after A done, got '$ready'"; return 1; }
}

# Test 2: Mutex prevents parallel execution
test_mutex_exclusion() {
  cat > "$PRD_FILE" << 'EOF'
version: 1
tasks:
  - id: M1
    title: Uses db mutex
    completed: false
    dependsOn: []
    mutex: ["db-migrations"]
  - id: M2
    title: Also uses db mutex
    completed: false
    dependsOn: []
    mutex: ["db-migrations"]
EOF
  
  scheduler_init
  
  # Both should be ready initially (no deps)
  local ready_count
  ready_count=$(scheduler_get_ready | wc -l | tr -d ' ')
  [[ "$ready_count" -eq 2 ]] || { echo "FAIL: expected 2 ready, got $ready_count"; return 1; }
  
  # Lock mutex for M1
  SCHED_STATE[M1]="running"
  SCHED_LOCKED["db-migrations"]="M1"
  
  # Now only M1 is running, M2 should not be ready (mutex locked)
  local ready
  ready=$(scheduler_get_ready | tr '\n' ' ' | xargs)
  [[ -z "$ready" ]] || { echo "FAIL: M2 should be blocked by mutex, got '$ready'"; return 1; }
  
  # Unlock mutex
  unset 'SCHED_LOCKED[db-migrations]'
  SCHED_STATE[M1]="done"
  
  # Now M2 should be ready
  ready=$(scheduler_get_ready | tr '\n' ' ' | xargs)
  [[ "$ready" == "M2" ]] || { echo "FAIL: M2 should be ready after mutex release, got '$ready'"; return 1; }
}

# Test 3: Independent tasks can run in parallel
test_parallel_independent() {
  cat > "$PRD_FILE" << 'EOF'
version: 1
tasks:
  - id: P1
    title: Independent 1
    completed: false
    dependsOn: []
    mutex: []
  - id: P2
    title: Independent 2
    completed: false
    dependsOn: []
    mutex: []
  - id: P3
    title: Independent 3
    completed: false
    dependsOn: []
    mutex: []
EOF
  
  scheduler_init
  
  # All 3 should be ready
  local ready_count
  ready_count=$(scheduler_get_ready | wc -l | tr -d ' ')
  [[ "$ready_count" -eq 3 ]] || { echo "FAIL: expected 3 ready, got $ready_count"; return 1; }
}

# Run tests
echo "Testing scheduler..."
test_dependency_order
test_mutex_exclusion
test_parallel_independent
echo "All scheduler tests passed"
