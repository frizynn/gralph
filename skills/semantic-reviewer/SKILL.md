---
name: semantic-reviewer
description: "Review integrated code for semantic and design issues. Use after merging task branches to detect inconsistencies. Triggers on: review integration, semantic review, check design consistency."
---

# Semantic Reviewer

Review integrated code for semantic issues, design inconsistencies, and potential bugs.

---

## The Job

1. Analyze diff between integration branch and base
2. Read task reports for context
3. Identify semantic/design issues
4. Classify by severity
5. Output structured review report

**Do NOT:** schedule tasks, implement fixes, or merge code.

---

## Review Scope

What to check:
- API consistency across tasks
- Type compatibility
- Naming conventions
- Error handling patterns
- Dead code from partial changes
- Broken references

What NOT to check:
- Code style (that's linting)
- Test coverage (separate concern)
- Performance (unless obvious regression)

---

## Issue Severity

| Level | Name | Description | Action |
|-------|------|-------------|--------|
| 1 | `blocker` | Breaks compilation or runtime | Must fix before merge |
| 2 | `critical` | Logic error, data corruption risk | Should fix before merge |
| 3 | `warning` | Inconsistency, tech debt | Consider fixing |
| 4 | `info` | Suggestion, style | Optional |

---

## Review Report Format

```json
{
  "version": 1,
  "reviewedCommits": ["abc123", "def456"],
  "summary": {
    "blockers": 1,
    "critical": 2,
    "warnings": 3,
    "info": 1
  },
  "issues": [
    {
      "id": "ISSUE-001",
      "severity": "blocker",
      "title": "Type mismatch in auth middleware",
      "file": "src/auth/middleware.ts",
      "line": 42,
      "description": "Function expects User but receives UserDTO",
      "evidence": "middleware.ts imports User from auth, but routes pass UserDTO",
      "suggestedFix": "Update middleware to accept UserDTO or convert in route",
      "relatedTasks": ["AUTH-002", "AUTH-003"]
    }
  ],
  "designConflicts": [
    {
      "pattern": "Error handling",
      "description": "AUTH-002 throws exceptions, AUTH-003 returns Result types",
      "recommendation": "Standardize on one pattern"
    }
  ],
  "followUps": [
    "Add integration tests for auth flow",
    "Document error handling convention"
  ]
}
```

---

## Issue Categories

### 1. Type/Interface Mismatches

```
ISSUE: Type mismatch
File: src/api/users.ts:25
Description: getUser returns Promise<User> but caller expects UserDTO
Evidence: 
  - src/api/users.ts defines getUser(): Promise<User>
  - src/routes/profile.ts calls getUser() and passes to renderProfile(UserDTO)
Suggested fix: Add toDTO() conversion or align types
```

### 2. Broken References

```
ISSUE: Missing export
File: src/auth/index.ts
Description: validateToken is used but not exported
Evidence:
  - src/middleware/auth.ts imports { validateToken }
  - src/auth/index.ts does not export validateToken
Suggested fix: Add export { validateToken } to auth/index.ts
```

### 3. Design Inconsistencies

```
ISSUE: Inconsistent error handling
Files: src/auth/**, src/users/**
Description: Mixed error handling patterns
Evidence:
  - auth/ throws AuthError exceptions
  - users/ returns { error: string } objects
Suggested fix: Standardize on exceptions or Result types
```

### 4. Dead Code

```
ISSUE: Unused function
File: src/utils/helpers.ts:50
Description: formatUser() no longer called after refactor
Evidence: 
  - Defined in helpers.ts
  - No imports found in codebase
Suggested fix: Remove or document if intentionally kept
```

---

## Output Example

```
=== Semantic Review Report ===

Reviewed: 5 tasks, 23 files changed

Summary:
  🔴 1 blocker
  🟠 2 critical  
  🟡 3 warnings
  
Blockers (must fix):
  ISSUE-001: Type mismatch in auth middleware
    src/auth/middleware.ts:42
    Fix: Convert User to UserDTO before passing

Critical (should fix):
  ISSUE-002: Missing null check in getUser
    src/api/users.ts:15
    Fix: Add early return if user not found
    
  ISSUE-003: Inconsistent error codes
    Multiple files
    Fix: Standardize on HTTP status codes

Warnings:
  ISSUE-004: Duplicate validation logic
  ISSUE-005: Unused import in routes.ts
  ISSUE-006: Missing JSDoc on public API

Recommended follow-up tasks:
  - FIX-001: Resolve auth type mismatch (blocker)
  - FIX-002: Add null safety to user API (critical)
  - TECH-001: Standardize error handling (critical)
```

---

## Fix Task Generation

For blockers and critical issues, generate fix tasks:

```yaml
- id: FIX-001
  title: "Fix type mismatch in auth middleware"
  completed: false
  dependsOn: []
  mutex: ["contract:auth-api"]
  touches: ["src/auth/middleware.ts", "src/types/user.ts"]
  mergeNotes: "This fixes ISSUE-001 from review"
```
