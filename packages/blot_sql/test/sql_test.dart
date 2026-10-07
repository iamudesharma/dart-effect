import 'dart:async';

import 'package:blot_effect/blot_effect.dart';
import 'package:blot_sql/blot_sql.dart';
import 'package:test/test.dart';

final class DriverFault implements Exception {}

final class FakeDriver implements SqlDriver {
  final connections = <FakeConnection>[], trace = <String>[];
  Future<SqlConnection> Function()? opening;
  Future<SqlResult> Function(SqlStatement)? query;
  @override
  Future<SqlConnection> open() async {
    if (opening != null) return opening!();
    final c = FakeConnection(this);
    connections.add(c);
    return c;
  }

  @override
  SqlFailure? classify(Object e, String op) => e is DriverFault
      ? SqlFailure(SqlFailureKind.connection, op, cause: e)
      : null;
}

final class FakeConnection implements SqlConnection {
  FakeConnection(this.d);
  final FakeDriver d;
  bool open = true;
  int closes = 0;
  @override
  bool get isOpen => open;
  @override
  Future<SqlResult> execute(SqlStatement s) async {
    d.trace.add(s.text);
    return d.query == null ? SqlResult() : d.query!(s);
  }

  @override
  Future<void> close() async {
    if (open) {
      open = false;
      closes++;
    }
  }

  @override
  Future<void> cancel() async {
    d.trace.add('cancel');
  }
}

Future<void> checkpoint(bool Function() check) async {
  for (var i = 0; i < 200; i++) {
    if (check()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('No progress after 200 turns');
}

void main() {
  test('[SQL01] lazy execution, immutable snapshots and pool reuse', () async {
    final d = FakeDriver();
    final pool = SqlClient(d, maxConnections: 1),
        args = <Object?>[1, null],
        s = SqlStatement('SELECT ?', args);
    final effect = pool.execute<Unit>(s);
    args[0] = 99;
    expect(s.parameters, [1, null]);
    expect(d.connections, isEmpty);
    await Runtime(Unit.value).runFuture(effect);
    await Runtime(Unit.value).runFuture(effect);
    expect(d.connections.length, 1);
    final r = SqlResult(
      columns: ['x', 'x'],
      rows: [
        [1, null],
      ],
    );
    expect(() => r.rows.first[0] = 2, throwsUnsupportedError);
    expect(r.columns, ['x', 'x']);
    await pool.shutdown();
    expect(d.connections.single.closes, 1);
  });
  test('[SQL02] bounded leases and interrupted queued acquisition', () async {
    final d = FakeDriver(), gate = Completer<SqlResult>();
    d.query = (_) => gate.future;
    final c = SqlClient(d, maxConnections: 2), rt = Runtime(Unit.value);
    final a = rt.fork(c.execute<Unit>(SqlStatement('a'))),
        b = rt.fork(c.execute<Unit>(SqlStatement('b'))),
        waiter = rt.fork(c.execute<Unit>(SqlStatement('c')));
    await checkpoint(() => d.trace.length == 2);
    expect(d.connections.length, 2);
    await waiter.interruptAndAwait();
    expect(d.trace, ['a', 'b']);
    gate.complete(SqlResult());
    await a.awaitExit();
    await b.awaitExit();
    expect(c.activeConnections, 0);
    expect(c.idleConnections, 2);
    await c.shutdown();
    expect(d.connections.map((c) => c.closes), [1, 1]);
  });
  test(
    '[SQL03] interruption during protected acquisition never orphans socket',
    () async {
      final d = FakeDriver(), gate = Completer<SqlConnection>();
      d.opening = () => gate.future;
      final c = SqlClient(d), socket = FakeConnection(d);
      final f = Runtime(Unit.value)
          .fork(c.execute<Unit>(SqlStatement('query')));
      await checkpoint(() => c.activeConnections == 1);
      f.interrupt();
      gate.complete(socket);
      expect((await f.awaitExit() as Failure).cause, isA<Interrupted>());
      expect(d.trace, isEmpty);
      await c.shutdown();
      expect(socket.closes, 1);
    },
  );
  for (final outcome in ['success', 'expected', 'defect', 'interruption']) {
    test(
      '[SQL04/$outcome] commit success and roll back every failed body exit',
      () async {
        final d = FakeDriver(), started = Completer<void>();
        final pool = SqlClient(d);
        final work = pool.transaction<int, Unit>(
          (_) => switch (outcome) {
            'success' => Effect.succeed(7),
            'expected' => Effect.fail(
              const SqlFailure(SqlFailureKind.other, 'body'),
            ),
            'defect' => Effect.sync(() => throw StateError('bug')),
            _ => Effect.fromFuture(() {
              started.complete();
              return Completer<int>().future;
            }),
          },
        );
        final f = Runtime(Unit.value).fork(work);
        if (outcome == 'interruption') {
          await started.future;
          f.interrupt();
        }
        expect(
          await f.awaitExit(),
          outcome == 'success' ? isA<Success>() : isA<Failure>(),
        );
        expect(d.trace, [
          'BEGIN',
          outcome == 'success' ? 'COMMIT' : 'ROLLBACK',
        ]);
        await pool.shutdown();
      },
    );
  }
  test(
    '[SQL05] failed rollback retains body cause and discards lease',
    () async {
      final d = FakeDriver();
      d.query = (s) async {
        if (s.text == 'ROLLBACK') throw DriverFault();
        return SqlResult();
      };
      final c = SqlClient(d);
      final exit = await Runtime(Unit.value).runExit(
        c.transaction<int, Unit>(
          (_) => Effect.fail(const SqlFailure(SqlFailureKind.other, 'body')),
        ),
      );
      final cause = (exit as Failure).cause as Sequential;
      expect(cause.first, isA<Expected>());
      expect(cause.second, isA<Expected>());
      expect(c.idleConnections, 0);
      expect(d.connections.single.closes, 1);
      await c.shutdown();
    },
  );
  test('[SQL06] commit failure discards uncertain connection', () async {
    final d = FakeDriver();
    d.query = (s) async {
      if (s.text == 'COMMIT') throw DriverFault();
      return SqlResult();
    };
    final c = SqlClient(d);
    expect(
      await Runtime(Unit.value)
          .runExit(c.transaction<int, Unit>((_) => Effect.succeed(1))),
      isA<Failure>(),
    );
    expect(d.trace, ['BEGIN', 'COMMIT']);
    expect(d.connections.single.closes, 1);
    await c.shutdown();
  });
  test(
    '[SQL07] nested savepoints have unique IDs and recover on one connection',
    () async {
      final d = FakeDriver();
      final pool = SqlClient(d);
      await Runtime(Unit.value).runFuture(
        pool.transaction<Unit, Unit>(
          (outer) => outer
              .transaction<Unit, Unit>(
                (inner) => inner
                    .transaction<Unit, Unit>(
                      (_) => Effect.fail(
                        const SqlFailure(SqlFailureKind.other, 'inner'),
                      ),
                    )
                    .catchAll((_) => Effect.succeed(Unit.value)),
              )
              .flatMap(
                (_) => outer
                    .execute<Unit>(SqlStatement('write'))
                    .map((_) => Unit.value),
              ),
        ),
      );
      expect(d.connections.length, 1);
      expect(d.trace, [
        'BEGIN',
        'SAVEPOINT blot_sp_1',
        'SAVEPOINT blot_sp_2',
        'ROLLBACK TO SAVEPOINT blot_sp_2',
        'RELEASE SAVEPOINT blot_sp_2',
        'RELEASE SAVEPOINT blot_sp_1',
        'write',
        'COMMIT',
      ]);
      await pool.shutdown();
    },
  );
  test('[SQL08] escaped transaction handle expires', () async {
    final d = FakeDriver();
    final pool = SqlClient(d);
    late SqlSession saved;
    await Runtime(Unit.value).runFuture(
      pool.transaction<Unit, Unit>((s) {
        saved = s;
        return Effect.succeed(Unit.value);
      }),
    );
    final e = await Runtime(Unit.value)
        .runExit(saved.execute<Unit>(SqlStatement('late')));
    expect((e as Failure).cause, isA<Expected>());
    expect(d.trace, ['BEGIN', 'COMMIT']);
    await pool.shutdown();
  });
  test('[SQL09] ordinary child finalizers finish before commit', () async {
    final d = FakeDriver(), start = Completer<void>();
    final c = SqlClient(d);
    await Runtime(Unit.value).runFuture(
      c.transaction<Unit, Unit>(
        (_) =>
            Effect.fromFuture<Unit, SqlFailure, Unit>(() {
                  start.complete();
                  return Completer<Unit>().future;
                })
                .ensuring(Effect.sync(() => d.trace.add('child-release')))
                .fork()
                .flatMap(
                  (_) => Effect.fromFuture<void, SqlFailure, Unit>(
                    () => start.future,
                  ).map((_) => Unit.value),
                ),
      ),
    );
    expect(d.trace, ['BEGIN', 'child-release', 'COMMIT']);
    await c.shutdown();
  });
  test(
    '[SQL10] canceled command drains before rollback and pool reuse',
    () async {
      final d = FakeDriver(), gate = Completer<SqlResult>();
      d.query = (s) async => s.text == 'query' ? gate.future : SqlResult();
      final c = SqlClient(d, maxConnections: 1);
      final f = Runtime(Unit.value).fork(
        c.transaction<SqlResult, Unit>(
          (s) => s.execute<Unit>(SqlStatement('query')),
        ),
      );
      await checkpoint(() => d.trace.contains('query'));
      f.interrupt();
      await checkpoint(() => d.trace.contains('cancel'));
      expect(d.trace, ['BEGIN', 'query', 'cancel']);
      expect(c.activeConnections, 1);
      gate.complete(SqlResult());
      await f.awaitExit();
      expect(d.trace, ['BEGIN', 'query', 'cancel', 'ROLLBACK']);
      expect(c.idleConnections, 1);
      await c.shutdown();
    },
  );
  test('[SQL11] shutdown waits for active work and rejects new work', () async {
    final d = FakeDriver(), gate = Completer<SqlResult>();
    d.query = (_) => gate.future;
    final c = SqlClient(d), rt = Runtime(Unit.value);
    final work = rt.runFuture(c.execute<Unit>(SqlStatement('query')));
    await checkpoint(() => c.activeConnections == 1);
    final closing = c.shutdown();
    expect(
      await rt.runExit(c.execute<Unit>(SqlStatement('late'))),
      isA<Failure>(),
    );
    gate.complete(SqlResult());
    await work;
    await closing;
    await c.shutdown();
    expect(d.connections.single.closes, 1);
    expect(c.idleConnections, 0);
  });
  test(
    '[SQL12] expected connection errors stay distinct from programmer defects',
    () async {
      final d = FakeDriver();
      final pool = SqlClient(d);
      d.opening = () async => throw DriverFault();
      expect(
        (await Runtime(
          Unit.value,
        ).runExit(pool.execute<Unit>(SqlStatement('query'))) as Failure).cause,
        isA<Expected>(),
      );
      d.opening = () async => throw StateError('bug');
      expect(
        (await Runtime(
          Unit.value,
        ).runExit(pool.execute<Unit>(SqlStatement('query'))) as Failure).cause,
        isA<Defect>(),
      );
      await pool.shutdown();
    },
  );
  test(
    '[SQL14] cancellation after commit starts cannot run rollback',
    () async {
      final driver = FakeDriver(), gate = Completer<SqlResult>();
      driver.query = (s) async =>
          s.text == 'COMMIT' ? gate.future : SqlResult();
      final client = SqlClient(driver);
      final fiber = Runtime(Unit.value)
          .fork(client.transaction<int, Unit>((_) => Effect.succeed(1)));
      await checkpoint(() => driver.trace.contains('COMMIT'));
      fiber.interrupt();
      expect(client.activeConnections, 1);
      expect(driver.trace, ['BEGIN', 'COMMIT']);
      gate.complete(SqlResult());
      await fiber.awaitExit();
      expect(driver.trace, ['BEGIN', 'COMMIT']);
      expect(client.activeConnections, 0);
      await client.shutdown();
    },
  );
  test(
    '[SQL15] service layer owns shutdown on success and body failure',
    () async {
      for (final failed in [false, true]) {
        final driver = FakeDriver();
        final pool = SqlClient(driver), key = ServiceKey<SqlClient>('sql');
        final program = key
            .effect<SqlFailure>()
            .flatMap((db) => db.execute<Context>(SqlStatement('query')))
            .flatMap(
              (_) => failed
                  ? Effect.fail<Unit, SqlFailure, Context>(
                      const SqlFailure(SqlFailureKind.other, 'body'),
                    )
                  : Effect.succeed<Unit, SqlFailure, Context>(Unit.value),
            );
        await Runtime(Context()).runExit(pool.layer(key).use(program));
        expect(pool.isClosed, true);
        expect(driver.connections.single.closes, 1);
        expect(pool.idleConnections, 0);
      }
    },
  );
  test('[SQL13] summaries omit query and driver-secret text', () {
    final e = SqlFailure(
      SqlFailureKind.constraint,
      'execute',
      code: '23505',
      cause: StateError('secret'),
    );
    expect(e.toString(), 'SqlFailure(constraint, execute, 23505)');
  });
}
