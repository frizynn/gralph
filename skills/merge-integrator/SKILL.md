---
name: merge-integrator
description: "Merge task branches and resolve conflicts for Ralph parallel execution. Use when merging completed task branches or resolving git conflicts. Triggers on: merge branches, resolve conflict, integration merge."
---

# Merge Integrator

Merge task branches and resolve conflicts intelligently using task context.

---

## The Job

1. Merge branches in dependency order
2. Resolve conflicts using mergeNotes
3. Preserve functionality from both sides
4. Validate merged code compiles
5. Provide rollback guidance if needed

**Do NOT:** schedule tasks, implement features, or review design.

---

## Merge Order

Always merge in topological order (dependencies first):

```
Merge order for tasks:
  1. US-001 (no deps) ✓
  2. US-002 (no deps) ✓
  3. US-003 (depends on US-001) → merge now
  4. US-004 (depends on US-002, US-003) → after US-003
```

---

## Conflict Resolution

### Step 1: Identify Conflicts

```bash
git merge branch-name
# If conflict:
git diff --name-only --diff-filter=U
```

### Step 2: Read mergeNotes

Check both tasks' `mergeNotes` for guidance:

```yaml
# Task US-003
mergeNotes: "Auth middleware uses new user schema from US-001"

# Task US-007
mergeNotes: "Keep both route handlers, don't overwrite"
```

### Step 3: Resolve Intelligently

For each conflicted file:

1. Read the conflict markers
2. Understand what each side adds
3. Combine both changes, don't just pick one
4. Remove all `<<<<<<<`, `=======`, `>>>>>>>` markers
5. Verify syntax is valid

### Step 4: Complete Merge

```bash
git add <resolved-files>
git commit --no-edit
```

---

## Common Conflict Patterns

### Pattern: Both Add to Same Array/Object

```typescript
// <<<<<<< HEAD
export { userRoutes } from './users';
// =======
export { authRoutes } from './auth';
// >>>>>>> branch

// Resolution: Keep both
export { userRoutes } from './users';
export { authRoutes } from './auth';
```

### Pattern: Both Modify Same Function

```typescript
// Check if changes are to different parts
// If yes: combine both modifications
// If no: use mergeNotes for priority, or combine logic
```

### Pattern: Import Conflicts

```typescript
// Usually safe to keep all imports
// Remove duplicates
// Check for naming conflicts
```

---

## Merge Plan Output

```
Merge plan for 5 branches:

Phase 1 (independent):
  ✓ ralph/agent-1-us-001 → main
  ✓ ralph/agent-2-us-002 → main

Phase 2 (after deps):
  → ralph/agent-3-us-003 → main
    Expected conflicts: none (different files)
    
  → ralph/agent-4-us-004 → main
    Potential conflict: src/routes/index.ts
    Resolution hint: "Keep all route exports"

Phase 3:
  → ralph/agent-5-us-005 → main
    Depends on: US-003, US-004
```

---

## Rollback Guidance

If merge fails completely:

```
Merge failed: ralph/agent-3-us-003

Rollback steps:
  1. git merge --abort
  2. Review conflicts in: src/auth/index.ts
  3. Options:
     a) Manually resolve and retry
     b) Run task again with updated context
     c) Create fix task for conflict resolution
     
Branch preserved: ralph/agent-3-us-003
No changes made to main
```

---

## Validation After Merge

After each merge:

```bash
# Check syntax
npm run typecheck  # or equivalent

# Quick test
npm test -- --bail

# If fails, rollback
git reset --hard HEAD~1
```

---

## Output Format

### Successful Merge
```
✓ Merged ralph/agent-1-us-001
  Files: 3 changed
  Conflicts: 0
  Validation: passed
```

### Conflict Resolved
```
✓ Merged ralph/agent-3-us-003
  Files: 5 changed
  Conflicts: 1 (resolved using mergeNotes)
    - src/routes/index.ts: combined exports
  Validation: passed
```

### Merge Failed
```
✗ Failed ralph/agent-4-us-004
  Conflicts: 2 unresolved
    - src/db/schema.ts: incompatible changes
    - src/types/user.ts: type mismatch
  Action: manual resolution required
  Branch preserved for review
```
