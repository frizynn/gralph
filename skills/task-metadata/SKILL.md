---
name: task-metadata
description: "Generate and validate task metadata for Ralph parallel execution. Use when creating tasks.yaml v1 files, validating task dependencies, or checking mutex usage. Triggers on: create task metadata, validate tasks yaml, check task dependencies."
---

# Task Metadata Generator

Create and validate task metadata for parallel-safe execution in Ralph.

---

## The Job

1. Generate or validate `tasks.yaml` v1 metadata
2. Ensure unique task IDs
3. Validate dependencies exist
4. Check mutex against catalog
5. Output clear errors for invalid metadata

**Do NOT:** schedule tasks, merge branches, or review design.

---

## tasks.yaml v1 Format

```yaml
version: 1
tasks:
  - id: US-001
    title: "Short descriptive title"
    completed: false
    dependsOn: []           # Array of task IDs that must complete first
    mutex: []               # Array of mutex names from catalog
    touches: []             # Optional: paths/globs this task modifies
    contracts:              # Optional: interface contracts
      produces: []
      consumes: []
    mergeNotes: ""          # Optional: hints for conflict resolution
    verify: []              # Optional: verification commands
```

---

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier (e.g., US-001, TASK-1) |
| `title` | string | Human-readable task name |
| `completed` | boolean | Task completion status |
| `dependsOn` | array | Task IDs that must complete before this one |
| `mutex` | array | Mutex names from the catalog |

---

## Mutex Catalog

Valid mutex names (check `mutex-catalog.json`):
- `db-migrations` - Database schema changes
- `lockfile` - Package lock files (package-lock.json, yarn.lock, etc.)
- `router` - Route configuration files
- `global-config` - Global configuration files
- `contract:*` - Interface contracts (e.g., `contract:auth-api`)

---

## Validation Checklist

When validating tasks.yaml:

- [ ] `version: 1` is present
- [ ] Every task has `id`, `title`, `completed`, `dependsOn`, `mutex`
- [ ] All `id` values are unique
- [ ] All `dependsOn` references exist as task IDs
- [ ] No circular dependencies
- [ ] All `mutex` values exist in catalog

---

## Output Format

### Valid Metadata
```
✓ tasks.yaml v1 valid
  - 5 tasks
  - 3 unique mutex
  - 2 dependency chains
```

### Invalid Metadata
```
✗ tasks.yaml validation failed:
  - Line 12: Duplicate id "US-001"
  - Line 25: dependsOn "US-999" not found
  - Line 30: Unknown mutex "invalid-mutex"
  - Cycle detected: US-002 → US-003 → US-002
```

---

## Example

**Input request:** "Create metadata for a user auth feature"

**Output:**
```yaml
version: 1
tasks:
  - id: AUTH-001
    title: Add users table migration
    completed: false
    dependsOn: []
    mutex: ["db-migrations"]
    touches: ["db/migrations/**"]
    
  - id: AUTH-002
    title: Create auth middleware
    completed: false
    dependsOn: ["AUTH-001"]
    mutex: ["contract:auth-api"]
    touches: ["src/auth/**"]
    contracts:
      produces: ["contract:auth-api"]
      consumes: []
```
