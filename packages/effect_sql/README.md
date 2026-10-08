# effect_sql

Driver-independent SQL effects: bounded connection leasing, parameterized queries,
exclusive transactions and nested savepoints with scoped cleanup.

**Initial release: `0.0.1`.** Use the hosted dependencies below, or the local
overrides for source development.

## Features and platform support

`effect_sql` depends only on `effect_core`. It does not open a database by itself;
provide a `SqlDriver`, or use `effect_postgres` or `effect_mysql` for native server
connections. The shared contract runs on VM and web with a compatible driver.
Flutter applications should normally call a backend API rather than distribute
database credentials to clients.

## Installation

Requires Dart **3.13 or later**. Run:

```sh
dart pub add effect_core effect_sql
# In a Flutter project:
flutter pub add effect_core effect_sql
```

Or add these dependencies to `pubspec.yaml`:

```yaml
dependencies:
  effect_core: ^0.0.1
  effect_sql: ^0.0.1
```

Then run `dart pub get` or `flutter pub get`. Your Flutter installation must
include a compatible Dart SDK.

## Quick start without a database

This complete example demonstrates the driver extension point using a small
in-memory driver. It does not connect to a real SQL server or implement SQL parsing.
Save as `bin/main.dart` and run `dart run bin/main.dart`:

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_sql/effect_sql.dart';

final class DemoDriver implements SqlDriver {
  @override
  Future<SqlConnection> open() async => DemoConnection();

  @override
  SqlFailure? classify(Object error, String operation) => null;
}

final class DemoConnection implements SqlConnection {
  bool _open = true;

  @override
  bool get isOpen => _open;

  @override
  Future<SqlResult> execute(SqlStatement statement) async {
    return SqlResult(columns: ['greeting'], rows: [statement.parameters]);
  }

  @override
  Future<void> close() async {
    _open = false;
  }

  @override
  Future<void> cancel() async {}
}

Future<void> main() async {
  final database = SqlClient(DemoDriver(), maxConnections: 2);
  final runtime = Runtime(Unit.value);

  try {
    final result = await runtime.runFuture(
      database.execute<Unit>(
        SqlStatement('SELECT ? AS greeting', ['Hello from Effect']),
      ),
    );
    print(result.rows.single.single); // Hello from Effect
  } finally {
    await runtime.shutdown();
    await database.shutdown();
  }
}
```

A real driver implements `open`, `execute`, `cancel`, `close`, and error
classification. Returning `null` from `classify` preserves a programmer defect.
For a real database, start with the PostgreSQL or MySQL package's quick start.

## Queries and transactions

The following reusable function assumes an `accounts(id, balance)` table and
MySQL-style `?` placeholders. PostgreSQL uses `$1`, `$2`, and so on.

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_sql/effect_sql.dart';

Effect<SqlResult, SqlFailure, Unit> transfer(SqlClient database) {
  return database.transaction<SqlResult, Unit>((session) {
    return session
        .execute<Unit>(
          SqlStatement(
            'UPDATE accounts SET balance = balance - ? WHERE id = ?',
            [10, 1],
          ),
        )
        .flatMap(
          (_) => session.execute<Unit>(
            SqlStatement(
              'UPDATE accounts SET balance = balance + ? WHERE id = ?',
              [10, 2],
            ),
          ),
        );
  });
}
```

A successful transaction commits; a failed/interrupted body rolls back. Use the
callback's `session` for every query in that transaction. It owns an exclusive
connection and expires when the callback finishes. `session.transaction` creates
a nested savepoint; do not replace it with `database.transaction`, which acquires
another connection. Bind values through `SqlStatement.parameters`; validate
identifiers separately rather than interpolating untrusted table/column names.

## Errors and shutdown

`SqlFailure` classifies connection, authentication, constraint, serialization,
syntax, closed-service and other driver errors. Use `Runtime.runExit` to distinguish
expected SQL failures from defects and interruption. Its summary omits query text
and values; the original `cause` may contain sensitive diagnostics.

Keep one pool for its owner lifetime, bound `maxConnections`, and await
`Runtime.shutdown` before `SqlClient.shutdown`. Transactions serialize their
session's queries. Cancellation guarantees depend on the driver's hook: work must
settle before rollback or connection reuse, and draining may take time.

## Local development

With access to the repository, clone it and add a `pubspec_overrides.yaml` beside
your application's pubspec. Replace `/path/to/effect_dart` with your checkout:

```yaml
dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
  effect_sql:
    path: /path/to/effect_dart/packages/effect_sql
```

Keep the version dependencies above in `pubspec.yaml`, then run `dart pub get`.
The repository already contains overrides for its own examples. The source
repository is currently private; repository access is required.

## Testing

From this package's repository directory:

```sh
dart analyze
dart test
dart test -p chrome
```

The release checks recorded 18 portable VM tests and 18 Chrome tests. Run
`python3 tool/sql_integration.py` from the repository root for real PostgreSQL and
MySQL acceptance. No database engine or credentials are needed for the shared
contract tests.

## Documentation and license

- [Package guide](https://effect-dart.ginjustice4.chatgpt.site/docs/sql/)
- [Verification and progress](https://effect-dart.ginjustice4.chatgpt.site/progress/)
- [Source repository](https://github.com/iamudesharma/dart-effect)

MIT; see [LICENSE](LICENSE). Independent and Effect-inspired; not affiliated
with Effect-TS. The advertised scope is documented here, not full upstream parity.
