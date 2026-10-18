import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:effect_cache/effect_cache.dart';
import 'package:test/test.dart';

Future<void> turn() => Future<void>.delayed(Duration.zero);
void main() {
  test(
    'concurrent waiters share load, one cancellation does not cancel owner',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      final done = Completer<int>(), started = Completer<void>();
      var loads = 0;
      final cache = EffectCache<String, int, String, Unit>(
        runtime: rt,
        capacity: 2,
        ttl: const Duration(seconds: 10),
        lookup: (_) => Effect.fromFuture(() {
          loads++;
          started.complete();
          return done.future;
        }),
      );
      addTearDown(cache.close);
      final a = rt.fork(cache.get('same')), b = rt.fork(cache.get('same'));
      await started.future;
      await a.interruptAndAwait();
      done.complete(7);
      expect((await b.awaitExit() as Success<int, String>).value, 7);
      expect(loads, 1);
      expect(await rt.runFuture(cache.get('same')), 7);
      expect(loads, 1);
    },
  );
  test(
    'TTL uses injected time, invalidation generations and LRU capacity',
    () async {
      final clock = TestClock();
      final rt = Runtime(Unit.value, clock: clock);
      addTearDown(rt.shutdown);
      var loads = 0;
      final cache = EffectCache<int, int, String, Unit>(
        runtime: rt,
        capacity: 2,
        ttl: const Duration(seconds: 1),
        lookup: (k) => Effect.sync(() => ++loads),
      );
      addTearDown(cache.close);
      await rt.runFuture(cache.get(1));
      await rt.runFuture(cache.get(2));
      await rt.runFuture(cache.get(1));
      await rt.runFuture(cache.get(3));
      expect(cache.size, 2);
      expect(await cache.peek(2), null);
      expect(loads, 3);
      clock.advance(const Duration(seconds: 1));
      expect(await cache.peek(1), null);
      await rt.runFuture(cache.get(1));
      expect(loads, 4);
      await cache.invalidateAll();
      expect(cache.size, 0);
    },
  );
  test('invalidation interrupts old in-flight generation without stale reinsertion', () async {
    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    final start = Completer<void>();
    var calls = 0;
    final cache = EffectCache<int, int, String, Unit>(
      runtime: rt,
      capacity: 1,
      ttl: const Duration(seconds: 10),
      lookup: (_) => Effect.fromFuture(() {
        calls++;
        if (calls == 1) {
          start.complete();
          return Completer<int>().future;
        }
        return Future.value(2);
      }),
    );
    addTearDown(cache.close);
    final old = rt.fork(cache.get(1));
    await start.future;
    await cache.invalidate(1);
    expect(await old.awaitExit(), isA<Failure<int, String>>());
    expect(await rt.runFuture(cache.get(1)), 2);
    expect(cache.size, 1);
  });
  test(
    'failure caching is opt-in and composites/defects are not retained',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      var calls = 0;
      final cache = EffectCache<int, int, String, Unit>(
        runtime: rt,
        capacity: 1,
        ttl: const Duration(seconds: 1),
        failureTtl: const Duration(seconds: 1),
        lookup: (_) => Effect.defer(() {
          calls++;
          return Effect.fail('missing');
        }),
      );
      addTearDown(cache.close);
      await rt.runExit(cache.get(1));
      await rt.runExit(cache.get(1));
      expect(calls, 1);
      await cache.close();
      expect(await rt.runExit(cache.get(1)), isA<Failure<int, String>>());
    },
  );
  test(
    'scoped cache retires borrowed generations and releases after user cleanup',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      final events = <String>[],
          started = Completer<void>(),
          finish = Completer<int>();
      var created = 0;
      final cache = ScopedCache<int, int, String, Unit>(
        runtime: rt,
        capacity: 1,
        ttl: const Duration(seconds: 10),
        acquire: (_) => Effect.sync<int, String, Unit>(() => ++created)
            .acquireScoped((id) => Effect.sync(() => events.add('release$id'))),
      );
      final first = rt.fork(
        cache.use(
          1,
          (id) =>
              Effect.fromFuture<int, String, Unit>(() {
                started.complete();
                return finish.future;
              }).ensuring(
                Effect.sync<Unit, String, Unit>(() {
                  events.add('user');
                  return Unit.value;
                }),
              ),
        ),
      );
      await started.future;
      cache.invalidate(1);
      expect(events, isEmpty);
      expect(await rt.runFuture(cache.use(1, (id) => Effect.succeed(id))), 2);
      finish.complete(9);
      await first.awaitExit();
      await cache.close();
      expect(events, ['user', 'release1', 'release2']);
      expect(created, 2);
    },
  );
  test(
    'scoped cache closes exactly once and preserves cleanup failures',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      var released = 0;
      final cache = ScopedCache<int, int, String, Unit>(
        runtime: rt,
        capacity: 1,
        ttl: const Duration(seconds: 10),
        acquire: (_) => Effect.succeed<int, String, Unit>(1).acquireScoped(
          (_) => Effect.defer(() {
            released++;
            return Effect.fail('release');
          }),
        ),
      );
      expect(await rt.runFuture(cache.use(1, Effect.succeed)), 1);
      final cause = await cache.close();
      expect((cause as Expected<String>).error, 'release');
      await cache.close();
      expect(released, 1);
    },
  );
}
