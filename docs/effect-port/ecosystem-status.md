# Historical ecosystem inventory

Repository note: upstream/npm snapshots, Node comparison tooling and generated
npm inventories are deliberately ignored by Git. Links to `references/` and
ignored inventories describe optional local evidence and will not resolve in a
fresh clone. Dart and database tests do not require those files.

The previous entire-ecosystem request has been superseded by the user. Current
scope is a reusable Dart Effect core plus PostgreSQL/MySQL, choosing established
pub.dev drivers. Read [sql-adapters.md](sql-adapters.md). The table below is a
historical source inventory. Other Node packages are outside this task's scope,
not an outstanding completion requirement.

The pinned source has 39 package manifests, 792 `.ts` source modules and 514
TypeScript/TSX test files. Module counts exclude `.tsx` source modules. These are
source inventory counts, not implemented Dart modules or passing test counts.

| Upstream package | Source modules (.ts) | Test files | Dart status |
| --- | ---: | ---: | --- |
| `@effect/ai-anthropic` | 10 | 2 | Outside current scope |
| `@effect/ai-cloudflare` | 5 | 2 | Outside current scope |
| `@effect/ai-openai` | 13 | 4 | Outside current scope |
| `@effect/ai-openai-compat` | 9 | 3 | Outside current scope |
| `@effect/ai-openrouter` | 10 | 5 | Outside current scope |
| `@effect/ai-typesafe` | 6 | 3 | Outside current scope |
| `@effect/atom-react` | 5 | 1 | Outside current scope |
| `@effect/atom-solid` | 3 | 1 | Outside current scope |
| `@effect/atom-vue` | 1 | 1 | Outside current scope |
| `effect` | 496 | 324 | Partial core in effect_core |
| `@effect/opentelemetry` | 10 | 3 | Outside current scope |
| `@effect/platform-browser` | 18 | 12 | Outside current scope |
| `@effect/platform-bun` | 23 | 6 | Outside current scope |
| `@effect/platform-deno` | 23 | 17 | Outside current scope |
| `@effect/platform-node` | 26 | 27 | Outside current scope |
| `@effect/platform-node-shared` | 16 | 7 | Outside current scope |
| `@effect/sql-clickhouse` | 3 | 2 | Outside current scope |
| `@effect/sql-d1` | 2 | 2 | Outside current scope |
| `@effect/sql-libsql` | 3 | 2 | Outside current scope |
| `@effect/sql-mssql` | 5 | 4 | Outside current scope |
| `@effect/sql-mysql2` | 3 | 7 | Dart query/transaction adapter in effect_mysql; broader upstream API not ported |
| `@effect/sql-pg` | 11 | 16 | Dart query/transaction adapter in effect_postgres; underlying protocol delegated to postgres |
| `@effect/sql-pglite` | 3 | 6 | Outside current scope |
| `@effect/sql-sqlite-bun` | 3 | 1 | Outside current scope |
| `@effect/sql-sqlite-do` | 3 | 2 | Outside current scope |
| `@effect/sql-sqlite-node` | 3 | 9 | Outside current scope |
| `@effect/sql-sqlite-react-native` | 3 | 1 | Outside current scope |
| `@effect/sql-sqlite-wasm` | 6 | 2 | Outside current scope |
| `@effect/ai-codegen` | 8 | 2 | Outside current scope |
| `@effect/ai-docgen` | 2 | 0 | Outside current scope |
| `@effect/api-diff` | 13 | 9 | Outside current scope |
| `@effect/bundle` | 6 | 2 | Outside current scope |
| `@effect/docgen` | 10 | 4 | Outside current scope |
| `@effect/doctest` | 7 | 5 | Outside current scope |
| `@effect/jsdocs` | 2 | 1 | Outside current scope |
| `@effect/openapi-generator` | 9 | 7 | Outside current scope |
| `@effect/oxc` | 6 | 4 | Outside current scope |
| `@effect/utils` | 4 | 1 | Outside current scope |
| `@effect/vitest` | 3 | 7 | Outside current scope |

## Historical expansion roadmap (outside current scope)

1. Complete portable foundations: richer Cause/data structures, concurrency strategies, Stream/Sink operators, schema codecs/issues, configuration, cache and observability. Each contract needs independent lifecycle/property tests and selected npm comparisons.
2. Build browser/native network, socket, worker/isolate, file and process adapters as separate Dart packages. Keep platform imports outside portable core; verify on real supported runtimes. Bun/Deno/Node adapters need explicit Dart-equivalent decisions rather than name-only packages.
3. Add SQL driver integrations and persistence. Check migrations, transactions, cancellation, pool lifetime and real database round trips; mocked queries alone are insufficient.
4. Add HTTP API, RPC, event log, workflows and cluster. Verify wire schemas, disconnects, retries, persistence/recovery, idempotency and interruption across processes.
5. Add AI providers, CLI and reactive state. Provider protocol fixtures, command parsing/completion, state subscriptions and scope cleanup must be tested.
6. Decide equivalents for React/Solid/Vue bindings and TypeScript-oriented code-generation/tooling packages. Dart/Flutter adapters require their own compatibility specifications and framework tests; JavaScript framework wrappers cannot be declared compatible by renaming exports.

The implementation and test plan use the frozen release, not whatever latest
npm versions happen to become. A release-by-release parity manifest must precede
any whole-ecosystem completion claim. Native platform, external databases, vendor
APIs, framework adapters and distributed recovery remain unvalidated.

Current foundation contracts: [expansion-contracts.md](expansion-contracts.md).
Detailed case design and upstream runner behavior: [testing.md](testing.md).
