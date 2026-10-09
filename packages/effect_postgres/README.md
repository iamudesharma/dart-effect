# effect_postgres

PostgreSQL / PG queries and transactions as lazy, typed Effect computations, backed by
[`postgres`](https://pub.dev/packages/postgres).

**Current release: `0.0.2`.** Use the hosted dependencies below, or the local
overrides for source development.

## Features and platform support

- Bound queries, typed SQL failures and bounded connection leasing.
- Exclusive transactions, nested savepoints and expired-session checks.
- Direct application-owned pools or scoped `Layer`/`Context` services.
- Configurable TLS and driver settings.

This is a **native Dart VM adapter intended for backend/API services**. It uses
`dart:io` and does not run in Flutter web. Native Flutter compilation is not a
mobile acceptance claim; keep database credentials in your backend and use HTTP
from Flutter clients.

## Installation

Requires Dart **3.13 or later**. Run:

```sh
dart pub add effect_core effect_postgres postgres
# In a Flutter project:
flutter pub add effect_core effect_postgres postgres
```

Or add these dependencies to `pubspec.yaml`:

```yaml
dependencies:
  effect_core: ^0.0.1
  effect_postgres: ^0.0.2
  postgres: ^3.5.19
```

Then run `dart pub get` or `flutter pub get`. Your Flutter installation must
include a compatible Dart SDK.

## Quick start

This example uses environment variables rather than embedding credentials.
Save as `bin/main.dart` and run it against your own database:

```dart
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_postgres/effect_postgres.dart';
import 'package:postgres/postgres.dart' as pg;

Future<void> main() async {
  final env = Platform.environment;
  final endpoint = pg.Endpoint(
    host: env['PGHOST'] ?? 'localhost',
    port: int.parse(env['PGPORT'] ?? '5432'),
    database: env['PGDATABASE'] ?? 'postgres',
    username: env['PGUSER'],
    password: env['PGPASSWORD'],
  );
  final layer = PostgresClient.layer(
    endpoint,
    settings: pg.ConnectionSettings(
      sslMode: env['PGSSLMODE'] == 'disable'
          ? pg.SslMode.disable
          : pg.SslMode.verifyFull,
    ),
  );
  final program = PostgresClient.key
      .effect<SqlFailure>()
      .flatMap(
        (db) => db.execute<Context>(
          SqlStatement(r'SELECT $1::text AS greeting', ['Hello from Effect']),
        ),
      )
      .map((result) => result.rows.single.single);
  final runtime = Runtime(Context());
  try {
    print(await runtime.runFuture(layer.use(program)));
  } finally {
    await runtime.shutdown();
  }
}
```

Set `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and `PGPASSWORD` in your
process environment. TLS uses `verifyFull` by default. The hostname and the
server's certificate chain must validate against trusted certificates.
`PGSSLMODE=disable` is intended only for a deliberate isolated local fixture.

The `postgres` dependency is listed explicitly because this example imports its
`Endpoint`, `ConnectionSettings` and TLS types. PostgreSQL and PG use this same
adapter; a second PG-specific package is unnecessary.

## Compose queries and transactions

`effect_postgres` re-exports the shared `effect_sql` types. Values use `$1`, `$2`
placeholders and are sent separately in `SqlStatement.parameters`.

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_postgres/effect_postgres.dart';

Effect<SqlResult, SqlFailure, Unit> queryInTransaction(SqlClient database) {
  return database.transaction<SqlResult, Unit>((session) {
    return session.execute<Unit>(
      SqlStatement(r'SELECT $1::text AS greeting', [
        'Hello from a transaction',
      ]),
    );
  });
}
```

Run the returned effect with a `Runtime(Unit.value)`. Use the transaction's
`session` for its queries, and `session.transaction` for nested savepoints. A
successful body commits; failure or interruption rolls back. Do not retain a
session after its callback completes. The driver controls SQL value decoding;
`SqlResult` retains ordered columns and driver-native values.

## Ownership, cancellation and errors

The quick start uses `Layer.use` to close its pool at the end of the scope. For
an application-wide pool, use `PostgresClient.create`, retain it in your service owner,
and await runtime shutdown before database shutdown. Each layer construction
scope receives a fresh pool. Keep `maxConnections` within your database's limits.

PostgreSQL cancellation force-closes and discards the interrupted connection.
The safe `SqlFailure` summary omits SQL text, bound values and server messages;
raw diagnostic causes may contain sensitive information. Use `runExit` to handle
expected failures separately from defects and interruption. Transactions are not
automatically replayed after transient failures.

## Local development

With access to the repository, clone it and add a `pubspec_overrides.yaml` beside
your application's pubspec. Replace `/path/to/effect_dart` with your checkout:

```yaml
dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
  effect_sql:
    path: /path/to/effect_dart/packages/effect_sql
  effect_postgres:
    path: /path/to/effect_dart/packages/effect_postgres
```

Keep the version dependencies above in `pubspec.yaml`, then run `dart pub get`.
The repository already contains overrides for its own examples. The source
repository is currently private; repository access is required.

## Examples and testing

With database settings configured, from this package's repository directory:

```sh
dart analyze
dart run example/main.dart
```

Run `python3 tool/sql_integration.py` from the repository root for isolated real
driver tests and both database examples; it removes its test containers afterward.
The release check recorded 13 native tests for this package with no skips.
Running `dart test` without the fixture environment skips database-dependent
cases, so that alone is not end-to-end database validation.

Production failover, database version matrices, network partitions and long
load/soak remain separate acceptance work.

## Documentation and license

- [Package guide](https://effect-dart.ginjustice4.chatgpt.site/docs/sql/)
- [Verification and progress](https://effect-dart.ginjustice4.chatgpt.site/progress/)
- [Source repository](https://github.com/iamudesharma/dart-effect)

MIT; see [LICENSE](LICENSE). Independent and Effect-inspired; not affiliated
with Effect-TS. The advertised scope is documented here, not full upstream parity.
