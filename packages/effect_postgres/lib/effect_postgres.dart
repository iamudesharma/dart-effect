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
  /// Configures a driver without opening a database connection.
  ///
  /// [settings] controls the underlying driver's TLS, timeouts and codecs.
  PostgresDriver(this.endpoint, {this.settings});

  /// Server address, database and authentication used for new connections.
  final pg.Endpoint endpoint;

  /// Optional connection policy passed to [pg.Connection.open].
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

/// Factories for bounded PostgreSQL pools and scoped dependency layers.
///
/// Queries use PostgreSQL's positional parameters (`$1`, `$2`, and so on).
/// Pools open connections lazily, when their effects are executed.
final class PostgresClient {
  /// Context key provided by [layer] for access to its scoped SQL client.
  static final key = ServiceKey<SqlClient>('PostgresClient');

  /// Creates an application-owned pool with at most [maxConnections] leases.
  ///
  /// Construction performs no network I/O. [maxConnections] must be positive.
  /// [settings] is forwarded to the PostgreSQL driver for each connection.
  /// Await runtime shutdown before awaiting [SqlClient.shutdown] when the
  /// application's owner closes. Cancellation discards the affected connection.
  static SqlClient create(
    pg.Endpoint endpoint, {
    pg.ConnectionSettings? settings,
    int maxConnections = 10,
  }) => SqlClient(
    PostgresDriver(endpoint, settings: settings),
    maxConnections: maxConnections,
  );

  /// Provides a fresh pool under [key] for each layer construction scope.
  ///
  /// Use [Layer.use] to retain the pool while the application effect runs and
  /// await its cleanup when that scope closes. Connections are opened lazily;
  /// [settings] and [maxConnections] have the same meaning as in [create].
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
