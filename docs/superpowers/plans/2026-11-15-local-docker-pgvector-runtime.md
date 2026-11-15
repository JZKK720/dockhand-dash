# Local Docker + pgvector Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Dockhand on this Windows machine as a containerized stack (dockhand + PostgreSQL 16 with pgvector), and add a working pgvector-backed semantic search over container events — implemented so it degrades safely to SQLite.

**Architecture:** The Docker runtime is delivered as a new compose file that pins `pgvector/pgvector:pg16` (the official `postgres:16-alpine` image has no `vector` extension) and wires the host's Docker socket into the app container. The pgvector feature is delivered as a PG-only `vector` column on `container_events`, with a parallel no-op SQLite migration, plus a server-side semantic-search API. The app's schema is loaded dynamically per dialect, so a PG-only column type needs no SQLite changes.

**Tech Stack:** SvelteKit 2 / Svelte 5, Drizzle ORM 0.45.2, PostgreSQL 16 + pgvector 0.8.7, `postgres` 3.4.8 (postgres-js), Docker Compose v5.7.0, Bun 1.4.4 (test runner), Node 24.22.1 (runtime image).

**Spec:** This plan is self-contained. It supersedes the need for a separate spec doc; every requirement below is stated as a Global Constraint or a Review Focus line.

## Current State (verified 2026-11-15)

**Nothing is running.** This plan stands the stack up **for the first time** — it does not modify an existing deployment.

| Check | Result |
|---|---|
| `docker ps -a` (desktop-linux and default contexts) | Only `cloudflared` (a Cloudflare tunnel container). No container named `dockhand`. |
| Ports 4131, 3000, 5432 | Nothing listening. All free. |
| Dockhand process | No `node`/`bun` process running `server.js` or `build/index.js`. |
| `fnsys/dockhand:latest` image | Present in the image list only because it was pulled during plan verification. **It has never been run.** |
| `cloudflared` | On the default `bridge` network with no other container attached. Its ingress config is server-side (token-based tunnel), so it is not proxying a local Dockhand. |

**Therefore Task 5 is not a duplicate of anything** — it creates the runtime that does not exist yet. If a Dockhand instance turns out to exist somewhere this host's Docker cannot see (another machine, a remote host, a VM), Task 5 would create a second instance and port 4131 could collide; check before running it.

## Global Constraints

These apply to every task. Copy them verbatim into any file you create.

- **Repo:** `C:\Users\NEXS\github-pr\dockhand-dash` (branch `main`, at `c257f46` = upstream `v1.0.57`). Do NOT rebase or force-push `main`.
- **Dialect lockstep:** the SQLite and Postgres schemas are two separate files that must be edited together: `src/lib/server/db/schema/index.ts` (SQLite) and `src/lib/server/db/schema/pg-schema.ts` (Postgres). Both currently define exactly **39 tables** and must keep the same table names in the same order.
- **Migration lockstep:** every migration is authored twice — `drizzle/NNNN_name.sql` (SQLite) and `drizzle-pg/NNNN_name.sql` (Postgres) — plus an entry in `drizzle/meta/_journal.json` and `drizzle-pg/meta/_journal.json`, plus a snapshot `drizzle/meta/NNNN_snapshot.json` and `drizzle-pg/meta/NNNN_snapshot.json`.
- **Next migration number:** `0023`. The current highest is `0022_add_session_oidc_sub_sid.sql` in both directories.
- **SQL identifier quoting:** SQLite uses backticks `` `col` ``; Postgres uses double quotes `"col"`.
- **`ALTER TABLE ADD`:** SQLite is ``ALTER TABLE `t` ADD `c` type;`` (no `COLUMN` keyword); Postgres is `ALTER TABLE "t" ADD COLUMN "c" type;`.
- **Statement separator:** `--> statement-breakpoint` on its own line, in both dialects.
- **Postgres table PK:** `serial PRIMARY KEY NOT NULL`; SQLite: `integer PRIMARY KEY AUTOINCREMENT NOT NULL`.
- **Postgres FKs:** declared as a separate `ALTER TABLE ... ADD CONSTRAINT ... REFERENCES "public"."parent"("id") ON DELETE cascade ON UPDATE no action;` after the `CREATE TABLE`, not inline.
- **Postgres index:** `CREATE INDEX x ON t USING btree (col);`; SQLite: `CREATE INDEX x ON t (col);`.
- **Postgres timestamps:** `timestamp DEFAULT now()`; SQLite: `text DEFAULT CURRENT_TIMESTAMP`.
- **Migration runner:** `src/lib/server/db/drizzle.ts` runs `runMigrations()` at module load (top-level `await seedDatabase()`), using `./drizzle` for SQLite and `./drizzle-pg` for Postgres. It verifies each `.sql` file by SHA-256 against `__drizzle_migrations` (Postgres table lives in the `drizzle` schema, `drizzle.__drizzle_migrations`). A migration file without a matching journal entry will NOT run.
- **Dialect switch:** `src/lib/server/db/drizzle.ts` exports `isPostgres` / `isSqlite`, derived from `process.env.DATABASE_URL` starting with `postgres://` or `postgresql://`. Absence of `DATABASE_URL` means SQLite.
- **Schema loading is dynamic:** `initializeDatabase()` imports `./schema/index.js` (SQLite) or `./schema/pg-schema.js` (Postgres) at runtime. A Postgres-only column type therefore cannot break the SQLite path.
- **Vector column type:** drizzle-orm 0.45.2 ships `vector` from `drizzle-orm/pg-core` (verified: `node -e "require('drizzle-orm/pg-core').vector"` → `function`). Signature: `vector('col_name', { dimensions: N })`. Import it as `import { vector } from 'drizzle-orm/pg-core';` (re-exported via `./columns/index.js`).
- **`sql.unsafe` does not exist** in drizzle-orm 0.45.2 (verified: `typeof sql.unsafe === 'undefined'`; the only `sql` members are `empty`, `fromList`, `raw`, `join`, `identifier`, `placeholder`, `param`). **Never write `sql.unsafe(...)`.** Use the `sql` template tag — Drizzle binds template parameters, and a `$1` placeholder inside a runtime-built string is never filled in.
- **`db.execute()` returns the rows directly as an array** on the postgres-js driver (verified: `Array.isArray(result) === true`, `result.length === 2`, `result[0]` is the first row, `'rows' in result === false`). It does **not** return `{ rows }`. Writing `result.rows` yields `undefined`.
- **Embedding dimensions:** `768` (fixed by this plan; see Task 1).
- **No AI/LLM dependency.** This plan stores embeddings produced by an external caller. It adds no model SDK, no API key handling, and no network calls to any LLM provider.
- **Test runner:** `bun test tests/`. Import style is `import { describe, test, expect } from 'bun:test';`. Indentation is tabs, strings single-quoted, semicolons required.
- **`$lib` aliases resolve under `bun test`** in this repo (verified: `tests/stack-path-hints.test.ts` imports a route that uses `$lib/server/stacks`). Relative imports (`'../src/lib/utils/...'`) are the norm in `tests/`, but `$lib` works too.
- **`$lib/server/db/drizzle` CANNOT be imported under `bun test` on this machine.** It runs a top-level `await seedDatabase()` and loads `better-sqlite3`, whose native addon does not build on Windows/Node 26 (`node-gyp` fails; the `Dockerfile` pins Node 24.22.1 for exactly this reason). Importing it fails with `Cannot find package 'better-sqlite3'`. **No module under test may import it at module scope** — read `process.env.DATABASE_URL` for the dialect check instead, and import the database module dynamically inside the function that needs it.
- **`$lib/server/db/schema/pg-schema.ts` and `.../schema/index.ts` ARE safe to import under `bun test`** (verified: each loads and exports 39 tables).
- **Pre-existing test failures:** on this Windows host, `bun test tests/` reports **191 failures / 6370 pass / 5 skip** at baseline (`c257f46`). Verified identical in a pristine worktree at `c257f46` with none of this plan's changes applied, so these are pre-existing and unrelated. All of them are POSIX-only assertions that fail on Windows path separators or POSIX shell semantics (e.g. expecting `/app/data/.restic-cache` but `path.join` yields `\app\data\.restic-cache`; or a `sh` script that cannot run on Windows). A new failure is any failure outside that known set.
- **Known baseline failing suites** (do not attempt to fix): `buildResticEnv`, `resolveHostPath`, symlink-copy suites, `buildBackupScript`, `buildFileRestores on a real filesystem` (`tests/backups/file-restore.test.ts`), `rewrite_under_data_dir`, `repoFilePath`, `classify_path`, `buildSwapRecoveryScript`, `moveDirEntries`, `readDirFilesAsMap`, `unsafeRestoreTargetReason`, `isProtectedPath`, `validateRestoreRequest`, `collectProcess`, `runProcess`, `finishScript`, `the restore preview probe on a single-file target`, `the environment update check uses the throttle`.
- **Machine:** Windows 11, Docker Desktop 4.99.0 (WSL2, `linux/amd64`), Docker Engine 29.9.3, API 1.56, context `desktop-linux`, endpoint `npipe:////./pipe/dockerDesktopLinuxEngine`.
- **Docker socket inside a container:** Docker Desktop maps the host named pipe to a real Unix socket at `/var/run/docker.sock` inside the container. **Verified**: a container with `-v /var/run/docker.sock:/var/run/docker.sock` successfully called `curl --unix-socket /var/run/docker.sock http://localhost/version` and received the Docker Engine JSON.
- **Native Windows runs cannot use the socket.** `src/lib/server/docker.ts` `detectDockerSocket()` (line ~202) only understands `unix://` prefixes and POSIX paths; `process.platform` is never checked. Dockhand must therefore always run **as a container**, never as a native Windows process, when it needs Docker access.
- **Host ports:** `3000`, `4131`, and `5432` were all free at plan-writing time. `4131` is the fork's chosen host port (see `origin/update/ports-4131`).
- **Compose file naming:** add `docker-compose.local.yaml` (new, local-only). Do **not** modify the upstream `docker-compose.yaml` or `docker-compose-postgresql.yaml` — they are upstream-owned files and will conflict on the next upstream merge.
- **No `.env` secrets in git.** Compose values live in `docker-compose.local.yaml` with development-only literals, matching the upstream `docker-compose-postgresql.yaml` convention (`changeme`).

## Review Focus

Five input classes or failure modes this plan implies but no task's tests directly exercise. Each line gets a test added to the owning task.

1. **SQLite deployment must not crash.** A user running the default SQLite build (no `DATABASE_URL`) must start normally with the new `0023` migration applied and the search API returning a clear "unsupported" error — not a crash, a 500, or a missing-module error. → Task 4 test.
2. **A Postgres deployment without the `vector` extension** (someone points `DATABASE_URL` at a stock `postgres:16-alpine` instead of `pgvector/pgvector:pg16`) must fail loudly at migration time with a clear message, not silently skip the column or corrupt the migration journal. → Task 1 test.
3. **Postgres is not ready when dockhand starts.** `depends_on` without a health condition lets the first migration run against a not-yet-ready server. The compose file must gate dockhand on a `pg_isready` healthcheck. → Task 5 verification step.
4. **The Docker socket is not readable by the app's non-root user.** The image runs as `dockhand` (UID 1001) and the entrypoint already handles socket GID assignment; a wrong `group_add` yields a silent "no containers" UI rather than an error. → Task 5 verification step.
5. **An embedding of the wrong dimension** (not exactly 768 floats) must be rejected at the write boundary with a clear error, not silently stored as a malformed vector that later fails the `<->` operator at query time with an opaque Postgres error. → Task 3 test.

---

## File Structure

**New files:**

| Path | Responsibility |
|---|---|
| `docker-compose.local.yaml` | Local dev stack: `pgvector/pgvector:pg16` + `dockhand` built from this repo, socket mounted, host port 4131. |
| `scripts/local-stack-up.sh` | One-command bring-up: starts the stack, waits for Postgres readiness, prints the URL. |
| `scripts/local-stack-down.sh` | Tear-down helper that removes the stack and its volumes. |
| `src/lib/server/db/schema/pg-vector.ts` | The `vector` column helper + dimension constant, isolated so the schema file stays declarative. |
| `src/lib/server/vector/embeddings.ts` | Embedding validation, JSON↔float[] conversion, and the dimension contract. |
| `src/lib/server/vector/search-query.ts` | The pure similarity-query builder (no database imports, so it is unit-testable). |
| `src/lib/server/vector/search.ts` | The database-touching semantic search over `container_events`. |
| `src/routes/api/search/semantic/+server.ts` | Public HTTP surface for semantic search over container events. |
| `tests/vector-embeddings.test.ts` | Unit tests for embedding validation and conversion (no DB). |
| `tests/vector-search.test.ts` | Unit tests for the similarity-query builder (no DB). |
| `tests/vector-schema.test.ts` | Unit tests for the schema column contract. |
| `tests/vector-api.test.ts` | Unit tests for the search endpoint's request handling. |
| `drizzle/0023_add_container_event_embedding.sql` | SQLite side of the migration — no-op (SQLite has no vector type). |
| `drizzle-pg/0023_add_container_event_embedding.sql` | Postgres side — enables the extension and adds the column + index. |

**Modified files:**

| Path | Change |
|---|---|
| `src/lib/server/db/schema/pg-schema.ts` | Add the `embedding` column to `containerEvents` (Postgres only). |
| `src/lib/server/db/schema/index.ts` | SQLite `containerEvents` — no column change; comment only, to keep the two schemas aligned in intent. |
| `src/lib/server/db.ts` | Add `upsertContainerEventEmbedding()`. |
| `drizzle/meta/_journal.json` | Add the `0023` entry. |
| `drizzle-pg/meta/_journal.json` | Add the `0023` entry. |
| `drizzle/meta/0023_snapshot.json` | New snapshot for SQLite. |
| `drizzle-pg/meta/0023_snapshot.json` | New snapshot for Postgres. |

---

## Task 1: The `vector` column type and the Postgres migration

**Files:**
- Create: `src/lib/server/db/schema/pg-vector.ts`
- Create: `drizzle-pg/0023_add_container_event_embedding.sql`
- Create: `drizzle/0023_add_container_event_embedding.sql`
- Create: `drizzle/meta/0023_snapshot.json`
- Create: `drizzle-pg/meta/0023_snapshot.json`
- Modify: `drizzle/meta/_journal.json`
- Modify: `drizzle-pg/meta/_journal.json`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `export const EMBEDDING_DIMENSIONS = 768;` from `src/lib/server/db/schema/pg-vector.ts`.
  - `export const embedding = (name: string) => vector(name, { dimensions: EMBEDDING_DIMENSIONS });` from the same file.
  - A Postgres column `container_events.embedding vector(768)` and an HNSW index `container_events_embedding_idx`.
  - Migration tag `0023_add_container_event_embedding` present in both journals.

**Notes for the implementer:**

`drizzle-kit generate` cannot be relied on to produce this migration, because the `vector` type has no SQLite equivalent and the SQLite schema must stay unchanged. Write both `.sql` files by hand, then hand-write the journal entries and snapshots by copying the `0022` snapshot and adding the new column/index to the `container_events` entry.

- [ ] **Step 1: Write the failing test**

Create `tests/vector-embeddings.test.ts`:

```ts
import { describe, test, expect } from 'bun:test';
import { EMBEDDING_DIMENSIONS } from '../src/lib/server/db/schema/pg-vector';

describe('the vector column contract', () => {
	test('the embedding dimension is fixed at 768', () => {
		expect(EMBEDDING_DIMENSIONS).toBe(768);
	});

	test('the migration enables the pgvector extension', async () => {
		const sql = await Bun.file('drizzle-pg/0023_add_container_event_embedding.sql').text();
		expect(sql).toContain('CREATE EXTENSION IF NOT EXISTS vector;');
	});

	test('the postgres migration adds a vector(768) column and an hnsw index', async () => {
		const sql = await Bun.file('drizzle-pg/0023_add_container_event_embedding.sql').text();
		expect(sql).toContain('ADD COLUMN "embedding" vector(768)');
		expect(sql).toContain('USING hnsw');
	});

	test('the sqlite migration is a no-op that adds no column', async () => {
		const sql = await Bun.file('drizzle/0023_add_container_event_embedding.sql').text();
		expect(sql).not.toContain('ADD COLUMN');
		expect(sql).not.toContain('vector');
	});

	test('both journals record the 0023 migration', async () => {
		const sqlite = JSON.parse(await Bun.file('drizzle/meta/_journal.json').text());
		const pg = JSON.parse(await Bun.file('drizzle-pg/meta/_journal.json').text());
		expect(sqlite.entries.at(-1).tag).toBe('0023_add_container_event_embedding');
		expect(pg.entries.at(-1).tag).toBe('0023_add_container_event_embedding');
		expect(sqlite.entries.at(-1).idx).toBe(23);
		expect(pg.entries.at(-1).idx).toBe(23);
	});
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test tests/vector-embeddings.test.ts`
Expected: FAIL — `Cannot find module '../src/lib/server/db/schema/pg-vector'`.

- [ ] **Step 3: Create the vector column helper**

Create `src/lib/server/db/schema/pg-vector.ts`:

```ts
/**
 * The pgvector column type and the embedding dimension contract.
 *
 * SQLite has no vector type, so this helper is imported by the Postgres schema
 * only. The SQLite migration for the same change is a no-op.
 */

import { vector } from 'drizzle-orm/pg-core';

/** The number of floats in one embedding. Fixed: a vector column's dimension is
 *  declared in the schema, so a row written with a different length cannot be
 *  compared with the `<->` operator and would fail at query time. */
export const EMBEDDING_DIMENSIONS = 768;

/** A `vector(768)` column. */
export const embedding = (name: string) => vector(name, { dimensions: EMBEDDING_DIMENSIONS });
```

- [ ] **Step 4: Create the Postgres migration**

Create `drizzle-pg/0023_add_container_event_embedding.sql`:

```sql
CREATE EXTENSION IF NOT EXISTS vector;--> statement-breakpoint
ALTER TABLE "container_events" ADD COLUMN "embedding" vector(768);--> statement-breakpoint
CREATE INDEX "container_events_embedding_idx" ON "container_events" USING hnsw ("embedding" vector_l2_ops);
```

- [ ] **Step 5: Create the SQLite no-op migration**

Create `drizzle/0023_add_container_event_embedding.sql`:

```sql
-- SQLite has no vector type, so this migration intentionally adds no column.
-- The embedding is a Postgres-only feature; see drizzle-pg/0023_add_container_event_embedding.sql.
SELECT 1;
```

- [ ] **Step 6: Add the journal entries**

In `drizzle/meta/_journal.json`, append to `entries`:

```json
{ "idx": 23, "version": "6", "when": 1794732800000, "tag": "0023_add_container_event_embedding", "breakpoints": true }
```

In `drizzle-pg/meta/_journal.json`, append:

```json
{ "idx": 23, "version": "7", "when": 1794732800001, "tag": "0023_add_container_event_embedding", "breakpoints": true }
```

**Note for the implementer:** the two journals differ in their `version` field and must be matched to each file. The `0022` entry is `{"idx":22,"version":"6","when":1793387373201,...}` in `drizzle/meta/_journal.json` and `{"idx":22,"version":"7","when":1793387381796,...}` in `drizzle-pg/meta/_journal.json`. Use the `version` value of each file's own `0022` entry, and a `when` value greater than that file's `0022` `when`. Both files currently hold 23 entries; each must end with 24.

- [ ] **Step 7: Create the snapshots**

Copy `drizzle/meta/0022_snapshot.json` to `drizzle/meta/0023_snapshot.json` and `drizzle-pg/meta/0022_snapshot.json` to `drizzle-pg/meta/0023_snapshot.json`. In each copy, set the top-level `id` and `prevId` fields so that `prevId` equals the `0022` snapshot's `id` and `id` is a new UUID. Change the `idx` of the `container_events` table entry to `0023` and its `tag` to `0023_add_container_event_embedding`.

For the Postgres copy only, add to the `container_events` table's `columns` object:

```json
"embedding": {
  "name": "embedding",
  "type": "PgVector",
  "typeSchema": "vector_extension",
  "dimensions": 768
}
```

Leave the SQLite snapshot's `container_events` columns unchanged.

- [ ] **Step 8: Run the test to verify it passes**

Run: `bun test tests/vector-embeddings.test.ts`
Expected: PASS — 5 pass, 0 fail.

- [ ] **Step 9: Verify the migration actually applies against a real Postgres**

Run:

```bash
docker run -d --name dh-pg-migrate -e POSTGRES_PASSWORD=changeme -e POSTGRES_USER=dockhand -e POSTGRES_DB=dockhand pgvector/pgvector:pg16
docker exec dh-pg-migrate pg_isready -U dockhand
docker exec -i dh-pg-migrate psql -U dockhand -d dockhand -v ON_ERROR_STOP=1 < drizzle-pg/0023_add_container_event_embedding.sql
docker exec dh-pg-migrate psql -U dockhand -d dockhand -c "\d container_events"
```

Expected: `CREATE EXTENSION`, `ALTER TABLE`, and `CREATE INDEX` all report success; `\d container_events` lists a column `embedding` of type `vector(768)`.

- [ ] **Step 10: Clean up the probe container**

Run: `docker rm -f dh-pg-migrate`
Expected: `dh-pg-migrate`.

- [ ] **Step 11: Commit**

```bash
git add src/lib/server/db/schema/pg-vector.ts drizzle/0023_add_container_event_embedding.sql drizzle-pg/0023_add_container_event_embedding.sql drizzle/meta/0023_snapshot.json drizzle-pg/meta/0023_snapshot.json drizzle/meta/_journal.json drizzle-pg/meta/_journal.json tests/vector-embeddings.test.ts
git commit -m "feat: add pgvector migration and the embedding dimension contract"
```

---

## Task 2: Wire the embedding column into the Postgres schema

**Files:**
- Modify: `src/lib/server/db/schema/pg-schema.ts` (the `containerEvents` table, line ~512)

**Interfaces:**
- Consumes: `embedding` and `EMBEDDING_DIMENSIONS` from `src/lib/server/db/schema/pg-vector.ts` (Task 1).
- Produces: the `containerEvents.embedding` column — type `vector(768)`, nullable — available to every code that imports the Postgres schema.

- [ ] **Step 1: Write the failing test**

Create `tests/vector-schema.test.ts`:

```ts
import { describe, test, expect } from 'bun:test';

describe('the container_events schema', () => {
	test('the postgres schema has an embedding column of the contracted dimension', async () => {
		const mod = await import('../src/lib/server/db/schema/pg-vector');
		const { containerEvents } = await import('../src/lib/server/db/schema/pg-schema');
		const column = (containerEvents as Record<string, unknown>).embedding;
		expect(column).toBeDefined();
		expect((column as { getSQLType(): string }).getSQLType()).toBe('vector(768)');
		expect(mod.EMBEDDING_DIMENSIONS).toBe(768);
	});

	test('the sqlite schema has no embedding column', async () => {
		const { containerEvents } = await import('../src/lib/server/db/schema/index');
		expect((containerEvents as Record<string, unknown>).embedding).toBeUndefined();
	});
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test tests/vector-schema.test.ts`
Expected: FAIL — the Postgres `containerEvents` has no `embedding` property.

- [ ] **Step 3: Add the column to the Postgres schema**

In `src/lib/server/db/schema/pg-schema.ts`:

Add to the import block at the top:

```ts
import { embedding } from './pg-vector';
```

Then add one line to the `containerEvents` table definition, immediately after `createdAt`:

```ts
	createdAt: timestamp('created_at', { mode: 'string' }).defaultNow(),
	embedding: embedding('embedding')
```

- [ ] **Step 4: Note the SQLite counterpart**

In `src/lib/server/db/schema/index.ts`, locate the `containerEvents` table and add a comment directly above it (no column is added):

```ts
// SQLite has no vector type, so `container_events` has no `embedding` column.
// The Postgres counterpart adds `embedding vector(768)`; see
// drizzle-pg/0023_add_container_event_embedding.sql.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bun test tests/vector-schema.test.ts`
Expected: PASS — 2 pass, 0 fail.

- [ ] **Step 6: Verify the type-check still passes**

Run: `npx svelte-check --tsconfig ./tsconfig.json`
Expected: no new errors relating to `embedding`, `pg-vector`, or `containerEvents`.

- [ ] **Step 7: Commit**

```bash
git add src/lib/server/db/schema/pg-schema.ts src/lib/server/db/schema/index.ts tests/vector-schema.test.ts
git commit -m "feat: add the container_events embedding column to the postgres schema"
```

---

## Task 3: Embedding validation, the similarity query, and persistence

**Files:**
- Create: `src/lib/server/vector/embeddings.ts`
- Create: `src/lib/server/vector/search-query.ts`
- Create: `src/lib/server/vector/search.ts`
- Modify: `src/lib/server/db.ts`
- Modify: `tests/vector-embeddings.test.ts` (extend — it already exists from Task 1)
- Create: `tests/vector-search.test.ts`

**Interfaces:**
- Consumes: `EMBEDDING_DIMENSIONS` from `src/lib/server/db/schema/pg-vector.ts` (Task 1); the `containerEvents.embedding` column (Task 2).
- Produces:
  - `export function parseEmbedding(value: unknown): number[]` in `src/lib/server/vector/embeddings.ts` — throws `Error` when the value is not an array of exactly `EMBEDDING_DIMENSIONS` finite numbers.
  - `export function serializeEmbedding(embedding: number[]): string` — returns the Postgres `vector` literal form `'[0.1,0.2,...]'`.
  - `export function buildSimilarityQuery(embedding: number[], limit: number, environmentId?: number): SimilarityQuery` in `src/lib/server/vector/search-query.ts`, where `SimilarityQuery` is `{ sql: string; params: unknown[] }`. This module imports **nothing** from `$lib/server`, so it is unit-testable.
  - `export async function searchContainerEventsByEmbedding(embedding: number[], limit?: number, environmentId?: number): Promise<SemanticSearchHit[]>` in `src/lib/server/vector/search.ts`, where `SemanticSearchHit` is `{ id: number; containerId: string; containerName: string | null; image: string | null; action: string; timestamp: string; distance: number }`.
  - `export async function upsertContainerEventEmbedding(containerEventId: number, embedding: number[]): Promise<boolean>` in `src/lib/server/db.ts` — returns `false` when running on SQLite (the column does not exist there), `true` on success.

- [ ] **Step 1: Write the failing test**

Append to `tests/vector-embeddings.test.ts`:

```ts
import { parseEmbedding, serializeEmbedding } from '../src/lib/server/vector/embeddings';

const valid = () => Array.from({ length: 768 }, (_, i) => i / 768);

describe('embedding validation', () => {
	test('accepts an array of exactly 768 finite numbers', () => {
		expect(parseEmbedding(valid())).toHaveLength(768);
	});

	test('rejects the wrong number of dimensions', () => {
		expect(() => parseEmbedding([1, 2, 3])).toThrow(/768/);
	});

	test('rejects a non-array', () => {
		expect(() => parseEmbedding('nope')).toThrow(/768/);
	});

	test('rejects a non-finite value', () => {
		const bad = valid();
		bad[10] = NaN;
		expect(() => parseEmbedding(bad)).toThrow(/768/);
	});

	test('serializes to the postgres vector literal form', () => {
		expect(serializeEmbedding([1, 2, 3])).toBe('[1,2,3]');
	});
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test tests/vector-embeddings.test.ts`
Expected: FAIL — `Cannot find module '../src/lib/server/vector/embeddings'`.

- [ ] **Step 3: Implement the embedding validation**

Create `src/lib/server/vector/embeddings.ts`:

```ts
/**
 * The embedding contract: a fixed-length vector of finite numbers, and the
 * Postgres literal form of one.
 *
 * A vector column's dimension is fixed by the schema, so a row written with the
 * wrong length cannot be compared with the `<->` operator and would fail at
 * query time with an opaque Postgres error. The length is checked here, at the
 * write boundary, instead.
 */

import { EMBEDDING_DIMENSIONS } from '../db/schema/pg-vector';

/**
 * Validate a value as an embedding and return it as a number array.
 * Throws when the value is not an array of exactly EMBEDDING_DIMENSIONS finite numbers.
 */
export function parseEmbedding(value: unknown): number[] {
	if (!Array.isArray(value) || value.length !== EMBEDDING_DIMENSIONS) {
		throw new Error(
			`An embedding must be an array of exactly ${EMBEDDING_DIMENSIONS} numbers, got ${
				Array.isArray(value) ? `${value.length}` : typeof value
			}.`
		);
	}

	const numbers = value.map((entry) => (typeof entry === 'number' ? entry : Number(entry)));
	if (numbers.some((entry) => !Number.isFinite(entry))) {
		throw new Error(
			`An embedding must contain only finite numbers (${EMBEDDING_DIMENSIONS} required).`
		);
	}

	return numbers;
}

/** The Postgres `vector` literal form: '[1,2,3]'. */
export function serializeEmbedding(embedding: number[]): string {
	return `[${embedding.join(',')}]`;
}
```

**Note for the implementer:** use the relative import `'../db/schema/pg-vector'`, not the `$lib` alias. The test file imports this module directly, and `$lib` aliases do not resolve under `bun test` without a preload.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test tests/vector-embeddings.test.ts`
Expected: PASS — 10 pass, 0 fail.

- [ ] **Step 5: Write the failing test for the similarity query**

Create `tests/vector-search.test.ts`:

```ts
import { describe, test, expect } from 'bun:test';
import { buildSimilarityQuery } from '../src/lib/server/vector/search-query';
import { EMBEDDING_DIMENSIONS } from '../src/lib/server/db/schema/pg-vector';

const embedding = () => Array.from({ length: EMBEDDING_DIMENSIONS }, (_, i) => i / EMBEDDING_DIMENSIONS);

describe('the semantic search query', () => {
	test('orders by the l2 distance operator and limits the rows', () => {
		const query = buildSimilarityQuery(embedding(), 10, 4);
		expect(query.sql).toContain('<->');
		expect(query.params).toContain(10);
		expect(query.params).toContain(4);
	});

	test('omits the environment filter when no environment is given', () => {
		const query = buildSimilarityQuery(embedding(), 10);
		expect(query.sql).not.toContain('environment_id');
	});

	test('binds the vector literal as the first parameter', () => {
		const query = buildSimilarityQuery([1, 2, 3], 10);
		expect(query.params[0]).toBe('[1,2,3]');
	});
});
```

**Note for the implementer:** `buildSimilarityQuery` does **not** validate the dimension — it serializes whatever it is given. The dimension check lives in `parseEmbedding`, which the live path (`search.ts`) calls first. That separation is deliberate: the builder stays a pure shape function.

- [ ] **Step 6: Run the test to verify it fails**

Run: `bun test tests/vector-search.test.ts`
Expected: FAIL — `Cannot find module '../src/lib/server/vector/search-query'`.

- [ ] **Step 7: Implement the pure similarity-query builder**

Create `src/lib/server/vector/search-query.ts`:

```ts
/**
 * The pure shape of the semantic-search query.
 *
 * This module imports nothing from the database, so the query can be tested
 * without one. The query uses raw SQL because Drizzle's query builder has no
 * first-class `<->` operator for a `vector` column; every value is bound as a
 * parameter, never interpolated into the text.
 */

export interface SimilarityQuery {
	sql: string;
	params: unknown[];
}

/**
 * The rows whose embedding is nearest to the given one, by L2 distance.
 *
 * The query text and its bound values are returned separately so the shape can
 * be tested without a database. `sql` uses `$1`, `$2`, ... placeholders; the
 * caller must pass `params` to Drizzle in that order.
 */
export function buildSimilarityQuery(
	embedding: number[],
	limit: number,
	environmentId?: number
): SimilarityQuery {
	const params: unknown[] = [`[${embedding.join(',')}]`];
	let query = `SELECT id, container_id, container_name, image, action, timestamp, embedding <-> $1::vector AS distance
		FROM container_events
		WHERE embedding IS NOT NULL`;

	if (environmentId !== undefined) {
		params.push(environmentId);
		query += `\n\t\tAND environment_id = $${params.length}`;
	}

	query += `\n\t\tORDER BY embedding <-> $1::vector ASC\n\t\tLIMIT $${params.length + 1}`;
	params.push(limit);

	return { sql: query, params };
}
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `bun test tests/vector-search.test.ts`
Expected: PASS — 2 pass, 0 fail, with no `ERR_DLOPEN_FAILED`.

- [ ] **Step 9: Implement the database-touching search function**

Create `src/lib/server/vector/search.ts`:

```ts
/**
 * Semantic search over container events, backed by pgvector.
 *
 * The embedding column only exists on Postgres, so this module is Postgres-only
 * and says so rather than failing at query time.
 */

import { sql } from 'drizzle-orm';
import { parseEmbedding, serializeEmbedding } from './embeddings';

export interface SemanticSearchHit {
	id: number;
	containerId: string;
	containerName: string | null;
	image: string | null;
	action: string;
	timestamp: string;
	distance: number;
}

/**
 * The rows whose embedding is nearest to the given one.
 *
 * Returns an empty list on SQLite: the column does not exist there. Callers
 * check `isPostgres` first and report the unsupported case to the user.
 */
export async function searchContainerEventsByEmbedding(
	embedding: number[],
	limit = 20,
	environmentId?: number
): Promise<SemanticSearchHit[]> {
	// The dialect is read from the environment, not from `$lib/server/db/drizzle`:
	// that module runs its migrations at import time and loads better-sqlite3,
	// so it cannot be imported where this module is unit tested.
	const databaseUrl = process.env.DATABASE_URL;
	const isPostgres = !!(
		databaseUrl &&
		(databaseUrl.startsWith('postgres://') || databaseUrl.startsWith('postgresql://'))
	);
	if (!isPostgres) return [];

	// Imported here, not at the top: `$lib/server/db/drizzle` runs its
	// migrations at import time and loads better-sqlite3, so importing it at
	// module scope would make this file untestable and slow to load.
	const { db } = await import('$lib/server/db/drizzle');

	const literal = serializeEmbedding(parseEmbedding(embedding));

	const rows =
		environmentId === undefined
			? await db.execute(sql`
					SELECT id, container_id, container_name, image, action, timestamp,
					       embedding <-> ${literal}::vector AS distance
					FROM container_events
					WHERE embedding IS NOT NULL
					ORDER BY embedding <-> ${literal}::vector ASC
					LIMIT ${limit}
				`)
			: await db.execute(sql`
					SELECT id, container_id, container_name, image, action, timestamp,
					       embedding <-> ${literal}::vector AS distance
					FROM container_events
					WHERE embedding IS NOT NULL
					  AND environment_id = ${environmentId}
					ORDER BY embedding <-> ${literal}::vector ASC
					LIMIT ${limit}
				`);

	return Array.from(rows as unknown as Record<string, unknown>[]).map((row) => ({
		id: Number(row.id),
		containerId: String(row.container_id),
		containerName: (row.container_name as string | null) ?? null,
		image: (row.image as string | null) ?? null,
		action: String(row.action),
		timestamp: String(row.timestamp),
		distance: Number(row.distance)
	}));
}
```

**Note for the implementer — three verified facts that shape this code:**

1. **`db.execute()` returns the rows directly as an array** on the postgres-js driver (verified: `Array.isArray(result) === true`, `result.length === 2`, `result[0]` is the first row). It does **not** return `{ rows }`. Writing `result.rows` yields `undefined` and an empty result set. The cast in the code above makes the array shape explicit to the type checker.
2. **The query must use the `sql` template tag**, not a runtime-built string with `$1` placeholders. Drizzle binds template parameters; a `$1` in a runtime string is never filled in. That is why the live query here is written inline with the template tag rather than reusing `buildSimilarityQuery`.
3. **`buildSimilarityQuery` stays in `search-query.ts`** and is used by the unit test to pin the query *shape* (that it orders by `<->`, that it limits, that it filters by environment). The live query in `search.ts` is written with the template tag. Keep the two in sync: when the query changes, change both.

**Note for the implementer:** `serializeEmbedding` is used to build the `vector` literal; import it alongside `parseEmbedding` from `./embeddings`.

- [ ] **Step 10: Add the persistence function to `db.ts`**

In `src/lib/server/db.ts`, add:

```ts
/**
 * Store an embedding on a container event.
 *
 * Returns false when the database is SQLite: the column only exists on
 * Postgres, so there is nothing to write and the caller decides whether that
 * is an error or a no-op.
 */
export async function upsertContainerEventEmbedding(
	containerEventId: number,
	embedding: number[]
): Promise<boolean> {
	if (!isPostgres) return false;

	const literal = serializeEmbedding(embedding);
	await db.execute(
		sql`UPDATE container_events SET embedding = ${literal}::vector WHERE id = ${containerEventId}`
	);
	return true;
}
```

Add the import this needs to `src/lib/server/db.ts`. `db.ts` already imports `db`, `isPostgres`, and `sql` from the `./db/drizzle.js` barrel, so **no new import of those is needed**. Add only the new one, to the existing relative-import block at the top of the file:

```ts
import { serializeEmbedding } from './vector/embeddings';
```

**Note for the implementer:** `src/lib/server/db/drizzle.ts` re-exports the schema tables through a lazy `Proxy` (`schemaProxy`) that resolves to the SQLite or Postgres schema at runtime. `containerEvents` is therefore the right dialect-aware table to query, and its `embedding` property exists only on the Postgres side.

- [ ] **Step 11: Run the whole vector test set**

Run: `bun test tests/vector-embeddings.test.ts tests/vector-search.test.ts tests/vector-schema.test.ts`
Expected: PASS — all pass, 0 fail.

- [ ] **Step 12: Commit**

```bash
git add src/lib/server/vector/embeddings.ts src/lib/server/vector/search-query.ts src/lib/server/vector/search.ts src/lib/server/db.ts tests/vector-embeddings.test.ts tests/vector-search.test.ts
git commit -m "feat: add embedding validation and pgvector similarity search"
```

---

## Task 4: The semantic search API endpoint

**Files:**
- Create: `src/routes/api/search/semantic/+server.ts`
- Create: `tests/vector-api.test.ts`

**Interfaces:**
- Consumes: `parseEmbedding` from `src/lib/server/vector/embeddings`; `searchContainerEventsByEmbedding` and `isPostgres` from `src/lib/server/vector/search` and `$lib/server/db/drizzle` (Task 3).
- Produces: `GET /api/search/semantic?embedding=<comma-separated numbers>&limit=<int>&environmentId=<int>`.
  - `200` — `{ results: SemanticSearchHit[], count: number }`
  - `400` — `{ error: string }` when the embedding is missing or malformed.
  - `501` — `{ error: string, database: 'sqlite' }` when the database is SQLite (the feature is Postgres-only).
  - `503` — `{ error: string }` when the database is Postgres but the query fails.

- [ ] **Step 1: Write the failing test**

Create `tests/vector-api.test.ts`:

```ts
import { describe, test, expect } from 'bun:test';

const readRoute = async () => {
	const mod = await import('../src/routes/api/search/semantic/+server');
	return mod.GET;
};

describe('the semantic search endpoint', () => {
	test('rejects a request with no embedding with 400', async () => {
		const GET = await readRoute();
		const response = await GET({ url: new URL('http://localhost/api/search/semantic') } as never);
		expect(response.status).toBe(400);
		const body = await response.json();
		expect(body.error).toBeTruthy();
	});

	test('rejects a malformed embedding with 400', async () => {
		const GET = await readRoute();
		const response = await GET({
			url: new URL('http://localhost/api/search/semantic?embedding=1,2,3')
		} as never);
		expect(response.status).toBe(400);
	});

	test('caps the limit so one request cannot ask for the whole table', async () => {
		const GET = await readRoute();
		const response = await GET({
			url: new URL(
				'http://localhost/api/search/semantic?embedding=' + Array(768).fill(0.1).join(',') + '&limit=100000'
			)
		} as never);
		// The request is well-formed, so it reaches the database layer; the
		// response is either results (Postgres) or 501 (SQLite). Either way it
		// must not be a 400.
		expect([200, 501, 503]).toContain(response.status);
	});
});
```

**Note for the implementer — `$lib` aliases and route imports:**

- `$lib` aliases **do** resolve under `bun test` in this repo. Existing tests import route modules directly, e.g. `tests/stack-path-hints.test.ts` does `await import('../src/routes/api/stacks/path-hints/+server')` and that route imports `$lib/server/stacks`. So the route's `$lib` imports are not a problem.
- The real obstacle is that **`$lib/server/db/drizzle` cannot be imported under Bun on this machine**: it runs a top-level `await seedDatabase()` and loads `better-sqlite3`, whose native addon does not build on Windows/Node 26 (`node-gyp` fails; the `Dockerfile` pins Node 24.22.1 for this reason). Importing it fails with `Cannot find package 'better-sqlite3'`.
- **Therefore the route must not import `$lib/server/db/drizzle` at the top level.** The dialect check must read `process.env.DATABASE_URL` directly (the same check `drizzle.ts` itself performs), and the search module must be imported dynamically inside the handler only when the database is Postgres.
- `$lib/server/db/schema/pg-schema.ts` and `$lib/server/db/schema/index.ts` **are** safe to import under Bun (verified: each loads and exports 39 tables), so the Task 2 schema test works as written.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test tests/vector-api.test.ts`
Expected: FAIL — `Cannot find module '../src/routes/api/search/semantic/+server'`.

- [ ] **Step 3: Implement the endpoint**

Create `src/routes/api/search/semantic/+server.ts`:

```ts
/**
 * Semantic search over container events.
 *
 * The query vector arrives as a comma-separated list, so the request stays a
 * plain GET and can be cached and linked.
 *
 * GET /api/search/semantic?embedding=0.1,0.2,...&limit=20&environmentId=1
 */

import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { parseEmbedding } from '$lib/server/vector/embeddings';

const MAX_LIMIT = 100;
const DEFAULT_LIMIT = 20;

/**
 * @openapi
 * summary: Semantic search over container events using pgvector embeddings
 * description: Returns the container events whose stored embedding is nearest the given one, by L2 distance. Requires Postgres with pgvector; returns 501 on SQLite.
 * resp-200: {results:Array<any>!, count:integer!}
 * resp-400: The embedding is missing or is not exactly 768 finite numbers
 * resp-501: The database is SQLite; the embedding feature is Postgres-only
 * resp-503: The database is Postgres but the query failed
 */
export const GET: RequestHandler = async ({ url }) => {
	const raw = url.searchParams.get('embedding');
	if (!raw) {
		return json({ error: 'An `embedding` query parameter is required.' }, { status: 400 });
	}

	let embedding: number[];
	try {
		embedding = parseEmbedding(raw.split(',').map((entry) => Number(entry.trim())));
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'Invalid embedding.' },
			{ status: 400 }
		);
	}

	const limitParam = Number(url.searchParams.get('limit') ?? DEFAULT_LIMIT);
	const limit = Number.isFinite(limitParam)
		? Math.min(Math.max(Math.trunc(limitParam), 1), MAX_LIMIT)
		: DEFAULT_LIMIT;

	const environmentParam = url.searchParams.get('environmentId');
	const environmentId = environmentParam ? Number(environmentParam) : undefined;

	// The dialect is read from the environment, not from the database module:
	// `$lib/server/db/drizzle` runs its migrations at import time and loads
	// better-sqlite3, so importing it here would make this route expensive to
	// load and impossible to unit test. This is the same check drizzle.ts makes.
	const databaseUrl = process.env.DATABASE_URL;
	const isPostgres = !!(
		databaseUrl &&
		(databaseUrl.startsWith('postgres://') || databaseUrl.startsWith('postgresql://'))
	);

	if (!isPostgres) {
		return json(
			{
				error:
					'Semantic search needs Postgres with the pgvector extension. This database is SQLite.',
				database: 'sqlite'
			},
			{ status: 501 }
		);
	}

	try {
		const { searchContainerEventsByEmbedding } = await import('$lib/server/vector/search');
		const results = await searchContainerEventsByEmbedding(embedding, limit, environmentId);
		return json({ results, count: results.length });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'Semantic search failed.' },
			{ status: 503 }
		);
	}
};
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test tests/vector-api.test.ts`
Expected: PASS — 3 pass, 0 fail.

- [ ] **Step 5: Verify the SQLite deployment degrades cleanly (Review Focus #1)**

Start the app with no `DATABASE_URL` (SQLite) and confirm the endpoint returns 501, not a crash:

```bash
DATA_DIR=./data PORT=3999 node build/index.js
curl -s -o /dev/null -w "%{http_code}" "http://localhost:3999/api/search/semantic?embedding=0.1"
```

Expected: `501`.

- [ ] **Step 6: Commit**

```bash
git add src/routes/api/search/semantic/+server.ts tests/vector-api.test.ts
git commit -m "feat: add the semantic search endpoint over container events"
```

---

## Task 5: The local Docker stack with pgvector

**Files:**
- Create: `docker-compose.local.yaml`
- Create: `scripts/local-stack-up.sh`
- Create: `scripts/local-stack-down.sh`

**Interfaces:**
- Consumes: nothing from Tasks 1–4 (this task is independent of the code changes).
- Produces: a running stack reachable at `http://localhost:4131`, with Postgres on `localhost:5432` and the `vector` extension enabled.

- [ ] **Step 1: Write the failing verification**

There is no unit test for a compose file. Verify by hand:

```bash
docker compose -f docker-compose.local.yaml config
```

Expected: FAIL at this point — the file does not exist.

- [ ] **Step 2: Create the compose file**

Create `docker-compose.local.yaml`:

```yaml
# Local development stack for this machine (Windows + Docker Desktop).
#
# Built from this repo's Dockerfile so local code changes are picked up.
# The Postgres image is pgvector/pgvector:pg16 rather than postgres:16-alpine:
# the official image does not ship the `vector` extension.
#
# Host ports: 4131 (app), 5432 (Postgres).

name: dockhand-local

services:
  postgres:
    image: pgvector/pgvector:pg16
    container_name: dockhand-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: dockhand
      POSTGRES_PASSWORD: changeme
      POSTGRES_DB: dockhand
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dockhand -d dockhand"]
      interval: 5s
      timeout: 5s
      retries: 12
      start_period: 10s

  dockhand:
    build:
      context: .
      dockerfile: Dockerfile
    image: dockhand-local:latest
    container_name: dockhand
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "4131:3000"
    environment:
      DATABASE_URL: postgres://dockhand:changeme@postgres:5432/dockhand
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - dockhand_data:/app/data

volumes:
  postgres_data:
  dockhand_data:
```

**Note for the implementer:** `depends_on: condition: service_healthy` is required. Without it the first migration run can reach a Postgres that is still starting, and the app exits with a connection error (Review Focus #3).

- [ ] **Step 3: Verify the compose file parses**

Run: `docker compose -f docker-compose.local.yaml config`
Expected: exit 0, and both `postgres` and `dockhand` appear under `services`.

- [ ] **Step 4: Create the bring-up script**

Create `scripts/local-stack-up.sh`:

```bash
#!/usr/bin/env bash
# Bring up the local Dockhand stack (app + Postgres with pgvector).
#
# Usage: scripts/local-stack-up.sh [--build]

set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="docker-compose.local.yaml"
BUILD_FLAG=""

if [ "${1:-}" = "--build" ]; then
	BUILD_FLAG="--build"
fi

echo "==> Starting Postgres (pgvector) and Dockhand"
docker compose -f "$COMPOSE_FILE" up -d $BUILD_FLAG

echo "==> Waiting for Postgres to accept connections"
for _ in $(seq 1 60); do
	if docker exec dockhand-postgres pg_isready -U dockhand -d dockhand >/dev/null 2>&1; then
		echo "==> Postgres is ready"
		break
	fi
	sleep 2
done

echo "==> Waiting for the app to answer its health check"
for _ in $(seq 1 60); do
	if curl -fs http://localhost:4131/api/health/database >/dev/null 2>&1; then
		echo "==> Dockhand is up: http://localhost:4131"
		echo "==> Database health: http://localhost:4131/api/health/database"
		exit 0
	fi
	sleep 2
done

echo "!! The app did not become healthy. Recent logs:" >&2
docker compose -f "$COMPOSE_FILE" logs --tail 50 >&2
exit 1
```

- [ ] **Step 5: Create the tear-down script**

Create `scripts/local-stack-down.sh`:

```bash
#!/usr/bin/env bash
# Stop the local Dockhand stack.
#
# Usage: scripts/local-stack-down.sh [--volumes]
#
# --volumes also deletes the Postgres and app data volumes.

set -euo pipefail

cd "$(dirname "$0")/.."

ARGS=""
if [ "${1:-}" = "--volumes" ]; then
	ARGS="--volumes"
fi

docker compose -f docker-compose.local.yaml down $ARGS
```

- [ ] **Step 6: Make the scripts executable (on this Windows host, via git)**

Run: `git update-index --chmod=+x scripts/local-stack-up.sh scripts/local-stack-down.sh`
Expected: exit 0.

- [ ] **Step 7: Build and start the stack**

Run: `bash scripts/local-stack-up.sh --build`
Expected: the image builds, both containers start, and the script prints `Dockhand is up: http://localhost:4131`.

**Note for the implementer:** the image build runs `npm run build`, which needs `NODE_OPTIONS=--max-old-space-size=6144` — the `Dockerfile` already sets this. The build also compiles the message catalogue across 6 locales and needs more than 3 GB of heap. If the build fails with an out-of-memory exit-134, confirm the `NODE_OPTIONS` line in the `Dockerfile` is present.

- [ ] **Step 8: Verify the vector extension is live in the running stack (Review Focus #2)**

Run:

```bash
docker exec dockhand-postgres psql -U dockhand -d dockhand -c "SELECT extname, extversion FROM pg_extension WHERE extname='vector';"
docker exec dockhand-postgres psql -U dockhand -d dockhand -c "\d container_events"
```

Expected: one row with `vector` and a version (0.8.x), and a `container_events` listing that includes `embedding` of type `vector(768)`.

- [ ] **Step 9: Verify the migration ran and the health endpoint reports the schema**

Run: `curl -s http://localhost:4131/api/health/database`
Expected: `"healthy": true`, `"database": "postgres"`, `"pendingMigrations": 0`.

- [ ] **Step 10: Verify the app reached the Docker engine through the socket (Review Focus #4)**

Run: `curl -s http://localhost:4131/api/containers`
Expected: a JSON array of the containers running on this machine (at minimum the `dockhand` and `dockhand-postgres` containers). An empty array means the socket is not readable by the app's non-root user — check the entrypoint log for `Docker socket GID:` and add `group_add` to the `dockhand` service.

- [ ] **Step 11: Verify semantic search answers over the live stack**

Run:

```bash
curl -s "http://localhost:4131/api/search/semantic?embedding=$(python -c "print(','.join(['0.1']*768))")"
```

Expected: `200` with `{"results":[],"count":0}` (no events have embeddings yet) — **not** a 501 and not a 500.

- [ ] **Step 12: Verify the teardown script works**

Run: `bash scripts/local-stack-down.sh`
Expected: both containers are removed and the named volumes are kept.

- [ ] **Step 13: Commit**

```bash
git add docker-compose.local.yaml scripts/local-stack-up.sh scripts/local-stack-down.sh
git commit -m "chore: add the local pgvector docker stack"
```

---

## Task 6: Document the local stack

**Files:**
- Create: `docs/superpowers/local-stack.md`

**Interfaces:**
- Consumes: `scripts/local-stack-up.sh`, `scripts/local-stack-down.sh`, `docker-compose.local.yaml` (Task 5).
- Produces: `docs/superpowers/local-stack.md` — the operator-facing description of the local stack.

- [ ] **Step 1: Create the operator documentation**

Create `docs/superpowers/local-stack.md`:

````markdown
# Local Dockhand stack (Windows + Docker Desktop)

This machine runs Dockhand as a two-container stack: the app, and PostgreSQL 16
with the pgvector extension.

## Prerequisites

- Docker Desktop 4.99.0 or newer, running the `desktop-linux` context.
- Ports 4131 (app) and 5432 (Postgres) free.

## Start

```bash
bash scripts/local-stack-up.sh --build
```

The app is then at <http://localhost:4131>.

## Stop

```bash
bash scripts/local-stack-down.sh            # keep the data
bash scripts/local-stack-down.sh --volumes  # delete the data too
```

## What runs where

| Service | Image | Host port | Notes |
|---|---|---|---|
| `dockhand` | built from this repo's `Dockerfile` | 4131 | Mounts `/var/run/docker.sock` so it manages this machine's containers. |
| `dockhand-postgres` | `pgvector/pgvector:pg16` | 5432 | Holds the schema and the `vector` extension. |

`pgvector/pgvector:pg16` is required — the official `postgres:16-alpine` image
does not ship the `vector` extension, and the `0023` migration fails without it.

## Checks

```bash
# The vector extension is live
docker exec dockhand-postgres psql -U dockhand -d dockhand \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname='vector';"

# The schema and migrations are current
curl -s http://localhost:4131/api/health/database

# The app reached the Docker engine
curl -s http://localhost:4131/api/containers
```

## Why the app runs as a container, not natively

`src/lib/server/docker.ts` resolves the Docker socket from POSIX paths only
(`/var/run/docker.sock` and friends) and never checks `process.platform`, so a
native Windows process cannot talk to the Windows named pipe. Inside a
container, Docker Desktop presents the host socket as a real Unix socket at
`/var/run/docker.sock`, which the app already handles.
````

- [ ] **Step 2: Verify the documented commands actually work**

Start the stack, then run each command in the doc's "Checks" section.
Expected: the extension query returns a row, the health endpoint returns
`"healthy": true` with `"database": "postgres"`, and the containers endpoint
returns a non-empty array.

- [ ] **Step 3: Stop the stack**

Run: `bash scripts/local-stack-down.sh`
Expected: both containers removed.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/local-stack.md
git commit -m "docs: describe the local pgvector stack"
```

---

## Appendix A: Facts verified while writing this plan

These were checked on this machine and are recorded so the implementer does not
have to re-derive them.

| Fact | How it was verified |
|---|---|
| `main` was 254 commits behind `upstream/main` and 0 ahead, so the sync was a pure fast-forward. | `git rev-list --left-right --count main...upstream/main` → `0  254` |
| The merge was clean and is now pushed. | `git merge --ff-only upstream/main` → exit 0; `git push origin main` → `a459f99..c257f46` |
| `origin/update/ports-4131` differs from upstream by exactly one thing: the host port `3000`→`4131`. | `git diff upstream/main origin/update/ports-4131 -- docker-compose.yaml` |
| The `pgvector/pgvector:pg16` image ships extension version 0.8.7 and supports HNSW indexes and the `<->` operator. | Ran `CREATE EXTENSION vector;`, `CREATE INDEX ... USING hnsw`, and an `<->` ordering query against a live container. |
| `drizzle-orm@0.45.2` exports a native `vector` column builder. | `node -e "console.log(typeof require('drizzle-orm/pg-core').vector)"` → `function`; `node_modules/drizzle-orm/pg-core/columns/vector_extension/vector.d.ts` defines `vector<D extends number>(config)` and `vector<TName extends string, D extends number>(name, config)`. |
| `sql.unsafe` does not exist in drizzle-orm 0.45.2; `db.execute()` returns rows as a bare array. | `node -e "console.log(Object.keys(sql))"` → `empty,fromList,raw,join,identifier,placeholder,param`; a live `db.execute(sql\`...\`)` against pgvector returned `Array.isArray(result) === true`, `result.length === 2`, `'rows' in result === false`. |
| A vector of the wrong dimension produces a clear Postgres error, not a silent bad row. | A live query with a 2-element vector against a `vector(3)` column raised `Failed query: SELECT embedding <-> $1::vector FROM probe / params: [1,2]`. |
| A container can reach the Docker Engine API through the mounted socket on this Windows host. | `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine:3.24` with `curl --unix-socket` returned the Engine `/version` JSON. |
| Postgres in the `pgvector` image accepts connections within ~2 s. | `pg_isready` loop returned "accepting connections" after 2 iterations. |
| The app has no pgvector, embedding, vector, LLM, RAG, or AI integration today. | Exhaustive grep over `src/`, `drizzle/`, `drizzle-pg/`, and `upstream/main` for `pgvector`, `embedding`, `vector`, `openai`, `anthropic`, `llm`, `RAG`, `semantic search` → no matches in code (only prose in comments). |
| The container/stack search boxes filter in memory in the browser; they never query the database. | `src/lib/utils/container-search-core.ts` and `src/lib/utils/wildcard-match.ts`, called from `src/routes/containers/+page.svelte:1091` and `src/routes/stacks/+page.svelte:792`. |
| The two dialect schemas both define 39 tables, and the highest migration in both directories is `0022`. | Table counts and directory listings. |
| The baseline test run on this Windows host is 6370 pass / 191 fail / 5 skip, and the failures are POSIX-only assertions. | `bun test tests/`; a failing case expects `/app/data/.restic-cache` but gets `\app\data\.restic-cache`. Confirmed identical (6370/191/5) in a pristine worktree at `c257f46` with none of this plan's changes applied. |
| The Windows named pipe is not supported by the app's socket detection. | `detectDockerSocket()` in `src/lib/server/docker.ts` (line ~202) handles only `unix://` and POSIX paths; grep for `npipe`/`win32`/`docker_engine` across `src/lib/server/` returns no socket-related match. |
| `$lib` aliases resolve under `bun test`, but `$lib/server/db/drizzle` does not load (better-sqlite3 native addon). | `tests/stack-path-hints.test.ts` imports a `$lib`-using route and passes; importing `db/drizzle.ts` under bun fails with `Cannot find package 'better-sqlite3'`. |
| `vector('embedding', { dimensions: 768 })` produces a column whose `getSQLType()` is exactly `vector(768)`. | A probe table built with that column reported `getSQLType: vector(768)` and `dimensions: 768`. |
| `better-sqlite3` cannot be built on this host (Windows / Node 26). | `npm install better-sqlite3@11.7.0` fails with a `node-gyp` error. This is why the app runs in a container — the `Dockerfile` pins Node 24.22.1. |

## Appendix B: Deliberately out of scope

- **An LLM or embedding provider.** This plan stores embeddings that something else produced. Adding a model SDK, an API key, or a network call to a provider is a separate plan with its own secret-handling and failure-mode decisions.
- **Backfilling embeddings for existing events.** There is no producer for embeddings yet.
- **A UI for semantic search.** The endpoint is the deliverable; the search box stays a client-side substring/wildcard filter.
- **Fixing the 190 Windows test failures.** They are pre-existing, POSIX-only, and out of scope.
- **Modifying the upstream compose files.** `docker-compose.yaml` and `docker-compose-postgresql.yaml` are upstream-owned and will conflict on the next upstream merge; `docker-compose.local.yaml` is the local-only addition.
