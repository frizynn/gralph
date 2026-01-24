# TODO

## Architecture & Communication
- [ ] Pass reports and progress context between agents.
- [ ] Implement "Allow All" permission mode: enable agents to automatically trigger and fix OS or environment-level failures.
- [ ] Audit core requirements and remove unnecessary complexity.

## Execution & Parallelism
- [ ] Improve parallelization: Currently, execution is mostly sequential.
- [ ] Define explicit contracts between tasks to ensure independence and avoid interference during parallel development.

## New Features
- [ ] Implement support for reading and resolving repository issues.
- [ ] Add direct task execution CLI:
    - **Single task**:
      ```bash
      ./gralph.sh "add dark mode"
      ./gralph.sh "fix the auth bug"
      ```
    - **Task list**:
      ```bash
      ./gralph.sh              # defaults to PRD.md
      ./gralph.sh --prd tasks.md
      ```
