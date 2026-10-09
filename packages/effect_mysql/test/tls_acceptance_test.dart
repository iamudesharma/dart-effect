@TestOn('vm')
library;

import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_mysql/effect_mysql.dart';
import 'package:test/test.dart';

// Independent TLS acceptance: no certificate bypass or leaf pinning.
void main() {
  final env = Platform.environment;
  final goodPort = env['EFFECT_MYSQL_TLS_PORT'];
  final wrongHostPort = env['EFFECT_MYSQL_TLS_WRONG_HOST_PORT'];
  final ca = env['EFFECT_SQL_TLS_CA'];
  final wrongCa = env['EFFECT_SQL_TLS_WRONG_CA'];
  final configured = [
    goodPort,
    wrongHostPort,
    ca,
    wrongCa,
  ].every((v) => v != null);
  SqlClient client(String portText, String caPath) {
    final port = int.parse(portText);
    final trust = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(caPath);
    return MySqlClient.create(
      MySqlSettings(
        host: '127.0.0.1',
        port: port,
        database: 'effect_test',
        user: 'root',
        password: 'effect_test_password',
        securityContext: trust,
        connectTimeout: const Duration(seconds: 3),
      ),
      maxConnections: 1,
    );
  }

  Future<void> rejected(String port, String authority) async {
    final db = client(port, authority);
    final runtime = Runtime(Unit.value);
    try {
      final exit = await runtime.runExit(
        db.execute<Unit>(SqlStatement('SELECT 1')),
      );
      expect(exit, isA<Failure<SqlResult, SqlFailure>>());
      final cause = (exit as Failure<SqlResult, SqlFailure>).cause;
      expect(cause, isA<Expected<SqlFailure>>());
      expect(
        (cause as Expected<SqlFailure>).error.kind,
        SqlFailureKind.connection,
      );
      expect(db.idleConnections, 0);
    } finally {
      await runtime.shutdown();
      await db.shutdown();
    }
    expect(db.isClosed, true);
    expect(db.idleConnections, 0);
  }

  group(
    'MYSQL trusted CA acceptance',
    () {
      test('[TLS01] root + intermediate chain authenticates and encrypts prepared queries', () async {
        final db = client(goodPort!, ca!);
        final runtime = Runtime(Unit.value);
        try {
          final encryption = await runtime.runFuture(
            db.execute<Unit>(
              SqlStatement("SHOW SESSION STATUS LIKE 'Ssl_cipher'"),
            ),
          );
          expect(encryption.rows.single[1], isNotEmpty);
          const value = "TLS café 😀 ' bound value";
          final result = await runtime.runFuture(
            db.execute<Unit>(SqlStatement('SELECT ? AS value', [value])),
          );
          expect(result.rows.single.single, value);
        } finally {
          await runtime.shutdown();
          await db.shutdown();
        }
        expect(db.isClosed, true);
        expect(db.idleConnections, 0);
      });
      test(
        '[TLS02] unrelated trusted root rejects server before query',
        () => rejected(goodPort!, wrongCa!),
      );
      test(
        '[TLS03] trusted chain with wrong hostname rejects server before query',
        () => rejected(wrongHostPort!, ca!),
      );
    },
    skip: configured
        ? false
        : 'Run python3 tool/sql_tls_acceptance.py for isolated CA-chain tests',
  );
}
