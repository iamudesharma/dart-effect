# Focused Dart API package scope

Repository note: upstream/npm snapshots, Node comparison tooling and generated
npm inventories are deliberately ignored by Git. Links to `references/` and
ignored inventories describe optional local evidence and will not resolve in a
fresh clone. Dart and database tests do not require those files.

The user's latest instruction replaces the full-ecosystem request. Deliver the
reusable `blot_effect` core and PostgreSQL/MySQL integrations backed by established
Dart packages. “PG” is the PostgreSQL adapter, not a second package or a new wire
protocol. The historical Node inventory is reference material, not a requirement
to port unsupported JavaScript runtimes, frameworks or vendor integrations.

## Driver decision — 7 October 2026

Primary sources: [postgres](https://pub.dev/packages/postgres),
[pg](https://pub.dev/packages/pg), [mysql1](https://pub.dev/packages/mysql1),
[mysql_client](https://pub.dev/packages/mysql_client),
[mysql_client_plus](https://pub.dev/packages/mysql_client_plus).

| Driver | Evidence observed on pub.dev | Decision |
| --- | --- | --- |
| postgres 3.5.19 | 416 likes, displayed 458k downloads; published two days before inspection; pools/codecs/extended protocol | Use it for PostgreSQL; largest adoption among the inspected PostgreSQL candidates |
| pg | Displayed 164 downloads and zero likes | Do not choose just because Node calls its driver pg |
| mysql1 0.20.0 | 493 likes, displayed 16.6k downloads; release four years old | Older popular option; no additional adapter for it |
| mysql_client 0.0.27 | 186 likes, displayed 14.7k downloads; release four years old | Superseded here by maintained fork |
| mysql_client_plus 0.1.3 | Verified publisher; 160 pub points, displayed 15.2k downloads; release three months old | Use maintained fork with modern authentication/TLS support |

These metrics are a dated selection snapshot, not a permanent popularity ranking
or a driver-quality proof. Runtime versions are pinned in local lockfiles; public
manifests allow compatible driver updates. No Effect source references were
refreshed. Driver dependency installation/research is separate from that frozen
reference pack.

## Package boundaries

| Package | Location | Runtime dependencies / platform |
| --- | --- | --- |
| blot_effect | Repository root | Zero runtime dependencies; VM and web portable |
| blot_sql | packages/blot_sql | Core only; portable lease/transaction contracts and driver extension interface |
| blot_postgres | packages/blot_postgres | Core + SQL + postgres; native Dart sockets |
| blot_mysql | packages/blot_mysql | Core + SQL + mysql_client_plus; native Dart sockets/TLS |

Database adapters belong in an API/server process. Web clients call that API.
Driver imports and `dart:io` remain outside core. `blot_sql` shares real lifecycle
behavior, not a placeholder implementation of every Effect SQL module. Query
building, migrations, reactive queries, cursors/streaming and dialect abstraction
are not advertised. Results are materialized by the underlying driver.

Packages remain local development candidates, not published on pub.dev. Their
public dependencies use versions; checked-in `pubspec_overrides.yaml` files point
to local sources for development and are excluded from consumer archives. To use
an adapter in another local project, provide overrides for both `blot_effect`
and `blot_sql` until those dependencies are published. Publication is separate.

## Query and API usage

```dart
final database = PostgresClient.create(endpoint, maxConnections: 10);
final runtime = Runtime(Unit.value);
final query = database.execute<Unit>(
  SqlStatement(r'SELECT id, name FROM users WHERE id = $1', [id]),
);
final exit = await runtime.runExit(query);
// Convert Success/Expected SqlFailure to your framework's HTTP response.
// Decode rows with map; mapError translates driver failures to application errors.
// At server shutdown: await runtime.shutdown(); await database.shutdown();
```

The MySQL equivalent uses `?` placeholders and `MySqlClient.create(settings)`.
Its parameterized queries use real binary prepared statements, not the driver's
string interpolation API. Parameters are snapshotted when SqlStatement is built;
execution remains lazy and reusable. SQL identifiers/text are explicitly supplied
by the caller, never derived from parameter values. SqlResult keeps ordered
columns (including duplicates), immutable result containers and native driver
value representations. PostgreSQL codecs remain configurable through its
ConnectionSettings; MySQL values can differ between binary and text results.
No implicit cross-dialect numeric/date conversion is promised.

Use one pool for an application lifecycle. Own it with `PostgresClient.layer` or
`MySqlClient.layer` and `Layer.use` for a long-running application effect; those
factories allocate a fresh pool each time the layer is constructed in a new scope.
The lower-level instance `SqlClient.layer(key)` owns that existing instance once.
Examples in each adapter's `example/main.dart` show typed Context provision and
scoped cleanup. For manual ownership, interrupt/await runtime work before shutting
down its pool.

## Transaction, cancellation and cleanup contracts

* Pool construction performs no I/O. Query acquisition is bounded and FIFO;
  queued acquisition can be interrupted. Opening a socket is protected so a late
  successful acquisition cannot be orphaned. MySQL TCP acquisition and
  authentication each have the configured connection deadline; a late TCP socket
  is destroyed after timeout.
* A transaction uses one exclusive connection. Success commits; expected failure,
  defect and interruption roll back. Body child fibers and finalizers finish
  before COMMIT/ROLLBACK. Rollback failures append to the original Cause, and a
  connection with uncertain transaction state is discarded.
* Nested callbacks receive a new SqlSession using a unique internal savepoint.
  Use the session supplied to that callback, rather than invoking its parent
  handle while the nested transaction holds the parent's lock. Successful nested
  work releases the savepoint; failed work rolls back to it. Sessions expire at
  callback completion and cannot be retained for later queries.
* Each session serializes queries; a connection is never returned to the idle
  pool while a command is still running. PostgreSQL cancellation force-closes the
  local connection and discards it. This is connection termination, not a claim
  of out-of-band PostgreSQL CancelRequest support or instantaneous server stop.
* MySQL has no public command-cancel API in this driver. Interruption drains the
  pending command before rollback/reuse. Thus interruption/timeout may wait for
  that query to finish. Arbitrarily long or unreachable server operations can
  delay cleanup; no fake cancellation capability is claimed.
* COMMIT/ROLLBACK are protected once started. A successfully sent COMMIT cannot
  be undone by a later cancellation; a failed COMMIT can have an uncertain durable
  outcome. Do not blindly retry a write after a connection failure.
* Shutdown rejects new acquisitions, closes idle sockets, then awaits active
  leases and their releases. Scope finalization runs this shutdown exactly once.

Expected driver errors become SqlFailure with kind, operation and native error
code. Arbitrary programming errors remain Defect. Safe toString summaries omit
SQL text, parameter values and server messages; the original cause is retained
for explicitly requested diagnostics and can contain sensitive data.

## TLS behavior verified from the driver

mysql_client_plus 0.1.3 defaults its certificate callback to accepting every bad
certificate (`lib/src/mysql_client/connection.dart`, SecureSocket.secure call).
The adapter explicitly overrides this with rejection by default. Applications
can provide a SecurityContext with their trusted CA. The integration runner pins
its isolated MySQL server's public certificate exactly; that exception is limited
to tests. Modern MySQL caching_sha2_password authentication requires TLS in this
Dart driver; insecure=true is not advertised as compatible with that mode.
PostgreSQL exposes its driver's TLS settings; the example defaults to verifyFull.

## Independent tests and real database acceptance

The upstream reference tests distinguish ordinary unit tests from container-backed
integration tests. Relevant frozen evidence:
[PostgreSQL transaction acquisition](../../references/effect/upstream/packages/sql/pg/test/TransactionAcquire.test.ts),
[PostgreSQL client integration](../../references/effect/upstream/packages/sql/pg/test/Client.integration.test.ts),
[MySQL client integration](../../references/effect/upstream/packages/sql/mysql2/test/MysqlClient.integration.test.ts),
[MySQL error classification](../../references/effect/upstream/packages/sql/mysql2/test/SqlErrorClassification.test.ts).
Their Node-specific transport/protocol internals are delegated to Dart drivers;
our tests cover the Effect-to-driver lifecycle boundary independently.

| Cases | Observable proof |
| --- | --- |
| SQL01–SQL03 | Lazy/reusable query, immutable containers, max leases, FIFO cancellation and no orphan during protected opening |
| SQL04 (four exits) | COMMIT only on success; ROLLBACK on expected error, defect or interruption |
| SQL05–SQL06 | Original + rollback causes retained; failed commit/rollback discards lease |
| SQL07–SQL09 | Unique three-level savepoints, expired handle rejection, ordinary child cleanup before commit |
| SQL10–SQL15 | Pending query drains before rollback, shutdown waits/rejects, typed driver errors vs defects, redacted summaries, protected COMMIT after cancellation and layer-owned shutdown |
| DB01–DB02 | Actual prepared binding of Unicode/injection text and NULL; real unique violation and continued usability |
| DB03–DB05 | Real committed rows, rollback of actual writes on failure/defect, inner-only savepoint rollback |
| DB06–DB08 | Real cancellation rollback, in-flight driver command interruption/drain and recovery, ordered bounded concurrent queries |
| PG09 / MYSQL09 | Invalid credentials produce typed authentication errors |
| MYSQL10 | Untrusted self-signed server certificate rejected by adapter default |
| PG/layer / MYSQL/layer | Fresh pool per construction scope; idle sockets closed after each use |
| Adapter classification tests | Selected native error codes and programmer-error distinction |

The shared real-database contract is in
[driver_contract.dart](../../packages/blot_sql/test/support/driver_contract.dart).
It runs against actual PostgreSQL/MySQL processes, not mocked SQL results. Tests
without explicit database environment variables are skipped and never counted
as integration acceptance. The automated runner starts isolated pinned containers,
waits for readiness, copies/pins the MySQL public certificate, executes suites,
and removes only containers it created even when a suite fails:

```sh
# Install Dart package dependencies once in each packages/blot_* directory.
python3 tool/sql_integration.py
# Unit/portable coverage:
cd packages/blot_sql && dart test test/sql_test.dart
# Use -p chrome for that portable suite; database adapters require the VM.
```

See [sql-validation.json](sql-validation.json) for real executed counts and image
digests. TLS rejection is tested; production CA chains, failover, long-running
network partitions, load/soak behavior and cross-version database compatibility
are not established by these bounded development tests.
