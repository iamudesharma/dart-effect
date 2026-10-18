/// Schema decoding and cardinality helpers for immutable SQL results.
library;

import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';
import 'package:effect_sql/effect_sql.dart';

sealed class SqlDecodeFailure {
  const SqlDecodeFailure();
}

final class SqlTransportFailure extends SqlDecodeFailure {
  const SqlTransportFailure(this.failure);
  final SqlFailure failure;
}

final class SqlRowFailure extends SqlDecodeFailure {
  const SqlRowFailure(this.row, this.error);
  final int row;
  final SchemaError error;
}

final class SqlCardinalityFailure extends SqlDecodeFailure {
  const SqlCardinalityFailure(this.actual);
  final int actual;
}

extension SqlDecode<R> on Effect<SqlResult, SqlFailure, R> {
  Effect<List<T>, SqlDecodeFailure, R> decodeRows<T>(Schema<T> schema) =>
      mapError<SqlDecodeFailure>(SqlTransportFailure.new).flatMap((result) {
        final values = <T>[];
        if (result.columns.toSet().length != result.columns.length) {
          return Effect.fail(
            SqlRowFailure(
              0,
              SchemaError([
                SchemaIssue([], 'Duplicate columns need explicit aliases'),
              ]),
            ),
          );
        }
        for (var row = 0; row < result.rows.length; row++) {
          final decoded = schema.decode({
            for (var i = 0; i < result.columns.length; i++)
              result.columns[i]: result.rows[row][i],
          });
          if (decoded is Invalid<T>) {
            return Effect.fail(SqlRowFailure(row, decoded.error));
          }
          values.add((decoded as Valid<T>).value);
        }
        return Effect.succeed(List.unmodifiable(values));
      });
  Effect<T, SqlDecodeFailure, R> exactlyOne<T>(Schema<T> schema) =>
      decodeRows(schema).flatMap(
        (rows) => rows.length == 1
            ? Effect.succeed(rows.single)
            : Effect.fail(SqlCardinalityFailure(rows.length)),
      );
}

sealed class SqlTransactionError<D> {
  const SqlTransactionError();
}

final class DomainFailure<D> extends SqlTransactionError<D> {
  const DomainFailure(this.error);
  final D error;
}

final class TransactionSqlFailure<D> extends SqlTransactionError<D> {
  const TransactionSqlFailure(this.failure);
  final SqlFailure failure;
}

final class _DomainSignal<D> {
  const _DomainSignal(this.error);
  final D error;
}

SqlFailure _toSql<D>(SqlTransactionError<D> error) => switch (error) {
  DomainFailure(:final error) => SqlFailure(
    SqlFailureKind.other,
    'domain',
    cause: _DomainSignal(error),
  ),
  TransactionSqlFailure(:final failure) => failure,
};
SqlTransactionError<D> _fromSql<D>(SqlFailure error) =>
    error.cause is _DomainSignal<D>
    ? DomainFailure((error.cause as _DomainSignal<D>).error)
    : TransactionSqlFailure(error);

/// Carries an explicit sealed SQL/domain family through rollback and cleanup.
final class DomainSqlSession<D> {
  DomainSqlSession._(this._session);
  final SqlSession _session;
  Effect<SqlResult, SqlTransactionError<D>, R> execute<R>(
    SqlStatement statement,
  ) => _session.execute<R>(statement).mapError(TransactionSqlFailure<D>.new);
  Effect<A, SqlTransactionError<D>, R> transaction<A, R>(
    Effect<A, SqlTransactionError<D>, R> Function(DomainSqlSession<D>) body,
  ) => _session
      .transaction<A, R>(
        (s) =>
            Effect.defer(() => body(DomainSqlSession._(s))).mapError(_toSql<D>),
      )
      .mapError(_fromSql<D>);
}

extension SqlDomainTransaction on SqlClient {
  Effect<A, SqlTransactionError<D>, R> transactionWithDomain<A, D, R>(
    Effect<A, SqlTransactionError<D>, R> Function(DomainSqlSession<D>) body,
  ) => transaction<A, R>(
    (s) => Effect.defer(() => body(DomainSqlSession._(s))).mapError(_toSql<D>),
  ).mapError(_fromSql<D>);
}

/// Dialect controls upsert and transactional lock syntax; identifiers are fixed.
enum MigrationDialect { postgres, mysql, sqlite }

final class SqlMigration {
  SqlMigration(
    this.version,
    this.name,
    this.checksum,
    Iterable<SqlStatement> statements,
  ) : statements = List.unmodifiable(statements) {
    if (version < 1 || name.isEmpty || checksum.isEmpty) {
      throw ArgumentError('Invalid migration identity');
    }
  }
  final int version;
  final String name, checksum;
  final List<SqlStatement> statements;
}

/// Idempotent ledger with a database-held singleton lock. Migration statements
/// must be transactional for the chosen database. MySQL DDL may auto-commit;
/// use transactional DML here or a database-specific DDL rollout process.
final class SqlMigrator {
  SqlMigrator(Iterable<SqlMigration> migrations, {required this.dialect})
    : migrations = List.unmodifiable(
        migrations.toList()..sort((a, b) => a.version.compareTo(b.version)),
      ) {
    if (this.migrations.map((m) => m.version).toSet().length !=
        this.migrations.length) {
      throw ArgumentError('Duplicate migration version');
    }
  }
  final List<SqlMigration> migrations;
  final MigrationDialect dialect;
  String _param(int n) => dialect == MigrationDialect.postgres ? '\$$n' : '?';
  Effect<List<int>, SqlFailure, R> run<R>(
    SqlClient client,
  ) => Effect.asyncExit((ctx) async {
    final setup = [
      SqlStatement(
        'CREATE TABLE IF NOT EXISTS effect_migrations (version INTEGER PRIMARY KEY, name VARCHAR(255) NOT NULL, checksum VARCHAR(255) NOT NULL)',
      ),
      SqlStatement(
        'CREATE TABLE IF NOT EXISTS effect_migration_lock (singleton INTEGER PRIMARY KEY)',
      ),
      SqlStatement(
        dialect == MigrationDialect.mysql
            ? 'INSERT IGNORE INTO effect_migration_lock VALUES (1)'
            : 'INSERT INTO effect_migration_lock VALUES (1) ON CONFLICT DO NOTHING',
      ),
    ];
    for (final statement in setup) {
      final exit = await ctx.evaluate(client.execute<R>(statement));
      if (exit is Failure<SqlResult, SqlFailure>) return Failure(exit.cause);
    }
    return ctx.evaluate(
      client.transaction<List<int>, R>(
        (session) => Effect.asyncExit((ctx) async {
          final locked = await ctx.evaluate(
            session.execute<R>(
              SqlStatement(
                dialect == MigrationDialect.sqlite
                    ? 'UPDATE effect_migration_lock SET singleton=singleton WHERE singleton=1'
                    : 'SELECT singleton FROM effect_migration_lock WHERE singleton=1 FOR UPDATE',
              ),
            ),
          );
          if (locked is Failure<SqlResult, SqlFailure>) {
            return Failure(locked.cause);
          }
          final ledger = await ctx.evaluate(
            session.execute<R>(
              SqlStatement(
                'SELECT version,name,checksum FROM effect_migrations ORDER BY version',
              ),
            ),
          );
          if (ledger is Failure<SqlResult, SqlFailure>) {
            return Failure(ledger.cause);
          }
          final known = {for (final m in migrations) m.version: m};
          final applied = <int>{};
          for (final row
              in (ledger as Success<SqlResult, SqlFailure>).value.rows) {
            final migration = known[row[0]];
            if (migration == null ||
                migration.name != row[1] ||
                migration.checksum != row[2]) {
              return const Failure(
                Expected(
                  SqlFailure(
                    SqlFailureKind.other,
                    'migration_history_mismatch',
                  ),
                ),
              );
            }
            applied.add(migration.version);
          }
          final added = <int>[];
          for (final migration in migrations) {
            if (applied.contains(migration.version)) continue;
            if (applied.any((version) => version > migration.version)) {
              return const Failure(
                Expected(
                  SqlFailure(SqlFailureKind.other, 'migration_order_mismatch'),
                ),
              );
            }
            for (final statement in migration.statements) {
              final result = await ctx.evaluate(session.execute<R>(statement));
              if (result is Failure<SqlResult, SqlFailure>) {
                return Failure(result.cause);
              }
            }
            final result = await ctx.evaluate(
              session.execute<R>(
                SqlStatement(
                  'INSERT INTO effect_migrations (version,name,checksum) VALUES (${_param(1)},${_param(2)},${_param(3)})',
                  [migration.version, migration.name, migration.checksum],
                ),
              ),
            );
            if (result is Failure<SqlResult, SqlFailure>) {
              return Failure(result.cause);
            }
            added.add(migration.version);
          }
          return Success(List.unmodifiable(added));
        }),
      ),
    );
  });
}
