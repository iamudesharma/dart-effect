import 'dart:async';

import 'package:blot_postgres/blot_postgres.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

void main() {
  final driver = PostgresDriver(
    pg.Endpoint(host: 'localhost', database: 'app'),
  );
  test('[PG/transport] driver transport failure and timeout map to expected connection errors', () {
    expect(
      driver.classify(pg.PgException('private detail'), 'execute')!.kind,
      SqlFailureKind.connection,
    );
    expect(
      driver.classify(TimeoutException('deadline'), 'acquire')!.kind,
      SqlFailureKind.connection,
    );
  });
  test('[PG/programmer] arbitrary programming errors remain defects', () {
    expect(driver.classify(StateError('bug'), 'execute'), null);
  });
}
