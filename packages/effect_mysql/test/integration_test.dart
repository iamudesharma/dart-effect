@TestOn('vm')
library;

import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_mysql/effect_mysql.dart';
import 'package:test/test.dart';

import '../../effect_sql/test/support/driver_contract.dart';

void main() {
  final port = Platform.environment['EFFECT_MYSQL_PORT'];
  final certificatePath = Platform.environment['EFFECT_MYSQL_CERT_PATH'];
  final certificate = certificatePath == null
      ? null
      : File(certificatePath)
            .readAsStringSync()
            .replaceAll('\u0000', '')
            .trim();
  bool trustTestCertificate(X509Certificate cert) =>
      certificate != null && cert.pem.trim() == certificate;
  group(
    'MySQL real database',
    () {
      driverContract(
        create: () => MySqlClient.create(
          MySqlSettings(
            host: '127.0.0.1',
            port: int.parse(port!),
            user: 'root',
            password: 'effect_test_password',
            database: 'effect_test',
            secure: true,
            onBadCertificate: trustTestCertificate,
          ),
          maxConnections: 2,
        ),
        parameter: (_) => '?',
        sleepQuery: 'SELECT SLEEP(0.3)',
      );
      test(
        '[MYSQL/layer] each scope gets a fresh pool and closes sockets',
        () async {
          final layer = MySqlClient.layer(
            MySqlSettings(
              host: '127.0.0.1',
              port: int.parse(port!),
              user: 'root',
              password: 'effect_test_password',
              database: 'effect_test',
              onBadCertificate: trustTestCertificate,
            ),
          );
          final seen = <SqlClient>[];
          final program = MySqlClient.key.effect<SqlFailure>().flatMap((db) {
            seen.add(db);
            return db.execute<Context>(SqlStatement('SELECT 1'));
          });
          final runtime = Runtime(Context());
          try {
            await runtime.runFuture(layer.use(program));
            await runtime.runFuture(layer.use(program));
          } finally {
            await runtime.shutdown();
          }
          expect(identical(seen[0], seen[1]), false);
          expect(
            seen.every((db) => db.isClosed && db.idleConnections == 0),
            true,
          );
        },
      );
      test(
        '[MYSQL10] invalid server certificate is rejected by default',
        () async {
          final client = MySqlClient.create(
            MySqlSettings(
              host: '127.0.0.1',
              port: int.parse(port!),
              user: 'root',
              password: 'effect_test_password',
              database: 'effect_test',
              connectTimeout: const Duration(seconds: 2),
            ),
          );
          try {
            final exit = await Runtime(Unit.value)
                .runExit(client.execute<Unit>(SqlStatement('SELECT 1')));
            expect((exit as Failure).cause, isA<Expected<SqlFailure>>());
          } finally {
            await client.shutdown();
          }
        },
      );
      test('[MYSQL09] invalid authentication is typed', () async {
        final c = MySqlClient.create(
          MySqlSettings(
            host: '127.0.0.1',
            port: int.parse(port!),
            user: 'root',
            password: 'invalid-test-only',
            database: 'effect_test',
            secure: true,
            onBadCertificate: trustTestCertificate,
          ),
        );
        try {
          final e = await Runtime(Unit.value)
              .runExit(c.execute<Unit>(SqlStatement('SELECT 1')));
          expect(
            ((e as Failure).cause as Expected<SqlFailure>).error.kind,
            SqlFailureKind.authentication,
          );
        } finally {
          await c.shutdown();
        }
      });
    },
    skip: port == null
        ? 'Set EFFECT_MYSQL_PORT for isolated real database tests'
        : false,
  );
}
