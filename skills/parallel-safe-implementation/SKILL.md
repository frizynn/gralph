---
name: parallel-safe-implementation
description: "Guidelines for implementing tasks safely in parallel execution. Use when working on a task in Ralph parallel mode to avoid conflicts. Triggers on: implement task safely, parallel mode, avoid conflicts."
---

# Parallel-Safe Implementation

Guidelines for implementing tasks in Ralph parallel mode without causing conflicts.

---

## The Job

1. Implement assigned task completely
2. Stay within declared `touches` paths
3. Respect mutex boundaries
4. Avoid undeclared hotspots
5. Commit atomically with clear messages

**Do NOT:** modify DAG, schedule tasks, merge branches, or review other work.

---

## Core Rules

### 1. Stay in Your Lane

Only modify files within your task's `touches` declaration:

```yaml
touches: ["src/auth/**", "tests/auth/**"]
```

**Allowed:** `src/auth/middleware.ts`, `tests/auth/login.test.ts`
**Forbidden:** `src/api/routes.ts`, `package.json`

### 2. Respect Mutex

If your task has `mutex: ["db-migrations"]`, you have exclusive access to that resource. Other tasks with the same mutex will wait.

### 3. Avoid Hotspots

Never touch these without explicit mutex:
- `package.json` / `package-lock.json` → mutex: `lockfile`
- Database migrations → mutex: `db-migrations`
- Route configuration → mutex: `router`
- Global config files → mutex: `global-config`

---

## Implementation Checklist

Before starting:
- [ ] Read task description and acceptance criteria
- [ ] Check `touches` for allowed paths
- [ ] Check `mutex` for exclusive resources
- [ ] Check `dependsOn` to understand available interfaces

While implementing:
- [ ] Make small, focused changes
- [ ] Avoid large refactors outside task scope
- [ ] Don't rename shared types/interfaces unless task requires it
- [ ] Test your changes in isolation

Before committing:
- [ ] Verify only allowed files changed
- [ ] Run relevant tests
- [ ] Write clear commit message referencing task ID

---

## Commit Discipline

### Good Commits
```
AUTH-002: Add auth middleware

- Implement JWT validation
- Add role-based access control
- Add unit tests for middleware
```

### Bad Commits
```
WIP

various fixes
```

---

## Conflict Prevention

### Do
- Import existing modules, don't copy code
- Use existing patterns from codebase
- Add new files instead of heavily modifying shared ones
- Coordinate interface changes via contracts

### Don't
- Refactor unrelated code
- Change file structure outside scope
- Modify global types without contract declaration
- Add dependencies without lockfile mutex

---

## Touched Areas Summary

At task completion, report what you changed:

```
Task AUTH-002 completed
Files changed: 4
  + src/auth/middleware.ts (new)
  + src/auth/roles.ts (new)
  ~ src/auth/index.ts (export added)
  + tests/auth/middleware.test.ts (new)
  
Within declared touches: ✓
Mutex used: contract:auth-api
```

---

## Safety Checklist Output

```
Pre-implementation safety check:
  ✓ touches: ["src/auth/**"] - clear scope
  ✓ mutex: ["contract:auth-api"] - exclusive access
  ✓ dependsOn: ["AUTH-001"] - user table available
  
  Hotspots to avoid:
    ✗ package.json (no lockfile mutex)
    ✗ db/migrations/** (no db-migrations mutex)
    
  Ready to implement safely
```
