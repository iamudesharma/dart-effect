import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:effect_sql/effect_sql.dart';
import 'package:test/test.dart';

// Real-database contract shared by both native adapters; not mock SQL parsing.
void driverContract({
  required SqlClient Function() create,
  required String Function(int) parameter,
  required String sleepQuery,
}) {
  var next = 0;
  late String table;
  late SqlClient client;
  late Runtime<Unit> runtime;
  SqlStatement insert(int id, String value) => SqlStatement(
    'INSERT INTO $table (id, txt, nullable_value) VALUES (${parameter(1)}, ${parameter(2)}, ${parameter(3)})',
    [id, value, null],
  );
  Future<SqlResult> query(String sql) =>
      runtime.runFuture(client.execute<Unit>(SqlStatement(sql)));
  setUp(() async {
    table = 'effect_contract_${++next}';
    client = create();
    runtime = Runtime(Unit.value);
    await query('DROP TABLE IF EXISTS $table');
    await query(
      'CREATE TABLE $table (id INTEGER PRIMARY KEY, txt VARCHAR(255) NOT NULL, nullable_value INTEGER NULL)',
    );
  });
  tearDown(() async {
    try {
      await query('DROP TABLE IF EXISTS $table');
    } finally {
      await runtime.shutdown();
      await client.shutdown();
    }
  });
  test('[DB01] bound malicious/Unicode text and null round trip', () async {
    const value = "x'); DROP TABLE users; -- 😀 café";
    final write = await runtime.runFuture(
      client.execute<Unit>(insert(1, value)),
    );
    expect(write.affectedRows, 1);
    final result = await query('SELECT id, txt, nullable_value FROM $table');
    expect(result.rows.single[0].toString(), '1');
    expect(result.rows.single[1], value);
    expect(result.rows.single[2], null);
    expect(result.columns, ['id', 'txt', 'nullable_value']);
  });
  test(
    '[DB02] typed unique violation is expected; connection remains usable',
    () async {
      await runtime.runFuture(client.execute<Unit>(insert(1, 'one')));
      final exit = await runtime.runExit(
        client.execute<Unit>(insert(1, 'duplicate')),
      );
      expect(
        ((exit as Failure).cause as Expected<SqlFailure>).error.kind,
        SqlFailureKind.constraint,
      );
      expect(
        (await query('SELECT COUNT(*) FROM $table')).rows.single.single
            .toString(),
        '1',
      );
    },
  );
  test('[DB03] successful multi-query transaction commits', () async {
    await runtime.runFuture(
      client.transaction<Unit, Unit>(
        (tx) => tx
            .execute<Unit>(insert(1, 'a'))
            .flatMap((_) => tx.execute<Unit>(insert(2, 'b')))
            .map((_) => Unit.value),
      ),
    );
    expect(
      (await query('SELECT id FROM $table ORDER BY id')).rows
          .map((r) => r.single.toString()),
      ['1', '2'],
    );
  });
  for (final kind in ['expected', 'defect']) {
    test('[DB04/$kind] failed transaction rolls back actual writes', () async {
      final exit = await runtime.runExit(
        client.transaction<int, Unit>(
          (tx) => tx
              .execute<Unit>(insert(1, 'rollback'))
              .flatMap(
                (_) => kind == 'expected'
                    ? Effect.fail(
                        const SqlFailure(SqlFailureKind.other, 'business'),
                      )
                    : Effect.sync(() => throw StateError('business')),
              ),
        ),
      );
      expect(
        (exit as Failure).cause,
        kind == 'expected' ? isA<Expected>() : isA<Defect>(),
      );
      expect(
        (await query('SELECT COUNT(*) FROM $table')).rows.single.single
            .toString(),
        '0',
      );
    });
  }
  test('[DB05] three-level savepoints roll back only inner write', () async {
    await runtime.runFuture(
      client.transaction<Unit, Unit>((outer) {
        final middle = outer.transaction<Unit, Unit>((mid) {
          final inner = mid.transaction<Unit, Unit>(
            (tx) => tx
                .execute<Unit>(insert(3, 'inner'))
                .flatMap(
                  (_) => Effect.fail<Unit, SqlFailure, Unit>(
                    const SqlFailure(SqlFailureKind.other, 'inner'),
                  ),
                ),
          );
          return mid
              .execute<Unit>(insert(2, 'middle'))
              .flatMap(
                (_) => inner.catchAll((_) => Effect.succeed(Unit.value)),
              );
        });
        return outer.execute<Unit>(insert(1, 'outer')).flatMap((_) => middle);
      }),
    );
    expect(
      (await query('SELECT id FROM $table ORDER BY id')).rows
          .map((r) => r.single.toString()),
      ['1', '2'],
    );
  });
  test(
    '[DB06] interruption rolls back write before another lease can see it',
    () async {
      final started = Completer<void>();
      final f = runtime.fork(
        client.transaction<int, Unit>(
          (tx) => tx
              .execute<Unit>(insert(1, 'cancel'))
              .flatMap(
                (_) => Effect.fromFuture<int, SqlFailure, Unit>(() {
                  started.complete();
                  return Completer<int>().future;
                }),
              ),
        ),
      );
      await started.future;
      expect(
        (await f.interruptAndAwait() as Failure).cause,
        isA<Interrupted>(),
      );
      expect(
        (await query('SELECT COUNT(*) FROM $table')).rows.single.single
            .toString(),
        '0',
      );
    },
  );
  test('[DB07] driver receives cancellation during active command, then pool recovers', () async {
    final observed = ObservedDriver(client.driver, sleepQuery);
    final pool = SqlClient(observed, maxConnections: 1);
    try {
      final f = runtime.fork(
        pool.transaction<SqlResult, Unit>(
          (tx) => tx
              .execute<Unit>(insert(1, 'cancel-query'))
              .flatMap((_) => tx.execute<Unit>(SqlStatement(sleepQuery))),
        ),
      );
      await observed.submitted.future;
      expect(
        (await f.interruptAndAwait() as Failure).cause,
        isA<Interrupted>(),
      );
      final result = await runtime.runFuture(
        pool.execute<Unit>(SqlStatement('SELECT COUNT(*) FROM $table')),
      );
      expect(result.rows.single.single.toString(), '0');
    } finally {
      await pool.shutdown();
    }
  });
  test('[DB08] bounded concurrent queries preserve ordered results', () async {
    final results = await runtime.runFuture(
      Effect.traverse<int, SqlResult, SqlFailure, Unit>(
        List.generate(12, (i) => i),
        (i) =>
            client.execute<Unit>(SqlStatement('SELECT ${parameter(1)}', [i])),
        concurrency: 6,
      ),
    );
    expect(
      results.map((r) => r.rows.single.single.toString()),
      List.generate(12, (i) => '$i'),
    );
    expect(client.activeConnections, 0);
    expect(client.idleConnections, lessThanOrEqualTo(client.maxConnections));
  });
}

final class ObservedDriver implements SqlDriver {
  ObservedDriver(this.inner, this.target);
  final SqlDriver inner;
  final String target;
  final submitted = Completer<void>();
  @override
  Future<SqlConnection> open() async =>
      ObservedConnection(await inner.open(), this);
  @override
  SqlFailure? classify(Object e, String op) => inner.classify(e, op);
}

final class ObservedConnection implements SqlConnection {
  ObservedConnection(this.inner, this.driver);
  final SqlConnection inner;
  final ObservedDriver driver;
  @override
  bool get isOpen => inner.isOpen;
  @override
  Future<SqlResult> execute(SqlStatement s) {
    final pending = inner.execute(s);
    if (s.text == driver.target && !driver.submitted.isCompleted) {
      driver.submitted.complete();
    }
    return pending;
  }

  @override
  Future<void> cancel() => inner.cancel();
  @override
  Future<void> close() => inner.close();
}
