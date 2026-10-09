# effect_mysql

MySQL queries and transactions as lazy, typed Effect computations, backed by
[`mysql_client_plus`](https://pub.dev/packages/mysql_client_plus).

**Initial release: `0.0.1`.** Use the hosted dependencies below, or the local
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
dart pub add effect_core effect_mysql
# In a Flutter project:
flutter pub add effect_core effect_mysql
```

Or add these dependencies to `pubspec.yaml`:

```yaml
dependencies:
  effect_core: ^0.0.1
  effect_mysql: ^0.0.1
```

Then run `dart pub get` or `flutter pub get`. Your Flutter installation must
include a compatible Dart SDK.

## Quick start

This example uses environment variables rather than embedding credentials.
Save as `bin/main.dart` and run it against your own database:

```dart
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_mysql/effect_mysql.dart';

Future<void> main() async {
  final env = Platform.environment;
  final caPath = env['MYSQL_CA'];
  final security = caPath == null
      ? null
      : (SecurityContext()..setTrustedCertificates(caPath));
  final layer = MySqlClient.layer(
    MySqlSettings(
      host: env['MYSQL_HOST'] ?? 'localhost',
      port: int.parse(env['MYSQL_PORT'] ?? '3306'),
      database: env['MYSQL_DATABASE'] ?? 'mysql',
      user: env['MYSQL_USER'] ?? 'root',
      password: env['MYSQL_PASSWORD'] ?? '',
      securityContext: security,
    ),
  );
  final program = MySqlClient.key
      .effect<SqlFailure>()
      .flatMap(
        (db) => db.execute<Context>(
          SqlStatement('SELECT ? AS greeting', ['Hello from Effect']),
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

Set `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_DATABASE`, `MYSQL_USER` and
`MYSQL_PASSWORD`. TLS is enabled by default and untrusted certificates are
rejected. Set `MYSQL_CA` to a trusted CA PEM path when using a private CA; the
server certificate must also be valid for the hostname. Do not use an always-true
`onBadCertificate` callback as a production configuration.

## Compose queries and transactions

`effect_mysql` re-exports the shared `effect_sql` types. Values use `?`
placeholders and are sent separately in `SqlStatement.parameters`.

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_mysql/effect_mysql.dart';

Effect<SqlResult, SqlFailure, Unit> queryInTransaction(SqlClient database) {
  return database.transaction<SqlResult, Unit>((session) {
    return session.execute<Unit>(
      SqlStatement('SELECT ? AS greeting', ['Hello from a transaction']),
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
an application-wide pool, use `MySqlClient.create`, retain it in your service owner,
and await runtime shutdown before database shutdown. Each layer construction
scope receives a fresh pool. Keep `maxConnections` within your database's limits.

MySQL cancellation drains an active command before rollback and reuse; it can
wait for the query to finish.
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
  effect_mysql:
    path: /path/to/effect_dart/packages/effect_mysql
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
The release check recorded 19 native tests for this package with no skips.
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
