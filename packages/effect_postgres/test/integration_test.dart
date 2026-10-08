@TestOn('vm')
library;

import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_postgres/effect_postgres.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

import 'support/driver_contract.dart';

void main() {
  final port = Platform.environment['EFFECT_PG_PORT'];
  group(
    'PostgreSQL real database',
    () {
      driverContract(
        create: () => PostgresClient.create(
          pg.Endpoint(
            host: '127.0.0.1',
            port: int.parse(port!),
            database: 'effect_test',
            username: 'postgres',
            password: 'effect_test_password',
          ),
          settings: const pg.ConnectionSettings(sslMode: pg.SslMode.disable),
          maxConnections: 2,
        ),
        parameter: (i) => '\$$i',
        sleepQuery: 'SELECT pg_sleep(0.3)',
      );
      test(
        '[PG/layer] each scope gets a fresh pool and closes sockets',
        () async {
          final layer = PostgresClient.layer(
            pg.Endpoint(
              host: '127.0.0.1',
              port: int.parse(port!),
              database: 'effect_test',
              username: 'postgres',
              password: 'effect_test_password',
            ),
            settings: const pg.ConnectionSettings(sslMode: pg.SslMode.disable),
          );
          final seen = <SqlClient>[];
          final program = PostgresClient.key.effect<SqlFailure>().flatMap((db) {
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
      test('[PG09] invalid authentication is typed', () async {
        final c = PostgresClient.create(
          pg.Endpoint(
            host: '127.0.0.1',
            port: int.parse(port!),
            database: 'effect_test',
            username: 'postgres',
            password: 'invalid-test-only',
          ),
          settings: const pg.ConnectionSettings(sslMode: pg.SslMode.disable),
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
        ? 'Set EFFECT_PG_PORT for isolated real database tests'
        : false,
  );
}
