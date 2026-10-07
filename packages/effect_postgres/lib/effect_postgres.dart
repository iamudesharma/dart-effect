/// PostgreSQL effects backed by package:postgres; native Dart API servers.
library;

import 'dart:async';
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_sql/effect_sql.dart';
import 'package:postgres/postgres.dart' as pg;
export 'package:effect_sql/effect_sql.dart';

/// PostgreSQL/PG is one adapter. Driver settings and codecs remain available.
final class PostgresDriver implements SqlDriver {
  PostgresDriver(this.endpoint, {this.settings});
  final pg.Endpoint endpoint;
  final pg.ConnectionSettings? settings;
  @override
  Future<SqlConnection> open() async =>
      _Connection(await pg.Connection.open(endpoint, settings: settings));
  @override
  SqlFailure? classify(Object error, String operation) {
    if (error is pg.ServerException) {
      final code = error.code;
      final kind = switch (code) {
        '23502' || '23503' || '23505' || '23514' => SqlFailureKind.constraint,
        '40001' || '40P01' => SqlFailureKind.serialization,
        '28P01' || '28000' => SqlFailureKind.authentication,
        final String s when s.startsWith('42') => SqlFailureKind.syntax,
        final String s when s.startsWith('08') => SqlFailureKind.connection,
        _ => SqlFailureKind.other,
      };
      return SqlFailure(kind, operation, code: code, cause: error);
    }
    if (error is pg.PgException ||
        error is IOException ||
        error is TimeoutException) {
      return SqlFailure(SqlFailureKind.connection, operation, cause: error);
    }
    return null;
  }
}

final class PostgresClient {
  static final key = ServiceKey<SqlClient>('PostgresClient');
  static SqlClient create(
    pg.Endpoint endpoint, {
    pg.ConnectionSettings? settings,
    int maxConnections = 10,
  }) => SqlClient(
    PostgresDriver(endpoint, settings: settings),
    maxConnections: maxConnections,
  );
  static Layer<SqlFailure> layer(
    pg.Endpoint endpoint, {
    pg.ConnectionSettings? settings,
    int maxConnections = 10,
  }) => Layer.resource(
    key,
    Effect.sync<SqlClient, SqlFailure, Context>(
      () =>
          create(endpoint, settings: settings, maxConnections: maxConnections),
    ),
    (c) => c.close<Context>(),
  );
}

final class _Connection implements SqlConnection {
  _Connection(this.connection);
  final pg.Connection connection;
  @override
  bool get isOpen => connection.isOpen;
  @override
  Future<SqlResult> execute(SqlStatement statement) async {
    final r = await connection.execute(
      statement.text,
      parameters: statement.parameters,
    );
    return SqlResult(
      columns: r.schema.columns.map((c) => c.columnName ?? '').toList(),
      rows: r.map((row) => row.toList()).toList(),
      affectedRows: r.affectedRows,
    );
  }

  @override
  Future<void> cancel() => connection.close(force: true);
  @override
  Future<void> close() => connection.close();
}
