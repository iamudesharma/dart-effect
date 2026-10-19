# effect_sql_schema

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_sql_schema:
    path: /path/to/effect_dart/packages/effect_sql_schema

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
  effect_sql:
    path: /path/to/effect_dart/packages/effect_sql
  effect_schema:
    path: /path/to/effect_dart/packages/effect_schema
  effect_sqlite:
    path: /path/to/effect_dart/packages/effect_sqlite
```

## Usage

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_sql/effect_sql.dart';
import 'package:effect_schema/effect_schema.dart';
import 'package:effect_sql_schema/effect_sql_schema.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final result = Effect.succeed<SqlResult, SqlFailure, Unit>(SqlResult(columns: ['id'], rows: [[42]]));
  try { print(await runtime.runFuture(result.exactlyOne(Schema.object({'id': Field(Schema.integer)})))); } finally { await runtime.shutdown(); }
}
```

## Contracts and limits

Schema row decoding rejects duplicate column names and offers exactly-one cardinality. transactionWithDomain preserves a sealed SQL/domain family through rollback and composite cleanup. SqlMigrator uses a ledger and transaction-held singleton lock; checksum strings are supplied by the application. SQLite migrations are tested; PostgreSQL/MySQL dialect acceptance remains unrun. MySQL DDL may auto-commit and must not be advertised as rollback-safe migrations.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
