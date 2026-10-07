import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_postgres/effect_postgres.dart';
import 'package:postgres/postgres.dart' as pg;

Future<void> main() async {
  final env = Platform.environment;
  final endpoint = pg.Endpoint(
    host: env['PGHOST'] ?? 'localhost',
    port: int.parse(env['PGPORT'] ?? '5432'),
    database: env['PGDATABASE'] ?? 'postgres',
    username: env['PGUSER'],
    password: env['PGPASSWORD'],
  );
  final layer = PostgresClient.layer(
    endpoint,
    settings: pg.ConnectionSettings(
      sslMode: env['PGSSLMODE'] == 'disable'
          ? pg.SslMode.disable
          : pg.SslMode.verifyFull,
    ),
  );
  final program = PostgresClient.key
      .effect<SqlFailure>()
      .flatMap(
        (db) => db.execute<Context>(
          SqlStatement(r'SELECT $1::text AS greeting', ['Hello from Effect']),
        ),
      )
      .map((result) => result.rows.single.single);
  final runtime = Runtime(Context());
  try {
    print(await runtime.runFuture(layer.use(program)));
  } finally {
    await runtime.shutdown();
  }
}
