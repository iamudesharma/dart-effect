import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:effect_cache/effect_cache.dart';
import 'package:test/test.dart';

Future<void> until(bool Function() f) async {
  for (var i = 0; i < 200; i++) {
    if (f()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('No progress');
}

void main() {
  test(
    'owner bound includes blocked retirement, releases admission after cleanup',
    () async {
      final rt = Runtime(Unit.value), gate = Completer<Unit>();
      var loads = 0, releases = 0;
      final cache = EffectCache<int, int, String, Unit>(
        runtime: rt,
        capacity: 1,
        maxOwners: 2,
        onCapacity: () => 'overloaded',
        ttl: const Duration(seconds: 1),
        lookup: (key) {
          loads++;
          return Effect.succeed<int, String, Unit>(key).ensuring(
            Effect.fromFuture<Unit, String, Unit>(() async {
              await gate.future;
              releases++;
              return Unit.value;
            }),
          );
        },
      );
      final first = rt.fork(cache.get(1));
      await until(() => loads == 1);
      final second = rt.fork(cache.get(2));
      await until(() => loads == 2);
      expect(cache.stats.owners, 2);
      expect(cache.size, 1);
      for (var i = 3; i < 100; i++) {
        final exit = await rt.runExit(cache.get(i));
        expect(
          (exit as Failure<int, String>).cause.expectedErrors.single,
          'overloaded',
        );
      }
      expect(loads, 2);
      expect(cache.stats.owners, 2);
      gate.complete(Unit.value);
      await first.awaitExit();
      await second.awaitExit();
      await until(() => cache.stats.owners == 0);
      expect(await rt.runFuture(cache.get(100)), 100);
      await cache.close();
      await rt.shutdown();
      expect(releases, 3);
    },
  );
  test('nested scoped generation fails promptly instead of deadlocking last permit', () async {
    final rt = Runtime(Unit.value);
    var acquired = 0, released = 0;
    final cache = ScopedCache<int, int, String, Unit>(
      runtime: rt,
      capacity: 1,
      maxOwners: 1,
      onCapacity: () => 'full',
      ttl: const Duration(seconds: 1),
      acquire: (key) =>
          Effect.sync<int, String, Unit>(() {
            acquired++;
            return key;
          }).acquireScoped(
            (_) => Effect.sync(() {
              released++;
              return Unit.value;
            }),
          ),
    );
    final exit = await rt.runExit(
      cache.use(1, (_) => cache.refresh(1, (v) => Effect.succeed(v))),
    );
    expect((exit as Failure<int, String>).cause.expectedErrors.single, 'full');
    await cache.close();
    await rt.shutdown();
    expect(acquired, 1);
    expect(released, 1);
  });
  test(
    'completed outcomes preserve failure TTL, identity and nullable values',
    () async {
      final rt = Runtime(Unit.value), clock = TestClock();
      final timed = Runtime(Unit.value, clock: clock);
      var calls = 0;
      final cache = EffectCache<int, int?, String, Unit>(
        runtime: timed,
        capacity: 2,
        ttl: const Duration(seconds: 1),
        failureTtl: const Duration(seconds: 1),
        lookup: (k) {
          calls++;
          return k == 0 ? Effect.fail('missing') : Effect.succeed(null);
        },
      );
      await timed.runExit(cache.get(0));
      await timed.runExit(cache.get(0));
      expect(await timed.runFuture(cache.get(1)), null);
      expect(await timed.runFuture(cache.get(1)), null);
      expect(calls, 2);
      expect(cache.stats.owners, 0);
      expect(await cache.peek(1), isA<Success<int?, String>>());
      clock.advance(const Duration(seconds: 1));
      await cache.purgeExpired();
      expect(cache.size, 0);
      await cache.close();
      await timed.shutdown();
      await rt.shutdown();
    },
  );
}
