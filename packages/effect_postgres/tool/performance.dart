import 'dart:io';

import 'package:effect_postgres/effect_postgres.dart';
import 'package:postgres/postgres.dart' as pg;

import '../../effect_sql/tool/performance_support.dart';

pg.Endpoint endpoint() => pg.Endpoint(
  host: '127.0.0.1',
  port: int.parse(Platform.environment['EFFECT_BENCH_PG_PORT']!),
  database: 'effect_test',
  username: 'postgres',
  password: 'effect_test_password',
);
pg.ConnectionSettings settings() => pg.ConnectionSettings(
  sslMode: pg.SslMode.verifyFull,
  securityContext: SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificates(Platform.environment['EFFECT_BENCH_CA']!),
  connectTimeout: const Duration(seconds: 5),
  queryTimeout: const Duration(seconds: 5),
);

// Baseline talks directly to postgres; same decoding/materialization and TLS.
final class DirectDriver implements SqlDriver {
  @override
  Future<SqlConnection> open() async => DirectConnection(
    await pg.Connection.open(endpoint(), settings: settings()),
  );
  @override
  SqlFailure? classify(Object e, String op) =>
      e is pg.ServerException && e.code == '23505'
      ? SqlFailure(SqlFailureKind.constraint, op)
      : null;
}

final class DirectConnection implements SqlConnection {
  DirectConnection(this.connection);
  final pg.Connection connection;
  @override
  bool get isOpen => connection.isOpen;
  @override
  Future<SqlResult> execute(SqlStatement s) async {
    final r = await connection.execute(s.text, parameters: s.parameters);
    return SqlResult(
      columns: r.schema.columns.map((c) => c.columnName ?? '').toList(),
      rows: r.map((r) => r.toList()).toList(),
      affectedRows: r.affectedRows,
    );
  }

  @override
  Future<void> cancel() => connection.close(force: true);
  @override
  Future<void> close() => connection.close();
}

Future<void> main(List<String> args) => runPerformance(
  args,
  (direct) => direct
      ? DirectDriver()
      : PostgresDriver(endpoint(), settings: settings()),
  'postgres',
);
