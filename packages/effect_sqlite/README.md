# effect_sqlite

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_sqlite:
    path: /path/to/effect_dart/packages/effect_sqlite

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
  effect_sql:
    path: /path/to/effect_dart/packages/effect_sql
```

## Usage

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_sqlite/effect_sqlite.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value), client = SqliteClient.create(':memory:');
  try { final rows = await runtime.runFuture(client.execute<Unit>(SqlStatement('SELECT ? AS value', [42]))); print(rows.rows); } finally { await runtime.shutdown(); await client.shutdown(); }
}
```

## Contracts and limits

Native sqlite3 2.x adapter, one connection per SqlClient. Insert IDs are read with `INSERT ... RETURNING`; connection-level stale last-insert IDs are not reported. Transactions, savepoints, bound parameters and constraint classification reuse effect_sql. Statements execute synchronously on the current isolate: they cannot be preempted mid-statement. Use a deliberate worker architecture for heavy queries. This adapter has no browser/Wasm implementation.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
