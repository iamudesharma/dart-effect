import 'dart:async';
import 'dart:math';

import 'package:effect_core/effect_core.dart';
import 'package:effect_cache/effect_cache.dart';
import 'package:test/test.dart';

Future<void> until(bool Function() condition) async {
  for (var n = 0; n < 200; n++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition did not become true');
}

const second = Duration(seconds: 1);

void main() {
  late TestClock clock;
  late Runtime<Unit> rt;
  setUp(() {
    clock = TestClock();
    rt = Runtime(Unit.value, clock: clock);
  });
  tearDown(() => rt.shutdown());
  EffectCache<int, int, String, Unit> valueCache(
    Effect<int, String, Unit> Function(int) load, {
    int capacity = 2,
    Duration ttl = second,
    Duration? failureTtl,
  }) {
    final c = EffectCache<int, int, String, Unit>(
      runtime: rt,
      capacity: capacity,
      ttl: ttl,
      failureTtl: failureTtl,
      lookup: load,
    );
    addTearDown(c.close);
    return c;
  }

  ScopedCache<int, int, String, Unit> resourceCache(
    Effect<int, String, Unit> Function(int) acquire, {
    int capacity = 2,
    Duration ttl = second,
  }) {
    final c = ScopedCache<int, int, String, Unit>(
      runtime: rt,
      capacity: capacity,
      ttl: ttl,
      acquire: acquire,
    );
    addTearDown(c.close);
    return c;
  }

  test('policies reject invalid bounds; zero TTL is supported', () async {
    for (final capacity in [0, -1]) {
      expect(
        () => valueCache((_) => Effect.succeed(1), capacity: capacity),
        throwsArgumentError,
      );
      expect(
        () => resourceCache((_) => Effect.succeed(1), capacity: capacity),
        throwsArgumentError,
      );
    }
    expect(
      () => valueCache((_) => Effect.succeed(1), ttl: -second),
      throwsArgumentError,
    );
    expect(
      () => valueCache((_) => Effect.succeed(1), failureTtl: -second),
      throwsArgumentError,
    );
    expect(
      () => resourceCache((_) => Effect.succeed(1), ttl: -second),
      throwsArgumentError,
    );
    var calls = 0;
    final c = valueCache((_) => Effect.sync(() => ++calls), ttl: Duration.zero);
    expect(await rt.runFuture(c.get(1)), 1);
    expect(await rt.runFuture(c.get(1)), 2);
    expect(c.size, 0);
  });
  test('get is lazy and thirty waiters share one root', () async {
    var calls = 0;
    final ready = Completer<int>();
    final c = valueCache(
      (_) => Effect.fromFuture(() {
        calls++;
        return ready.future;
      }),
    );
    final effect = c.get(1);
    expect(c.size, 0);
    expect(calls, 0);
    final waiters = List.generate(30, (_) => rt.runFuture(effect));
    await until(() => calls == 1);
    expect(c.containsKey(1), isTrue);
    expect(await c.peek(1), isNull);
    expect(c.stats.loads, 1);
    expect(c.stats.hits, 29);
    ready.complete(42);
    expect(await Future.wait(waiters), everyElement(42));
  });
  test(
    'last waiter interruption leaves load until explicit invalidation',
    () async {
      var started = false, aborted = 0;
      final c = valueCache(
        (_) => Effect.fromFuture(() {
          started = true;
          return Completer<int>().future;
        }, onCancel: () => aborted++),
      );
      final waiter = rt.fork(c.get(1));
      await until(() => started);
      expect(
        (await waiter.interruptAndAwait() as Failure<int, String>)
            .cause
            .isInterrupted,
        isTrue,
      );
      expect(aborted, 0);
      expect(c.size, 1);
      await c.invalidate(1);
      expect(aborted, 1);
      expect(c.size, 0);
    },
  );
  test('TTL starts on completion, expires exactly on the boundary', () async {
    final done = Completer<int>();
    var calls = 0;
    final c = valueCache(
      (_) => Effect.fromFuture(() {
        calls++;
        return done.future;
      }),
    );
    final pending = rt.runFuture(c.get(1));
    await until(() => calls == 1);
    clock.advance(const Duration(hours: 1));
    done.complete(3);
    await pending;
    clock.advance(const Duration(microseconds: 999999));
    expect((await c.peek(1) as Success<int, String>).value, 3);
    clock.advance(const Duration(microseconds: 1));
    expect(await c.peek(1), isNull);
    expect(c.keys, isEmpty);
    await c.purgeExpired();
    expect(c.size, 0);
    expect(c.stats.expirations, 1);
  });
  test(
    'expected failure TTL differs from success; default never retains failure',
    () async {
      var calls = 0;
      final c = valueCache(
        (_) => Effect.defer(() {
          calls++;
          return Effect.fail('missing');
        }),
        failureTtl: second * 2,
      );
      await rt.runExit(c.get(1));
      clock.advance(second);
      await rt.runExit(c.get(1));
      expect(calls, 1);
      clock.advance(second);
      await rt.runExit(c.get(1));
      expect(calls, 2);
      final uncached = valueCache(
        (_) => Effect.defer(() {
          calls++;
          return Effect.fail('missing');
        }),
      );
      await rt.runExit(uncached.get(1));
      await rt.runExit(uncached.get(1));
      expect(calls, 4);
    },
  );
  test('defects and sequential body/cleanup failures never cache', () async {
    var calls = 0;
    final c = valueCache(
      (_) => Effect.sync<int, String, Unit>(() {
        calls++;
        throw StateError('boom');
      }),
      failureTtl: second,
    );
    for (var i = 0; i < 2; i++) {
      expect(
        (await rt.runExit(c.get(1)) as Failure<int, String>).cause,
        isA<Defect<String>>(),
      );
    }
    expect(calls, 2);
    final composite = valueCache(
      (_) => Effect.defer(() {
        calls++;
        return Effect.fail<int, String, Unit>('body')
            .ensuring(Effect.fail('cleanup'));
      }),
      failureTtl: second,
    );
    for (var i = 0; i < 2; i++) {
      expect(
        (await rt.runExit(
          composite.get(1),
        ) as Failure<int, String>).cause.expectedErrors,
        ['body', 'cleanup'],
      );
    }
    expect(calls, 4);
  });
  test('null payload differs from a missing entry', () async {
    final c = EffectCache<int, int?, String, Unit>(
      runtime: rt,
      capacity: 1,
      ttl: second,
      lookup: (_) => Effect.succeed(null),
    );
    addTearDown(c.close);
    expect(await c.peek(1), null);
    await rt.runFuture(c.get(1));
    expect(await c.peek(1), isA<Success<int?, String>>());
  });
  test('inspection snapshots are immutable and do not change LRU', () async {
    final c = valueCache(Effect.succeed);
    await rt.runFuture(c.get(1));
    await rt.runFuture(c.get(2));
    final snapshot = c.stats, keys = c.keys;
    expect(() => keys.add(3), throwsUnsupportedError);
    await c.peek(1);
    expect(c.containsKey(1), isTrue);
    await rt.runFuture(c.get(3));
    expect(c.containsKey(1), isFalse);
    expect(c.keys, [2, 3]);
    expect(snapshot.loads, 2);
    expect(c.stats.loads, 3);
    expect(c.stats.evictions, 1);
  });
  test(
    'pending capacity eviction aborts old owner and preserves new generation',
    () async {
      var started = false, aborted = 0;
      final c = valueCache(
        (k) => k == 1
            ? Effect.fromFuture(() {
                started = true;
                return Completer<int>().future;
              }, onCancel: () => aborted++)
            : Effect.succeed(k),
        capacity: 1,
      );
      final old = rt.fork(c.get(1));
      await until(() => started);
      expect(await rt.runFuture(c.get(2)), 2);
      expect(
        (await old.awaitExit() as Failure<int, String>).cause.isInterrupted,
        isTrue,
      );
      expect(aborted, 1);
      expect(c.keys, [2]);
    },
  );
  test(
    'refresh reloads, nonloading peek stays empty while replacement loads',
    () async {
      var calls = 0;
      final gate = Completer<int>();
      final c = valueCache(
        (_) => Effect.defer(() {
          calls++;
          return calls == 1
              ? Effect.succeed(1)
              : Effect.fromFuture(() => gate.future);
        }),
      );
      await rt.runFuture(c.get(1));
      final refresh = rt.runFuture(c.refresh(1));
      await until(() => calls == 2);
      expect(await c.peek(1), null);
      final read = rt.runFuture(c.get(1));
      gate.complete(9);
      expect(await refresh, 9);
      expect(await read, 9);
      expect(calls, 2);
    },
  );
  test(
    'invalidate and close await protected cleanup and preserve its failure',
    () async {
      final release = Completer<void>();
      var started = false, cleaning = false;
      final c = valueCache(
        (_) =>
            Effect.fromFuture<int, String, Unit>(() {
              started = true;
              return Completer<int>().future;
            }).ensuring(
              Effect.fromFuture<Unit, String, Unit>(() async {
                cleaning = true;
                await release.future;
                return Unit.value;
              }).flatMap((_) => Effect.fail('release')),
            ),
      );
      final read = rt.fork(c.get(1));
      await until(() => started);
      final invalidated = c.invalidate(1);
      await until(() => cleaning);
      var closed = false;
      final first = c.close();
      final secondClose = c.close();
      expect(identical(first, secondClose), isTrue);
      final closing = first.then((v) {
        closed = true;
        return v;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(
        (await rt.runExit(c.get(2)) as Failure<int, String>).cause,
        isA<Defect<String>>(),
      );
      release.complete();
      expect((await invalidated)!.expectedErrors, ['release']);
      expect((await closing)!.expectedErrors, ['release']);
      await read.awaitExit();
      expect(c.stats.owners, 0);
    },
  );
  test('retirement diagnostic history is bounded and drainable', () async {
    final c = valueCache(
      (_) =>
          Effect.fromFuture<int, String, Unit>(() => Completer<int>().future)
              .ensuring(Effect.fail('cleanup')),
    );
    for (var i = 0; i < 40; i++) {
      final read = rt.fork(c.get(i));
      await until(() => c.size == 1);
      // Let the lookup enter its ensuring region before cancelling it.
      await Future<void>.delayed(Duration.zero);
      await c.invalidate(i);
      await read.awaitExit();
    }
    expect(c.stats.droppedDiagnostics, 8);
    expect(c.takeDiagnostics(), hasLength(32));
    expect(c.stats.droppedDiagnostics, 0);
    expect(c.takeDiagnostics(), isEmpty);
    expect(await c.close(), null);
  });
  test(
    'idle maintenance purges expired values and close removes its sleeper',
    () async {
      final c = valueCache(Effect.succeed);
      await rt.runFuture(c.get(1));
      final worker = c.startMaintenance(interval: second);
      expect(() => c.startMaintenance(interval: second), throwsStateError);
      await until(() => clock.pendingSleeps == 1);
      clock.advance(second);
      await until(() => c.size == 0 && clock.pendingSleeps == 1);
      await c.close();
      expect(clock.pendingSleeps, 0);
      expect(
        (await worker.awaitExit() as Failure<Unit, String>).cause.isInterrupted,
        isTrue,
      );
      expect(() => c.startMaintenance(interval: second), throwsStateError);
    },
  );
  test(
    'periodic refresh includes expired residents and exposes typed failure',
    () async {
      var calls = 0;
      final c = valueCache(
        (_) => Effect.defer(() {
          calls++;
          return calls == 3 ? Effect.fail('offline') : Effect.succeed(calls);
        }),
      );
      expect(
        () => c.startMaintenance(interval: Duration.zero),
        throwsArgumentError,
      );
      await rt.runFuture(c.get(1));
      final worker = c.startMaintenance(interval: second, refresh: true);
      await until(() => clock.pendingSleeps == 1);
      clock.advance(second);
      await until(() => calls == 2 && clock.pendingSleeps == 1);
      expect((await c.peek(1) as Success<int, String>).value, 2);
      clock.advance(second);
      expect(
        (await worker.awaitExit() as Failure<Unit, String>)
            .cause
            .expectedErrors,
        ['offline'],
      );
      expect(clock.pendingSleeps, 0);
      expect(c.size, 0);
    },
  );
  test(
    'scoped shared acquisition supports independent borrower cancellation',
    () async {
      final gate = Completer<int>();
      var calls = 0, releases = 0, entered = 0;
      final c = resourceCache(
        (_) => Effect.fromFuture<int, String, Unit>(() {
          calls++;
          return gate.future;
        }).acquireScoped((_) => Effect.sync(() => releases++)),
      );
      final a = rt.fork(c.use(1, Effect.succeed));
      final b = rt.fork(
        c.use(
          1,
          (v) => Effect.sync(() {
            entered++;
            return v;
          }),
        ),
      );
      await until(() => calls == 1);
      await a.interruptAndAwait();
      gate.complete(4);
      expect((await b.awaitExit() as Success<int, String>).value, 4);
      expect(entered, 1);
      expect(releases, 0);
      await c.close();
      expect(releases, 1);
    },
  );
  test(
    'scoped acquisition failure reaches caller but does not poison shutdown',
    () async {
      var calls = 0;
      final c = resourceCache(
        (_) => Effect.defer(() {
          calls++;
          return Effect.fail('missing');
        }),
      );
      for (var i = 0; i < 2; i++) {
        expect(
          (await rt.runExit(
            c.use(1, Effect.succeed),
          ) as Failure<int, String>).cause.expectedErrors,
          ['missing'],
        );
      }
      expect(calls, 2);
      expect(await c.close(), null);
      expect(c.stats.owners, 0);
    },
  );
  test(
    'failed scoped acquisition retains appended root cleanup diagnostics',
    () async {
      final c = resourceCache(
        (_) =>
            Effect.succeed<int, String, Unit>(1)
                .acquireScoped((_) => Effect.fail('release'))
                .flatMap((_) => Effect.fail('acquire')),
      );
      final exit =
          await rt.runExit(c.use(1, Effect.succeed)) as Failure<int, String>;
      expect(exit.cause.expectedErrors, ['acquire', 'release']);
      expect((await c.close())!.expectedErrors, ['release']);
    },
  );
  test(
    'scoped invalidation interrupts pending acquisition and awaits cleanup',
    () async {
      var started = false, aborted = 0;
      final c = resourceCache(
        (_) => Effect.fromFuture(() {
          started = true;
          return Completer<int>().future;
        }, onCancel: () => aborted++),
      );
      final read = rt.fork(c.use(1, Effect.succeed));
      await until(() => started);
      c.invalidate(1);
      await c.close();
      expect(
        (await read.awaitExit() as Failure<int, String>).cause.isInterrupted,
        isTrue,
      );
      expect(aborted, 1);
      expect(c.stats.owners, 0);
    },
  );
  test(
    'scoped refresh overlaps old borrow without releasing a live resource',
    () async {
      final entered = Completer<void>(), done = Completer<int>();
      final released = <int>[];
      var loads = 0;
      final c = resourceCache(
        (_) =>
            Effect.sync<int, String, Unit>(() => ++loads)
                .acquireScoped((v) => Effect.sync(() => released.add(v))),
      );
      final old = rt.fork(
        c.use(
          1,
          (v) => Effect.fromFuture<int, String, Unit>(() {
            entered.complete();
            return done.future;
          }),
        ),
      );
      await entered.future;
      expect(await rt.runFuture(c.refresh(1, Effect.succeed)), 2);
      expect(released, isEmpty);
      done.complete(7);
      await old.awaitExit();
      await until(() => released.contains(1));
      await c.close();
      expect(released, [1, 2]);
    },
  );
  test(
    'scoped close awaits borrower finalizers before resource finalizers',
    () async {
      final body = Completer<void>(), userCleanup = Completer<void>();
      var entered = false, cleaning = false, closed = false;
      final events = <String>[];
      final c = resourceCache(
        (_) => Effect.succeed<int, String, Unit>(1)
            .acquireScoped((_) => Effect.sync(() => events.add('resource'))),
      );
      final read = rt.fork(
        c.use(
          1,
          (_) =>
              Effect.fromFuture<int, String, Unit>(() async {
                entered = true;
                await body.future;
                return 1;
              }).ensuring(
                Effect.fromFuture(() async {
                  cleaning = true;
                  await userCleanup.future;
                  events.add('user');
                  return Unit.value;
                }),
              ),
        ),
      );
      await until(() => entered);
      final closing = c.close().then((_) => closed = true);
      body.complete();
      await until(() => cleaning);
      expect(closed, isFalse);
      expect(events, isEmpty);
      userCleanup.complete();
      await read.awaitExit();
      await closing;
      expect(events, ['user', 'resource']);
      expect(
        (await rt.runExit(
          c.use(1, Effect.succeed),
        ) as Failure<int, String>).cause,
        isA<Defect<String>>(),
      );
    },
  );
  test('scoped idle expiry releases once without any next read', () async {
    var released = 0;
    final c = resourceCache(
      (_) =>
          Effect.succeed<int, String, Unit>(1)
              .acquireScoped((_) => Effect.sync(() => released++)),
    );
    await rt.runFuture(c.use(1, Effect.succeed));
    c.startMaintenance(interval: second);
    await until(() => clock.pendingSleeps == 1);
    clock.advance(second);
    await until(() => released == 1);
    expect(c.size, 0);
    expect(c.stats.expirations, 1);
    await c.close();
    expect(released, 1);
    expect(clock.pendingSleeps, 0);
  });
  test(
    'scoped LRU and invalidate-all retain borrowed retired generations',
    () async {
      final released = <int>[];
      final c = resourceCache(
        (k) =>
            Effect.succeed<int, String, Unit>(k)
                .acquireScoped((v) => Effect.sync(() => released.add(v))),
      );
      for (final key in [1, 2, 1, 3]) {
        await rt.runFuture(c.use(key, Effect.succeed));
      }
      await until(() => released.contains(2));
      expect(c.keys, [1, 3]);
      c.invalidateAll();
      await until(() => c.stats.owners == 0);
      expect(released.toSet(), {1, 2, 3});
      expect(c.stats.evictions, 1);
      expect(await c.close(), null);
    },
  );
  test('scoped zero TTL never reuses a completed resource', () async {
    var loads = 0, released = 0;
    final c = resourceCache(
      (_) =>
          Effect.sync<int, String, Unit>(() => ++loads)
              .acquireScoped((_) => Effect.sync(() => released++)),
      ttl: Duration.zero,
    );
    expect(await rt.runFuture(c.use(1, Effect.succeed)), 1);
    expect(await rt.runFuture(c.use(1, Effect.succeed)), 2);
    c.purgeExpired();
    await c.close();
    expect(released, 2);
  });
  test(
    'owner shutdown misuse leaves cache closable without late-field errors',
    () async {
      final owner = Runtime(Unit.value);
      await owner.shutdown();
      final c = ScopedCache<int, int, String, Unit>(
        runtime: owner,
        acquire: Effect.succeed,
        capacity: 1,
        ttl: second,
      );
      expect(
        (await rt.runExit(
          c.use(1, Effect.succeed),
        ) as Failure<int, String>).cause,
        isA<Defect<String>>(),
      );
      expect(await c.close(), null);
      expect(c.stats.owners, 0);
      expect(c.size, 0);
    },
  );
  test(
    'deterministic state model agrees across 500 LRU/expiry operations',
    () async {
      final random = Random(1701);
      var sequence = 0;
      final c = valueCache((_) => Effect.sync(() => ++sequence), capacity: 4);
      final model = <int, (Duration, int)>{};
      for (var step = 0; step < 500; step++) {
        final key = random.nextInt(8), action = random.nextInt(10);
        if (action < 5) {
          final old = model.remove(key);
          final hit = old != null && clock.elapsed < old.$1;
          if (!hit && model.length >= 4) model.remove(model.keys.first);
          final expected = hit ? old.$2 : sequence + 1;
          expect(
            await rt.runFuture(c.get(key)),
            expected,
            reason: 'step $step',
          );
          model[key] = hit ? old : (clock.elapsed + second, expected);
        } else if (action < 7) {
          await c.invalidate(key);
          model.remove(key);
        } else if (action < 9) {
          await c.purgeExpired();
          model.removeWhere((_, v) => clock.elapsed >= v.$1);
        } else {
          clock.advance(const Duration(milliseconds: 500));
        }
        expect(c.size, model.length, reason: 'resident size step $step');
        expect(
          c.keys,
          model.entries
              .where((e) => clock.elapsed < e.value.$1)
              .map((e) => e.key)
              .toList(),
        );
      }
    },
  );
  test(
    'close during protected scoped acquisition waits and releases exactly once',
    () async {
      final gate = Completer<int>();
      var started = false, released = 0, used = false, closed = false;
      final c = resourceCache(
        (_) => Effect.fromFuture<int, String, Unit>(() {
          started = true;
          return gate.future;
        }).acquireScoped((_) => Effect.sync(() => released++)),
      );
      final reader = rt.fork(
        c.use(
          1,
          (v) => Effect.sync(() {
            used = true;
            return v;
          }),
        ),
      );
      await until(() => started);
      final closing = c.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      gate.complete(1);
      await closing;
      await reader.awaitExit();
      expect(released, 1);
      expect(used, isFalse);
      expect(c.stats.owners, 0);
    },
  );
  test('throwing borrow callback does not leak a borrower lease', () async {
    var released = 0;
    final c = resourceCache(
      (_) =>
          Effect.succeed<int, String, Unit>(1)
              .acquireScoped((_) => Effect.sync(() => released++)),
    );
    final exit = await rt.runExit(
      c.use<int>(1, (_) => throw StateError('user')),
    );
    expect((exit as Failure<int, String>).cause, isA<Defect<String>>());
    expect(await c.close(), null);
    expect(released, 1);
  });
  test('scoped periodic refresh retires each generation and worker stops on failure', () async {
    var acquired = 0;
    final released = <int>[];
    final c = resourceCache(
      (_) => Effect.defer<int, String, Unit>(() {
        acquired++;
        return acquired == 3
            ? Effect.fail('offline')
            : Effect.succeed<int, String, Unit>(acquired)
                  .acquireScoped((v) => Effect.sync(() => released.add(v)));
      }),
    );
    await rt.runFuture(c.use(1, Effect.succeed));
    final worker = c.startMaintenance(interval: second, refresh: true);
    await until(() => clock.pendingSleeps == 1);
    clock.advance(second);
    await until(() => acquired == 2 && clock.pendingSleeps == 1);
    expect(await rt.runFuture(c.use(1, Effect.succeed)), 2);
    clock.advance(second);
    expect(
      (await worker.awaitExit() as Failure<Unit, String>).cause.expectedErrors,
      ['offline'],
    );
    await c.close();
    expect(released, [1, 2]);
    expect(clock.pendingSleeps, 0);
  });
}
