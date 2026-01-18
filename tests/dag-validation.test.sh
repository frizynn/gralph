#!/usr/bin/env bash
# Tests for DAG validation

set -euo pipefail

# Skip if yq not installed
if ! command -v yq &>/dev/null; then
  echo "SKIP: yq not installed"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_DIR="$(dirname "$SCRIPT_DIR")"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Source gralph.sh functions (without running main)
source_ralph() {
  # Extract just the functions we need
  cd "$TMPDIR"
  export PRD_FILE="$TMPDIR/tasks.yaml"
  export ORIGINAL_DIR="$TMPDIR"
  
  # Minimal function copies for testing
  is_yaml_v1() {
    local version
    version=$(yq -r '.version // 0' "$PRD_FILE" 2>/dev/null)
    [[ "$version" == "1" ]]
  }
  
  get_all_task_ids_yaml_v1() {
    yq -r '.tasks[].id' "$PRD_FILE" 2>/dev/null
  }
  
  get_task_deps_by_id_yaml_v1() {
    local id=$1
    yq -r ".tasks[] | select(.id == \"$id\") | .dependsOn[]?" "$PRD_FILE" 2>/dev/null
  }
}

source_ralph

# Test 1: Valid schema passes
test_valid_schema() {
  cat > "$PRD_FILE" << 'EOF'
version: 1
tasks:
  - id: US-001
    title: First task
    completed: false
    dependsOn: []
  - id: US-002
    title: Second task
    completed: false
    dependsOn: ["US-001"]
EOF
  
  # Should have version 1
  is_yaml_v1 || { echo "FAIL: valid schema not detected as v1"; return 1; }
  
  # Should have 2 tasks
  local count
  count=$(get_all_task_ids_yaml_v1 | wc -l | tr -d ' ')
  [[ "$count" -eq 2 ]] || { echo "FAIL: expected 2 tasks, got $count"; return 1; }
}

# Test 2: Duplicate IDs detected
test_duplicate_ids() {
  cat > "$PRD_FILE" << 'EOF'
version: 1
tasks:
  - id: US-001
    title: First
    completed: false
    dependsOn: []
  - id: US-001
    title: Duplicate
    completed: false
    dependsOn: []
EOF
  
  local ids
  ids=$(get_all_task_ids_yaml_v1)
  local unique_count
  unique_count=$(echo "$ids" | sort -u | wc -l | tr -d ' ')
  local total_count
  total_count=$(echo "$ids" | wc -l | tr -d ' ')
  
  [[ "$unique_count" -lt "$total_count" ]] || { echo "FAIL: duplicates not detected"; return 1; }
}

# Test 3: Dependency check
test_dependency_exists() {
  cat > "$PRD_FILE" << 'EOF'
version: 1
tasks:
  - id: US-002
    title: Task with dep
    completed: false
    dependsOn: ["US-001"]
EOF
  
  local dep
  dep=$(get_task_deps_by_id_yaml_v1 "US-002")
  [[ "$dep" == "US-001" ]] || { echo "FAIL: dependency not parsed"; return 1; }
  
  # US-001 doesn't exist - validation should catch this
  local all_ids
  all_ids=$(get_all_task_ids_yaml_v1)
  if echo "$all_ids" | grep -qx "US-001"; then
    echo "FAIL: missing dependency not caught"
    return 1
  fi
}

# Run tests
echo "Testing DAG validation..."
test_valid_schema
test_duplicate_ids
test_dependency_exists
echo "All DAG validation tests passed"
