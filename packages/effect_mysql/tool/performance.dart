import 'dart:io';

import 'package:effect_mysql/effect_mysql.dart';
import 'package:mysql_client_plus/mysql_client_plus.dart' as mysql;
import 'package:mysql_client_plus/exception.dart' as errors;

import '../../effect_sql/tool/performance_support.dart';

MySqlSettings settings() => MySqlSettings(
  host: '127.0.0.1',
  port: int.parse(Platform.environment['EFFECT_BENCH_MYSQL_PORT']!),
  database: 'effect_test',
  user: 'root',
  password: 'effect_test_password',
  securityContext: SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificates(Platform.environment['EFFECT_BENCH_CA']!),
  connectTimeout: const Duration(seconds: 5),
);

// Baseline uses the driver's binary prepare/execute/deallocate path, never interpolation.
final class DirectDriver implements SqlDriver {
  @override
  Future<SqlConnection> open() async {
    final s = settings();
    final c = await mysql.MySQLConnection.createConnection(
      host: s.host,
      port: s.port,
      userName: s.user,
      password: s.password,
      databaseName: s.database,
      secure: true,
      securityContext: s.securityContext,
      onBadCertificate: (_) => false,
    );
    try {
      await c.connect(timeoutMs: 5000);
      return DirectConnection(c);
    } catch (_) {
      c.getSocket().destroy();
      rethrow;
    }
  }

  @override
  SqlFailure? classify(Object e, String op) =>
      e is errors.MySQLServerException && e.errorCode == 1062
      ? SqlFailure(SqlFailureKind.constraint, op)
      : null;
}

final class DirectConnection implements SqlConnection {
  DirectConnection(this.connection);
  final mysql.MySQLConnection connection;
  @override
  bool get isOpen => connection.connected;
  @override
  Future<SqlResult> execute(SqlStatement s) async {
    mysql.IResultSet r;
    if (s.parameters.isEmpty) {
      r = await connection.execute(s.text);
    } else {
      final prepared = await connection.prepare(s.text);
      try {
        r = await prepared.execute(s.parameters);
      } finally {
        if (connection.connected) await prepared.deallocate();
      }
    }
    return SqlResult(
      columns: r.cols.map((c) => c.name).toList(),
      rows: r.rows
          .map(
            (r) => List<Object?>.generate(
              r.numOfColumns,
              (i) => r.colAt(i) as Object?,
            ),
          )
          .toList(),
      affectedRows: r.affectedRows.toInt(),
      insertId: r.lastInsertID,
    );
  }

  @override
  Future<void> cancel() async {} // Same public driver limitation: drain active commands.
  @override
  Future<void> close() async {
    if (connection.connected) await connection.close();
  }
}

Future<void> main(List<String> args) => runPerformance(
  args,
  (direct) => direct ? DirectDriver() : MySqlDriver(settings()),
  'mysql',
);
