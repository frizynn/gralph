---
name: dag-planner
description: "Build and validate task DAGs for Ralph parallel execution. Use when planning execution order, detecting cycles, or explaining why tasks are blocked. Triggers on: plan dag, check dependencies, why is task blocked, execution order."
---

# DAG Planner

Build, validate, and explain task dependency graphs for parallel execution.

---

## The Job

1. Parse task dependencies into a DAG
2. Detect cycles and report paths
3. Compute topological order
4. Explain blocking reasons
5. Output ready queue and lock plan

**Do NOT:** author metadata, implement tasks, merge code, or review design.

---

## DAG Validation

### Cycle Detection

Use depth-first search with three states:
- `unvisited` - Not yet processed
- `visiting` - Currently in recursion stack
- `visited` - Fully processed

If we encounter a `visiting` node, we have a cycle.

**Cycle output format:**
```
Cycle detected: US-002 → US-003 → US-004 → US-002
```

---

## Execution Planning

### Ready Queue Rules

A task is **ready** when:
1. All tasks in `dependsOn` are `done`
2. None of its `mutex` are currently locked

### Blocking Reasons

When a task cannot run, explain why:

```
Task US-003 blocked:
  - Waiting for: US-001, US-002 (not completed)
  - Mutex locked: db-migrations (held by US-005)
```

---

## Output Formats

### Topological Order
```
Execution order (topological):
  1. US-001 (no deps)
  2. US-002 (no deps)
  3. US-003 (after: US-001)
  4. US-004 (after: US-002, US-003)
```

### Ready Queue Snapshot
```
Ready queue (3 tasks can run now):
  - US-001: mutex []
  - US-002: mutex []
  - US-005: mutex [lockfile]

Blocked (2 tasks waiting):
  - US-003: waiting for US-001
  - US-004: waiting for US-002, US-003
```

### Mutex Lock Plan
```
Mutex usage plan:
  db-migrations: US-001, US-006 (sequential)
  lockfile: US-005 (exclusive)
  contract:auth-api: US-003, US-004 (sequential after US-001)
```

---

## Deadlock Detection

Deadlock occurs when:
- No tasks are running
- No tasks are ready
- Pending tasks exist

**Deadlock output:**
```
DEADLOCK: No progress possible
  Pending tasks: US-003, US-004
  All blocked by unmet dependencies or locked mutex
  
  US-003 needs: US-001 (failed)
  US-004 needs: US-003 (blocked)
```

---

## Example Analysis

**Input tasks.yaml:**
```yaml
tasks:
  - id: A
    dependsOn: []
    mutex: [db-migrations]
  - id: B
    dependsOn: []
    mutex: []
  - id: C
    dependsOn: [A]
    mutex: [db-migrations]
  - id: D
    dependsOn: [B, C]
    mutex: []
```

**Output:**
```
DAG Analysis:
  Total tasks: 4
  Max parallelism: 2 (A and B can run together)
  Critical path: A → C → D (3 steps)
  
  Mutex contention:
    db-migrations: A, C must run sequentially
    
  Recommended execution waves:
    Wave 1: A, B (parallel)
    Wave 2: C (after A)
    Wave 3: D (after B, C)
```
