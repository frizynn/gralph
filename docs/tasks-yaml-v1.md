# tasks.yaml v1 Schema

Strict schema for Ralph parallel execution with DAG-based scheduling.

## Format

```yaml
version: 1
tasks:
  - id: US-001
    title: "Task description"
    completed: false
    dependsOn: []
    mutex: []
```

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `version` | number | Must be `1` |
| `id` | string | Unique task identifier |
| `title` | string | Human-readable description |
| `completed` | boolean | `true` when task is done |
| `dependsOn` | array | Task IDs that must complete first |
| `mutex` | array | Mutex names from catalog |

## Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `touches` | array | Paths/globs this task modifies |
| `mergeNotes` | string | Hints for conflict resolution |

## Validation Rules

1. `version` must equal `1`
2. `id` must be unique across all tasks
3. `dependsOn` must reference existing task IDs
4. `mutex` must exist in `mutex-catalog.json` or match `contract:*` pattern
5. No circular dependencies allowed

## Mutex Catalog

See `mutex-catalog.json` for valid mutex names:
- `db-migrations` - Database changes
- `lockfile` - Package lock files
- `router` - Route configuration
- `global-config` - Global config files
- `contract:*` - Interface contracts (pattern)

## Example

```yaml
version: 1
tasks:
  - id: AUTH-001
    title: Add users table
    completed: false
    dependsOn: []
    mutex: ["db-migrations"]
    
  - id: AUTH-002
    title: Create auth middleware
    completed: false
    dependsOn: ["AUTH-001"]
    mutex: ["contract:auth-api"]
    mergeNotes: "Keep backward compatibility with existing endpoints"
```

## Auto-Generation

If you have a `PRD.md` file but no `tasks.yaml`, Ralph will automatically generate it:

```bash
./ralph.sh --yaml tasks.yaml --parallel
# Ralph detects PRD.md and generates tasks.yaml
```
