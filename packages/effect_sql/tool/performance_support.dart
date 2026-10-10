// Shared development harness: real native drivers or the explicit synthetic fixture.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:effect_core/effect_core.dart';
import 'package:effect_sql/effect_sql.dart';

import '../../../tool/performance_memory.dart';

final class CountedDriver implements SqlDriver {
  CountedDriver(this.inner);
  final SqlDriver inner;
  int opened = 0, closed = 0, commands = 0, busy = 0, peakBusy = 0;
  Completer<void>? started;
  @override
  Future<SqlConnection> open() async {
    final connection = await inner.open();
    opened++;
    return _CountedConnection(connection, this);
  }

  @override
  SqlFailure? classify(Object e, String op) => inner.classify(e, op);
}

final class _CountedConnection implements SqlConnection {
  _CountedConnection(this.inner, this.owner);
  final SqlConnection inner;
  final CountedDriver owner;
  bool countedClosed = false;
  @override
  bool get isOpen => inner.isOpen;
  @override
  Future<SqlResult> execute(SqlStatement statement) async {
    owner.commands++;
    owner.busy++;
    if (owner.busy > owner.peakBusy) owner.peakBusy = owner.busy;
    final pending = inner.execute(statement);
    final start = owner.started;
    owner.started = null;
    start?.complete();
    try {
      return await pending;
    } finally {
      owner.busy--;
    }
  }

  @override
  Future<void> cancel() => inner.cancel();
  @override
  Future<void> close() async {
    await inner.close();
    if (!countedClosed) {
      countedClosed = true;
      owner.closed++;
    }
  }
}

final class Work {
  Work(this.effect, SqlDriver driver, this.dialect)
    : counted = CountedDriver(driver) {
    client = SqlClient(counted, maxConnections: 8);
  }
  final bool effect;
  final String dialect;
  final CountedDriver counted;
  late final SqlClient client;
  final runtime = Runtime(Unit.value);
  final direct = <SqlConnection>[];
  final idle = <SqlConnection>[];
  int sequence = 0;
  static const text = "bound café नमस्ते 😀 '";
  bool get synthetic => dialect == 'synthetic';
  String get placeholder => dialect == 'postgres' ? r'$1' : '?';
  SqlStatement get select => SqlStatement(
    dialect == 'postgres' ? r'SELECT $1::text AS value' : 'SELECT ? AS value',
    [text],
  );
  SqlStatement get sleep => SqlStatement(
    dialect == 'postgres' ? 'SELECT pg_sleep(0.002)' : 'SELECT SLEEP(0.002)',
  );
  Future<void> setup() async {
    if (effect) {
      await runtime.runFuture(
        Effect.traverse<int, SqlResult, SqlFailure, Unit>(
          List.generate(8, (i) => i),
          (_) => client.execute(sleep),
          concurrency: 8,
        ),
      );
    } else {
      for (var i = 0; i < 8; i++) {
        direct.add(await counted.open());
      }
      idle.addAll(direct);
    }
    if (!synthetic) {
      await query(
        SqlStatement(
          'CREATE TABLE IF NOT EXISTS effect_perf (id INTEGER PRIMARY KEY, value VARCHAR(128))',
        ),
      );
      await query(SqlStatement('DELETE FROM effect_perf'));
      await query(
        SqlStatement(
          'INSERT INTO effect_perf (id, value) VALUES (0, $placeholder)',
          [text],
        ),
      );
    }
    check(
      counted.opened == 8 && counted.busy == 0,
      'prewarm eight connections',
    );
  }

  Future<SqlResult> query(SqlStatement statement) async {
    if (effect) return runtime.runFuture(client.execute<Unit>(statement));
    check(idle.isNotEmpty, 'benchmark worker exceeded direct connection bound');
    final connection = idle.removeLast();
    try {
      return await connection.execute(statement);
    } finally {
      idle.add(connection);
    }
  }

  Future<void> transaction(bool rollback) async {
    final id = ++sequence;
    final insert = SqlStatement(
      'INSERT INTO effect_perf (id, value) VALUES ($id, $placeholder)',
      [text],
    );
    if (effect) {
      final exit = await runtime.runExit(
        client.transaction<SqlResult, Unit>(
          (session) => session
              .execute<Unit>(insert)
              .flatMap(
                (r) => rollback
                    ? Effect.fail(
                        const SqlFailure(
                          SqlFailureKind.other,
                          'deliberate rollback',
                        ),
                      )
                    : Effect.succeed(r),
              ),
        ),
      );
      if (rollback) {
        check(
          exit is Failure<SqlResult, SqlFailure> &&
              exit.cause is Expected<SqlFailure>,
          'rollback expected exit',
        );
      } else {
        check(exit is Success<SqlResult, SqlFailure>, 'commit exit');
      }
    } else {
      final connection = idle.removeLast();
      try {
        await connection.execute(SqlStatement('BEGIN'));
        try {
          await connection.execute(insert);
          if (rollback) {
            throw const SqlFailure(SqlFailureKind.other, 'deliberate rollback');
          }
          await connection.execute(SqlStatement('COMMIT'));
        } on SqlFailure {
          await connection.execute(SqlStatement('ROLLBACK'));
        }
      } finally {
        idle.add(connection);
      }
    }
  }

  Future<int> rows() async => int.parse(
    (await query(SqlStatement('SELECT COUNT(*) FROM effect_perf')))
        .rows
        .single
        .single
        .toString(),
  );
  Future<void> batch(String name) async {
    final before = counted.commands;
    var expectedCommands = 0;
    if (name == 'serial' || name == 'delayed') {
      expectedCommands = name == 'serial' ? 100 : 20;
      for (var i = 0; i < expectedCommands; i++) {
        final r = await query(name == 'serial' ? select : sleep);
        if (name == 'serial') {
          check(r.rows.single.single == text, 'prepared binding');
        }
      }
    } else if (name == 'bounded-8') {
      expectedCommands = 128;
      var next = 0;
      await Future.wait(
        List.generate(8, (_) async {
          while (next < 128) {
            next++;
            check(
              (await query(select)).rows.single.single == text,
              'bounded binding',
            );
          }
        }),
      );
    } else if (name == 'transactions') {
      final previous = synthetic ? 0 : await rows();
      for (var i = 0; i < 40; i++) {
        await transaction(i.isOdd);
      }
      if (!synthetic) {
        check(await rows() == previous + 20, 'commit/rollback row invariant');
      }
      expectedCommands = synthetic ? 120 : 122;
    } else if (name == 'failures') {
      for (var i = 0; i < 40; i++) {
        final duplicate = SqlStatement(
          'INSERT INTO effect_perf (id, value) VALUES (0, $placeholder)',
          [text],
        );
        if (effect) {
          final exit = await runtime.runExit(client.execute<Unit>(duplicate));
          check(
            exit is Failure<SqlResult, SqlFailure> &&
                exit.cause is Expected<SqlFailure> &&
                (exit.cause as Expected<SqlFailure>).error.kind ==
                    SqlFailureKind.constraint,
            'typed constraint',
          );
        } else {
          try {
            await query(duplicate);
            throw StateError('missing duplicate failure');
          } catch (e) {
            check(
              counted.classify(e, 'execute')?.kind == SqlFailureKind.constraint,
              'driver constraint',
            );
          }
        }
      }
      check(
        (await query(select)).rows.single.single == text,
        'recovery after constraint',
      );
      expectedCommands = 41;
    } else {
      throw ArgumentError(name);
    }
    check(
      counted.commands - before == expectedCommands,
      'unexpected command replay',
    );
    check(
      counted.busy == 0 &&
          counted.peakBusy <= 8 &&
          client.activeConnections == 0,
      'idle/bounded leases',
    );
  }

  Future<Map<String, Object?>> cancellation() async {
    check(effect, 'Effect ownership acceptance');
    // Start eight actual driver commands; cancel a ninth acquisition while all leases are occupied.
    final held = <Fiber<SqlResult, SqlFailure>>[];
    for (var i = 0; i < 8; i++) {
      counted.started = Completer<void>();
      final signal = counted.started!.future;
      held.add(
        runtime.fork(
          client.execute<Unit>(
            SqlStatement(
              dialect == 'postgres'
                  ? 'SELECT pg_sleep(0.15)'
                  : 'SELECT SLEEP(0.15)',
            ),
          ),
        ),
      );
      await signal;
    }
    final before = counted.commands;
    final queued = runtime.fork(client.execute<Unit>(select));
    final queuedExit = await queued.interruptAndAwait();
    check(
      queuedExit is Failure<SqlResult, SqlFailure> &&
          queuedExit.cause is Interrupted<SqlFailure>,
      'queued interruption',
    );
    check(counted.commands == before, 'canceled acquisition executed SQL');
    final timer = Stopwatch()..start();
    for (final fiber in held) {
      fiber.interrupt();
    }
    for (final fiber in held) {
      final exit = await fiber.awaitExit();
      check(
        exit is Failure<SqlResult, SqlFailure> &&
            exit.cause is Interrupted<SqlFailure>,
        'active interruption',
      );
    }
    final elapsed = timer.elapsedMicroseconds;
    check(
      counted.busy == 0 && client.activeConnections == 0,
      'cancellation not settled',
    );
    await batch('serial');
    return {
      'queuedCommandCount': 0,
      'interruptedCommands': 8,
      'interruptAndCleanupMicros': elapsed,
      'recoveryQueries': 100,
      'mode': dialect == 'postgres'
          ? 'force-close and replace'
          : 'await command drain then reuse',
    };
  }

  Future<void> dispose() async {
    await runtime.shutdown();
    await client.shutdown();
    for (final connection in direct) {
      await connection.close();
    }
    check(
      counted.busy == 0 &&
          counted.opened == counted.closed &&
          client.activeConnections == 0 &&
          client.idleConnections == 0 &&
          client.isClosed,
      'owner/socket cleanup',
    );
  }

  Map<String, Object?> counters() => {
    'opened': counted.opened,
    'closed': counted.closed,
    'commands': counted.commands,
    'peakBusy': counted.peakBusy,
    'busyAtEnd': counted.busy,
  };
}

@pragma('vm:never-inline')
Future<List<WeakReference<Object>>> churn(
  SqlDriver Function() driver,
  String dialect,
) async {
  final refs = <WeakReference<Object>>[];
  for (var i = 0; i < 10; i++) {
    final runtime = Runtime(Unit.value),
        client = SqlClient(driver(), maxConnections: 1);
    final payload = Uint8List(256 * 1024)..[0] = 1;
    final op = client.execute<Unit>(SqlStatement('SELECT 1')).map((r) {
      check(payload[0] == 1, 'captured payload');
      return r;
    });
    await runtime.runFuture(op);
    await runtime.shutdown();
    await client.shutdown();
    check(
      client.activeConnections == 0 && client.idleConnections == 0,
      'churn leases',
    );
    refs.addAll([
      WeakReference(runtime),
      WeakReference(client),
      WeakReference(payload),
      WeakReference(op),
    ]);
  }
  return refs;
}

Future<void> runPerformance(
  List<String> args,
  SqlDriver Function(bool direct) makeDriver,
  String dialect,
) async {
  final name = args[0], effect = args[1] == 'effect';
  final work = Work(effect, makeDriver(!effect), dialect);
  Map<String, Object?> result = {
    'workload': name,
    'implementation': args[1],
    'dialect': dialect,
    'mode': const bool.fromEnvironment('benchmark.aot') ? 'AOT' : 'JIT',
  };
  try {
    await work.setup();
    if (name == 'memory') {
      final probe = await HeapProbe.connect();
      try {
        for (var i = 0; i < 3; i++) {
          await work.batch('serial');
          if (!work.synthetic) {
            await work.batch('transactions');
            await work.batch('failures');
          }
        }
        final snapshots = [await probe.snapshot()];
        var collected = 0;
        for (var i = 0; i < 6; i++) {
          await work.batch('serial');
          await work.batch('bounded-8');
          if (!work.synthetic) {
            await work.batch('transactions');
            await work.batch('failures');
          }
          final refs = effect
              ? await churn(() => makeDriver(false), dialect)
              : <WeakReference<Object>>[];
          snapshots.add(await probe.snapshot());
          check(
            refs.every((r) => r.target == null),
            'closed SQL owners retained',
          );
          collected += refs.length;
        }
        final positive = Object();
        final held = WeakReference(positive);
        await probe.snapshot();
        check(held.target == positive, 'positive retention control');
        // Keep only the strong positive control as the diagnostic guard.
        result.addAll(memoryResult(snapshots, collected));
      } finally {
        await probe.close();
      }
    } else if (name == 'soak') {
      final seconds = int.parse(
        Platform.environment['EFFECT_BENCH_SECONDS'] ?? '30',
      );
      check(seconds >= 1 && seconds <= 300, 'bounded duration');
      final timer = Stopwatch()..start();
      final histogram = List.filled(5001, 0);
      var completed = 0, failed = 0;
      final beforeRows = work.synthetic ? 0 : await work.rows();
      final rss = <int>[];
      final poll = Timer.periodic(
        const Duration(seconds: 1),
        (_) => rss.add(ProcessInfo.currentRss),
      );
      try {
        await Future.wait(
          List.generate(8, (worker) async {
            while (timer.elapsed < Duration(seconds: seconds)) {
              final op = Stopwatch()..start();
              try {
                if (completed % 10 == 0 && !work.synthetic) {
                  await work.transaction(false);
                } else {
                  check(
                    (await work.query(work.select)).rows.single.single ==
                        Work.text,
                    'soak data',
                  );
                }
                completed++;
              } catch (_) {
                failed++;
                rethrow;
              }
              final ms = (op.elapsedMicroseconds / 1000).ceil().clamp(0, 5000);
              histogram[ms]++;
            }
          }),
        );
      } finally {
        poll.cancel();
      }
      final elapsed = timer.elapsedMicroseconds;
      check(
        failed == 0 && work.counted.peakBusy <= 8 && work.counted.busy == 0,
        'soak failure or bound',
      );
      if (!work.synthetic) {
        check(await work.rows() == beforeRows + work.sequence, 'soak writes');
      }
      int percentile(double q) {
        final target = (completed * q).ceil();
        var n = 0;
        for (var i = 0; i < histogram.length; i++) {
          n += histogram[i];
          if (n >= target) return i;
        }
        return 5000;
      }

      result.addAll({
        'requestedSeconds': seconds,
        'elapsedMicros': elapsed,
        'completed': completed,
        'failed': failed,
        'operationsPerSecond': completed * 1000000 / elapsed,
        'p50LatencyUpperMs': percentile(.5),
        'p95LatencyUpperMs': percentile(.95),
        'p99LatencyUpperMs': percentile(.99),
        'histogramMs': histogram,
        'rssSamplesBytes': rss,
        'committedTransactions': work.sequence,
      });
    } else if (name == 'cancellation') {
      result['acceptance'] = await work.cancellation();
    } else {
      for (var i = 0; i < 3; i++) {
        await work.batch(name);
      }
      final samples = <int>[];
      for (var i = 0; i < 9; i++) {
        final timer = Stopwatch()..start();
        await work.batch(name);
        samples.add(timer.elapsedMicroseconds);
      }
      result['samplesMicros'] = samples;
    }
  } finally {
    await work.dispose();
  }
  result.addAll({
    'counters': work.counters(),
    'success': true,
    'rssBytes': ProcessInfo.currentRss,
    'peakRssBytes': ProcessInfo.maxRss,
  });
  print(jsonEncode(result));
}
