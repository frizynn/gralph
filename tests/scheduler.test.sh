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
declare -A SCHED_RESOURCES

# Helper functions (copied from ../scripts/gralph/gralph.sh for isolation)
get_all_task_ids_yaml_v1() {
  yq -r '.tasks[].id' "$PRD_FILE" 2>/dev/null
}

get_task_deps_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .dependsOn[]?" "$PRD_FILE" 2>/dev/null
}

get_task_touches_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .touches[]?" "$PRD_FILE" 2>/dev/null
}

get_task_locks_by_id_yaml_v1() {
  local id=$1
  yq -r ".tasks[] | select(.id == \"$id\") | .locks[]?" "$PRD_FILE" 2>/dev/null
  yq -r ".tasks[] | select(.id == \"$id\") | .mutex[]?" "$PRD_FILE" 2>/dev/null
}

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

is_task_completed_yaml_v1() {
  local id=$1
  local completed
  completed=$(yq -r ".tasks[] | select(.id == \"$id\") | .completed" "$PRD_FILE" 2>/dev/null)
  [[ "$completed" == "true" ]]
}

scheduler_init() {
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

scheduler_deps_satisfied() {
  local id=$1
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "${SCHED_STATE[$dep]}" != "done" ]] && return 1
  done < <(get_task_deps_by_id_yaml_v1 "$id")
  return 0
}

scheduler_resources_available() {
  local id=$1
  while IFS= read -r lock; do
    [[ -z "$lock" ]] && continue
    [[ -n "${SCHED_RESOURCES[$lock]:-}" ]] && return 1
  done < <(get_task_effective_locks_yaml_v1 "$id")
  return 0
}

scheduler_get_ready() {
  for id in "${!SCHED_STATE[@]}"; do
    if [[ "${SCHED_STATE[$id]}" == "pending" ]]; then
      if scheduler_deps_satisfied "$id" && scheduler_resources_available "$id"; then
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
    touches: ["src/**"]
  - id: B
    title: Depends on A
    completed: false
    dependsOn: ["A"]
    touches: ["src/**"]
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

# Test 2: Resource locks prevent parallel execution
test_resource_lock_exclusion() {
  cat > "$PRD_FILE" << 'EOF'
version: 1
tasks:
  - id: M1
    title: Touches migrations
    completed: false
    dependsOn: []
    touches: ["db/migrations/**"]
  - id: M2
    title: Also touches migrations
    completed: false
    dependsOn: []
    touches: ["db/migrations/**"]
EOF
  
  scheduler_init
  
  # Both should be ready initially (no deps)
  local ready_count
  ready_count=$(scheduler_get_ready | wc -l | tr -d ' ')
  [[ "$ready_count" -eq 2 ]] || { echo "FAIL: expected 2 ready, got $ready_count"; return 1; }
  
  # Lock resources for M1
  SCHED_STATE[M1]="running"
  SCHED_RESOURCES["db-migrations"]="M1"
  
  # Now only M1 is running, M2 should not be ready (resource locked)
  local ready
  ready=$(scheduler_get_ready | tr '\n' ' ' | xargs)
  [[ -z "$ready" ]] || { echo "FAIL: M2 should be blocked by resource lock, got '$ready'"; return 1; }
  
  # Unlock resources
  unset 'SCHED_RESOURCES[db-migrations]'
  SCHED_STATE[M1]="done"
  
  # Now M2 should be ready
  ready=$(scheduler_get_ready | tr '\n' ' ' | xargs)
  [[ "$ready" == "M2" ]] || { echo "FAIL: M2 should be ready after resource release, got '$ready'"; return 1; }
}

# Test 3: Explicit locks are honored
test_explicit_locks() {
  cat > "$PRD_FILE" << 'EOF'
version: 1
tasks:
  - id: L1
    title: Explicit lock 1
    completed: false
    dependsOn: []
    locks: ["custom-lock"]
    touches: ["src/a/**"]
  - id: L2
    title: Explicit lock 2
    completed: false
    dependsOn: []
    locks: ["custom-lock"]
    touches: ["src/b/**"]
EOF

  scheduler_init

  # Both should be ready initially (no deps, lock not held yet)
  local ready_count
  ready_count=$(scheduler_get_ready | wc -l | tr -d ' ')
  [[ "$ready_count" -eq 2 ]] || { echo "FAIL: expected 2 ready, got $ready_count"; return 1; }

  # Lock resources for L1
  SCHED_STATE[L1]="running"
  SCHED_RESOURCES["custom-lock"]="L1"

  # Now L2 should be blocked by explicit lock
  local ready
  ready=$(scheduler_get_ready | tr '\n' ' ' | xargs)
  [[ -z "$ready" ]] || { echo "FAIL: L2 should be blocked by explicit lock, got '$ready'"; return 1; }
}

# Test 4: Independent tasks can run in parallel
test_parallel_independent() {
  cat > "$PRD_FILE" << 'EOF'
version: 1
tasks:
  - id: P1
    title: Independent 1
    completed: false
    dependsOn: []
    touches: ["src/api/**"]
  - id: P2
    title: Independent 2
    completed: false
    dependsOn: []
    touches: ["web/**"]
  - id: P3
    title: Independent 3
    completed: false
    dependsOn: []
    touches: ["infra/**"]
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
test_resource_lock_exclusion
test_explicit_locks
test_parallel_independent
echo "All scheduler tests passed"
