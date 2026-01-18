#!/usr/bin/env bash
# Simple test runner for GRALPH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

run_test() {
  local test_file=$1
  local test_name
  test_name=$(basename "$test_file" .test.sh)
  
  printf "  %-40s " "$test_name"
  
  local output
  output=$(bash "$test_file" 2>&1)
  local exit_code=$?
  
  if [[ "$output" == SKIP:* ]]; then
    echo -e "${YELLOW}SKIP${NC} (${output#SKIP: })"
  elif [[ $exit_code -eq 0 ]]; then
    echo -e "${GREEN}PASS${NC}"
    ((TESTS_PASSED++)) || true
  else
    echo -e "${RED}FAIL${NC}"
    ((TESTS_FAILED++)) || true
    echo "    Output:"
    echo "$output" | sed 's/^/    /' | head -20
  fi
}

echo "Running GRALPH tests..."
echo ""

for test_file in "$SCRIPT_DIR"/*.test.sh; do
  [[ -f "$test_file" ]] && run_test "$test_file"
done

echo ""
echo "Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"

[[ $TESTS_FAILED -eq 0 ]]
