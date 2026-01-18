# PRD: Ralph Parallel vNext (DAG + Metadata + Coordinación Central + Reviewer)

## 1. Introducción / Overview

Queremos evolucionar `gralph.sh` para soportar **ejecución paralela robusta** de tareas, minimizando conflictos y reduciendo la probabilidad de fallos semánticos cuando múltiples agentes trabajan a la vez.

El sistema actual ya soporta `--parallel` creando **worktrees aislados** por agente y luego intentando mergear ramas. Esto funciona para paralelismo “best-effort”, pero no resuelve bien:

- Dependencias entre tareas más allá de un `parallel_group`
- Exclusión de recursos compartidos (“hotspots”: migraciones, lockfiles, routers, config global)
- Cambios de “contratos” (APIs, schemas, tipos) que rompen consumidores sin generar conflicto de `git`
- Necesidad de un **review semántico** post-integración (diseño inconsistente, invariantes rotas) y loop de reparación

Esta PRD define un plan **por etapas** para evitar sobrediseño y llegar a un sistema confiable de forma incremental.

## 2. Goals (Objetivos)

- Permitir paralelizar tareas **cuando sea seguro**, y **serializar** cuando exista riesgo alto.
- Modelar explícitamente dependencias en un **DAG de tareas** (no de archivos).
- Introducir metadata por tarea para:
  - dependencias duras,
  - “touched areas” (`touches`) como heurística de conflicto textual,
  - contratos producidos/consumidos para detectar conflictos semánticos.
- Añadir “gates” de verificación para no marcar tareas como completas si:
  - no hay commits,
  - tocó fuera de lo permitido (cuando aplique),
  - no pasan checks/tests.
- Integrar una etapa **Reviewer** post-merge (en rama de integración) que genere un reporte estructurado con problemas semánticos/diseño y cree tareas de reparación.

## 3. Non-Goals (Fuera de alcance)

- Garantía perfecta de ausencia de bugs semánticos (solo se puede mitigar con gates + tests + reviewer + loops).
- Reemplazar Git como fuente de verdad (seguiremos usando branches/commits/merges).
- Implementar un sistema distribuido de locking (Redis/etcd) en la primera iteración; comenzaremos con locks locales coordinados por el proceso.

## 4. Usuarios / Stakeholders

- **Usuario principal**: desarrollador que corre `./gralph.sh` para ejecutar un PRD.
- **Stakeholders**: mantenedores del repo, equipo que consume PRs, pipeline CI.

## 5. Conceptos clave (definiciones)

- **DAG de tareas**: nodos = tareas; edges = `dependsOn` (dependencia dura).
- **Touches**: lista de paths/módulos estimados; sirve como heurística para evitar solapes textuales, no como garantía.
- **Contrato**: interfaz compartida (API, schema, tipos, eventos). Puede cambiar de forma compatible o breaking.
- **Coordinator**: componente que construye/valida el DAG, planifica la ejecución, recopila resultados y coordina merge/validación.
- **Reviewer**: etapa posterior que analiza cambios integrados (diffs + reportes por tarea) para detectar problemas semánticos/diseño y generar tareas correctivas.

## 6. Arquitectura (alto nivel)

```mermaid
flowchart TD
  prdInput[TaskSource(PRD/YAML)] --> validate[ValidateMetadataAndDAG]
  validate --> plan[PlanSchedule(readyQueue)]
  plan --> runWorkers[RunWorkersInParallel]
  runWorkers --> gates[PerTaskGates(commits,allowedPaths,tests)]
  gates --> integrate[IntegrationBranchMerge]
  integrate --> globalGates[GlobalGates(tests,lint,contracts)]
  globalGates --> reviewer[ReviewerSemanticDesignReview]
  reviewer --> fixTasks[GenerateFixTasks]
  fixTasks --> plan
  globalGates --> finalize[Finalize(MergeToBaseOrPRs)]
```

## 7. Formato de tareas (fuente recomendada)

### 7.1. Formato recomendado: `tasks.yaml` (v1)

Para soportar DAG + metadata, se recomienda introducir un archivo YAML con un esquema versionado. Ejemplo mínimo:

```yaml
version: 1
tasks:
  - id: US-001
    title: Add user table migration
    completed: false
    dependsOn: []
    touches: ["db/migrations/**", "src/db/**"]
    contracts:
      produces: ["contract:db-schema"]
      consumes: []
    mergeNotes: "Si hay conflicto en migraciones, preferir orden cronológico y asegurar que tests DB pasen."
    verify:
      - "tests"
      - "lint"
  - id: US-002
    title: Add auth middleware
    completed: false
    dependsOn: ["US-001"]
    touches: ["src/auth/**", "src/middleware/**"]
    contracts:
      produces: ["contract:auth-api"]
      consumes: ["contract:db-schema"]
    mergeNotes: "Mantener compatibilidad: no romper llamadas existentes; si cambian firmas, actualizar consumidores."
    verify:
      - "tests"
```

### 7.2. Soporte de PRD Markdown (opcional / posterior)

Podemos mantener PRD Markdown como input humano, pero para paralelismo seguro el sistema necesita metadata estructurada. Dos opciones:

- Convertidor PRD.md → tasks.yaml (semi-automático, con revisión)
- Enriquecer el PRD con bloques YAML por tarea (menos recomendado por parsing)

## 8. Etapas / Complejidad incremental (evitar sobrediseño)

Cada etapa incluye:
- Alcance
- Entregables
- Criterios de aceptación
- Checklist de tareas (para marcar progreso)

### Etapa 1 (MVP): Metadata + DAG Validation + Scheduler básico (sin contracts enforcement)

**Objetivo**: construir el DAG de tareas y planificar paralelismo respetando `dependsOn`, sin cambiar demasiado el comportamiento de ejecución.

**Alcance**:
- Introducir `tasks.yaml` v1 (solo YAML, no PRD.md).
- Implementar validación estática:
  - ids únicos
  - `dependsOn` válido
  - sin ciclos
- Scheduler central:
  - `readyQueue` por dependencias
  - límite de concurrencia `--max-parallel`
- Ejecución en worktrees (como hoy) y reporte de estado básico.

**Criterios de aceptación**:
- [ ] Con un `tasks.yaml` con dependencias, solo se ejecutan en paralelo tareas sin `dependsOn` pendientes.
- [ ] El sistema rechaza DAGs con ciclos y muestra un error claro.

**Checklist (Etapa 1)**:
- [ ] Definir `tasks.yaml` v1 schema (documentado).
- [ ] Añadir parser YAML y validación (ids, cycles, dependsOn).
- [ ] Implementar scheduler: ready/running/done/failed.
- [ ] Integrar scheduler con el runner paralelo existente (`run_parallel_tasks`).
- [ ] Logging: estado por tarea (started/done/failed) y por qué se bloquea (dep).

---

### Etapa 2: Task Reports (artefactos) + Gates por tarea

**Objetivo**: reducir falsos positivos de “done” y habilitar una etapa reviewer posterior con contexto estructurado.

**Alcance**:
- Cada worker produce un **task report** estructurado por tarea (JSON o Markdown).
- Gates por tarea antes de marcar `completed`:
  - hay commits nuevos vs base
  - (si definido) no tocó fuera de `allowedToModify`
  - (si definido) ejecutó/verificó checks mínimos

**Task report (v1)**:
- `taskId`, `branch`, `worktreeDir`
- `changedFiles` (lista)
- `summary` (qué se hizo)
- `designDecisions` (lista corta)
- `contractsChanged` (si aplica)
- `verification` (qué se corrió, resultados)
- `risksAndFollowups`

**Criterios de aceptación**:
- [ ] Por cada tarea completada, existe un artefacto `task-report` legible.
- [ ] No se marca una tarea como done si no hay commits.
- [ ] Si se define `allowedToModify`, tocar fuera bloquea la tarea (status “needs-review”).

**Checklist (Etapa 2)**:
- [ ] Definir formato `task-report` v1 (JSON recomendado).
- [ ] Modificar prompt de workers para exigir `task-report` + commits.
- [ ] Implementar gate: commit count > 0.
- [ ] Implementar gate opcional: allowedToModify vs changedFiles.
- [ ] Guardar reportes en una carpeta de artefactos por run (ej. `artifacts/run-YYYYMMDD-HHMM/`).

---

### Etapa 3: Integración en rama temporal + merge automático con fallback a Merge Agent

**Objetivo**: no ensuciar la base con merges rotos y tener una integración determinista.

**Alcance**:
- Crear una **integration branch** (o worktree) donde se aplican merges.
- Merge automático en orden topológico (o por waves/batches).
- Si hay conflicto:
  - usar `mergeNotes` de las tareas implicadas como contexto,
  - invocar un **merge agent** (una ejecución de AI dedicada) para resolver,
  - si no resuelve, dejar la rama en estado “needs-human”.

**Criterios de aceptación**:
- [ ] En modo paralelo, los merges ocurren en una rama de integración, no directamente en base.
- [ ] Si hay conflicto de `git`, el sistema intenta resolución con merge agent usando `mergeNotes`.
- [ ] Si no se puede resolver, el sistema falla de forma segura y deja instrucciones claras.

**Checklist (Etapa 3)**:
- [ ] Implementar creación/uso de rama de integración.
- [ ] Merge ordenado + registro de merges aplicados.
- [ ] Integración de `mergeNotes` en prompt de resolución.
- [ ] Política de fallback segura (abort/stop) si sigue habiendo conflictos.

---

### Etapa 4: Contracts (produces/consumes) + Contract Gates (mínimos)

**Objetivo**: reducir conflictos semánticos detectando cambios de interfaz y forzando compatibilidad o migración.

**Alcance**:
- Formalizar `contracts.produces/consumes` en tasks.yaml.
- Gate mínimo:
  - si una tarea produce `contract:X`, tareas que consumen `contract:X` deben depender de ella (o el scheduler lo infiere).
- (Opcional, incremental): “contract artifacts” versionados (docs/schema) y diff básico.

**Criterios de aceptación**:
- [ ] Si una tarea consume un contrato, no se ejecuta hasta que exista la tarea productora (o contrato base).
- [ ] Cambios a contratos pueden requerir coordinación adicional para evitar carreras.

**Checklist (Etapa 4)**:
- [ ] Especificar catálogo de contratos (nombres).
- [ ] Añadir validación: consumes debe existir (o estar en baseline).
- [ ] Inferir edges: producer → consumer (si no está en dependsOn, warning o auto-add).

---

### Etapa 5: Reviewer semántico/diseño + Loop automático de reparación

**Objetivo**: detectar problemas semánticos y decisiones de diseño incompatibles tras integrar.

**Alcance**:
- Reviewer agent lee:
  - diff de integration branch vs base,
  - task reports por tarea,
  - (si existe) artefactos de contratos.
- Produce `review-report` estructurado:
  - issues (severity, description, evidence, suggested fix)
  - “design conflicts” (incompatibilidades de patrones)
  - follow-ups recomendados
- Coordinator transforma issues “blocker” en nuevas tareas `fix-*` y las reinyecta al DAG.

**Criterios de aceptación**:
- [ ] Se genera un review report por run de paralelo.
- [ ] Los issues “blocker” generan tareas correctivas automáticamente.
- [ ] El loop puede re-ejecutar solo lo necesario (fix tasks), no todo el DAG.

**Checklist (Etapa 5)**:
- [ ] Definir formato `review-report` v1.
- [ ] Implementar reviewer agent step post-global-gates.
- [ ] Implementar generación de “fix tasks” a partir del review report.
- [ ] Implementar política: cuántos ciclos máximo (para evitar loops infinitos).

## 9. Cambios propuestos a `gralph.sh` (resumen)

- Nuevo modo de input: `--tasks-yaml tasks.yaml` (o reutilizar `--yaml` con esquema v1).
- Nuevo flujo paralelo:
  - validate → schedule → runWorkers → perTaskGates → integrationMerge → globalGates → reviewer → fixLoop → finalize
- Cambios al worker prompt:
  - exigir `task-report` + commits
  - respetar `allowedToModify`/touches/contracts

## 10. Skills nuevas (propuesta)

Estas skills son “instructions bundles” para mejorar consistencia entre motores (Claude/Codex/OpenCode/Cursor):

- `task-metadata`: generar/validar metadata de tareas (ids, dependsOn, touches, contracts, mergeNotes).
- `dag-planner`: construir/validar DAG, calcular paralelismo seguro, explicar bloqueos.
- `parallel-safe-implementation`: guías para que un worker respete límites (no tocar hotspots fuera de touches, no refactors masivos, etc.).
- `merge-integrator`: merge automático + resolución con mergeNotes/contracts + gates.
- `semantic-reviewer`: generar review-report estructurado y accionable; identificar conflictos semánticos/diseño.

## 11. Riesgos & mitigaciones

- **Metadata incorrecta**: mitigación con validación + warnings + aprendizaje (catálogo de contracts).
- **Flakiness por recursos externos**: añadir `requiresEnv` específicos (ej. `local-db`) o ejecutar tests aislados.
- **Overhead de coordinación**: empezar con pocos contracts; instrumentar métricas de contención.
- **Loops reviewer→fix infinito**: límite de iteraciones y severidad mínima para auto-fix.

## 12. Métricas de éxito

- Tiempo total de run vs secuencial (latencia).
- Cantidad de conflictos `git` (antes/después).
- Cantidad de fallos post-merge (tests rotos).
- Cantidad de issues semánticos detectados por reviewer y su tasa de reparación.
- Contención por dependencias (tiempo esperando en readyQueue).
