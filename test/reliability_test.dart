import 'dart:async';
import 'dart:math';

import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

Future<void> turn() => Future<void>.delayed(Duration.zero);
Future<void> sleepers(TestClock clock, int count) async {
  for (var i = 0; i < 100 && clock.pendingSleeps < count; i++) {
    await turn();
  }
  expect(clock.pendingSleeps, count);
}

void main() {
  test(
    'timeout retains failed release after interrupted worker, exactly once',
    () async {
      final clock = TestClock();
      final rt = Runtime(Unit.value, clock: clock);
      var released = 0;
      final effect = Effect.acquireUseRelease<int, Unit, String, Unit>(
        Effect.succeed(1),
        (_) => Effect.sleep(const Duration(seconds: 20)),
        (_, _) => Effect.defer(() {
          released++;
          return Effect.fail('release');
        }),
      ).timeout(const Duration(seconds: 1), () => 'timeout');
      final fiber = rt.fork(effect);
      await sleepers(clock, 2);
      clock.advance(const Duration(seconds: 1));
      final cause =
          (await fiber.awaitExit() as Failure<Unit, String>).cause
              as Sequential<String>;
      expect((cause.first as Expected<String>).error, 'timeout');
      expect((cause.second as Expected<String>).error, 'release');
      expect(released, 1);
      expect(clock.pendingSleeps, 0);
      await rt.shutdown();
    },
  );
  test('typed retry predicate rejects permanent expected failures', () async {
    var calls = 0;
    final effect = Effect.defer<int, String, Unit>(() {
      calls++;
      return Effect.fail('permanent');
    });
    final rt = Runtime(Unit.value);
    await rt.runExit(
      effect.retry(
        Schedule(recurrences: 4),
        whileError: (String e) => e == 'transient',
      ),
    );
    expect(calls, 1);
    await rt.shutdown();
  });
  test(
    'server delay takes precedence over cap and budget rejects retry',
    () async {
      final clock = TestClock(), rt = Runtime(Unit.value);
      var calls = 0;
      final effect = Effect.defer<int, String, Unit>(() {
        calls++;
        return Effect.fail('busy');
      });
      await rt.runExit(
        effect.retry(
          Schedule(
            recurrences: 4,
            maxDelay: Duration.zero,
            elapsedBudget: const Duration(seconds: 1),
          ),
          retryAfter: (_, _) => const Duration(seconds: 2),
        ),
      );
      expect(calls, 1);
      expect(clock.pendingSleeps, 0);
      await rt.shutdown();
    },
  );
  test('budget includes operation time and stops zero-delay retries', () async {
    final clock = TestClock();
    final rt = Runtime(Unit.value, clock: clock);
    var calls = 0;
    final effect = Effect.defer<int, String, Unit>(() {
      calls++;
      clock.advance(const Duration(seconds: 1));
      return Effect.fail('busy');
    });
    await rt.runExit(
      effect.retry(
        Schedule(recurrences: 8, elapsedBudget: const Duration(seconds: 2)),
      ),
    );
    expect(calls, 2);
    await rt.shutdown();
  });
  test('seeded jitter repeats, default executions receive independent sources, cap holds', () {
    final s = Schedule(
      recurrences: 10,
      seed: 8,
      jitter: 1,
      initialDelay: const Duration(seconds: 1),
      factor: 3,
      maxDelay: const Duration(seconds: 2),
    );
    final a = s.newRandom(), b = s.newRandom();
    for (var i = 0; i < 10; i++) {
      final delay = s.delay(i, a);
      expect(delay, s.delay(i, b));
      expect(delay <= const Duration(seconds: 2), true);
    }
    final independent = Schedule(recurrences: 1);
    expect(identical(independent.newRandom(), independent.newRandom()), false);
    expect(
      () =>
          Schedule(recurrences: 1, elapsedBudget: const Duration(seconds: -1)),
      throwsArgumentError,
    );
    expect(s.delay(10000, Random(1)), const Duration(seconds: 2));
  });
  test(
    'metrics finish after cleanup, throwing observer cannot alter success',
    () async {
      final metrics = RuntimeMetrics();
      final events = <LifecycleEvent>[];
      final rt = Runtime(
        Unit.value,
        metrics: metrics,
        lifecycle: (e) {
          events.add(e);
          throw StateError('observer');
        },
      );
      final exit = await rt.runExit(Effect.succeed<int, String, Unit>(1));
      expect(exit, isA<Success<int, String>>());
      expect(events.map((e) => e.phase), ['start', 'cleanup', 'end']);
      expect(metrics.active, 0);
      expect(metrics.started, 1);
      expect(metrics.completed, 1);
      await rt.shutdown();
    },
  );
  test(
    'breaker opens, rejects, admits only one half-open probe and closes',
    () async {
      final clock = TestClock(),
          breaker = CircuitBreaker(
            failureThreshold: 1,
            resetAfter: const Duration(seconds: 1),
          );
      final rt = Runtime(Unit.value, clock: clock);
      await rt.runExit(
        breaker.protect(
          Effect.fail<int, String, Unit>('bad'),
          onOpen: () => 'open',
        ),
      );
      expect(breaker.state, CircuitState.open);
      final blocked = await rt.runExit(
        breaker.protect(
          Effect.succeed<int, String, Unit>(2),
          onOpen: () => 'open',
        ),
      );
      expect(
        ((blocked as Failure<int, String>).cause as Expected<String>).error,
        'open',
      );
      clock.advance(const Duration(seconds: 1));
      final done = Completer<int>(), started = Completer<void>();
      final probe = rt.fork(
        breaker.protect(
          Effect.fromFuture<int, String, Unit>(() {
            started.complete();
            return done.future;
          }),
          onOpen: () => 'open',
        ),
      );
      await started.future;
      expect(breaker.state, CircuitState.halfOpen);
      expect(
        await rt.runExit(
          breaker.protect(
            Effect.succeed<int, String, Unit>(3),
            onOpen: () => 'open',
          ),
        ),
        isA<Failure<int, String>>(),
      );
      done.complete(2);
      await probe.awaitExit();
      expect(breaker.state, CircuitState.closed);
      await rt.shutdown();
    },
  );
  test(
    'cancelled probe releases admission and excluded errors do not trip',
    () async {
      final breaker = CircuitBreaker(
        failureThreshold: 1,
        resetAfter: Duration.zero,
      );
      final rt = Runtime(Unit.value);
      await rt.runExit(
        breaker.protect(
          Effect.fail<int, String, Unit>('ignore'),
          onOpen: () => 'open',
          countsAsFailure: (_) => false,
        ),
      );
      expect(breaker.state, CircuitState.closed);
      await rt.runExit(
        breaker.protect(
          Effect.fail<int, String, Unit>('bad'),
          onOpen: () => 'open',
        ),
      );
      final started = Completer<void>();
      final probe = rt.fork(
        breaker.protect(
          Effect.fromFuture<int, String, Unit>(() {
            started.complete();
            return Completer<int>().future;
          }),
          onOpen: () => 'open',
        ),
      );
      await started.future;
      await probe.interruptAndAwait();
      expect(breaker.state, CircuitState.open);
      expect(
        await rt.runExit(
          breaker.protect(
            Effect.succeed<int, String, Unit>(1),
            onOpen: () => 'open',
          ),
        ),
        isA<Success<int, String>>(),
      );
      await rt.shutdown();
    },
  );
  test(
    'rate limit spaces concurrent admission and cancellation removes sleeper',
    () async {
      final clock = TestClock(),
          limiter = RateLimiter(const Duration(seconds: 1));
      final rt = Runtime(Unit.value, clock: clock);
      var calls = 0;
      final effect = Effect.sync<int, String, Unit>(() => ++calls);
      await rt.runFuture(limiter.limit(effect));
      final cancelled = rt.fork(limiter.limit(effect));
      await sleepers(clock, 1);
      await cancelled.interruptAndAwait();
      final next = rt.fork(limiter.limit(effect));
      await sleepers(clock, 1);
      clock.advance(const Duration(seconds: 1));
      await turn();
      expect(calls, 1);
      clock.advance(const Duration(seconds: 1));
      await next.awaitExit();
      expect(calls, 2);
      expect(clock.pendingSleeps, 0);
      await rt.shutdown();
    },
  );

  test(
    'parent cancellation keeps cleanup defect instead of fabricating timeout',
    () async {
      final clock = TestClock();
      final rt = Runtime(Unit.value, clock: clock);
      final fiber = rt.fork(
        Effect.sleep<String, Unit>(const Duration(seconds: 20))
            .ensuring(
              Effect.sync<Unit, String, Unit>(
                () => throw StateError('cleanup'),
              ),
            )
            .timeout(const Duration(seconds: 10), () => 'timeout'),
      );
      await sleepers(clock, 2);
      final cause =
          (await fiber.interruptAndAwait() as Failure<Unit, String>).cause
              as Sequential<String>;
      expect(cause.first, isA<Interrupted<String>>());
      expect(cause.second, isA<Defect<String>>());
      expect(clock.pendingSleeps, 0);
      await rt.shutdown();
    },
  );
  test(
    'timeout constructor defects retain cleanup errors and prevent recovery',
    () async {
      final clock = TestClock();
      final rt = Runtime(Unit.value, clock: clock);
      var retries = 0;
      final fiber = rt.fork(
        Effect.sleep<String, Unit>(const Duration(seconds: 20))
            .ensuring(Effect.fail<Unit, String, Unit>('cleanup'))
            .timeout(
              const Duration(seconds: 1),
              () => throw StateError('timeout factory'),
            )
            .retry(
              Schedule(recurrences: 3),
              whileError: (_) {
                retries++;
                return true;
              },
            ),
      );
      await sleepers(clock, 2);
      clock.advance(const Duration(seconds: 1));
      final cause =
          (await fiber.awaitExit() as Failure<Unit, String>).cause
              as Sequential<String>;
      expect(cause.first, isA<Defect<String>>());
      expect((cause.second as Expected<String>).error, 'cleanup');
      expect(retries, 0);
      await rt.shutdown();
    },
  );
  test(
    'traces link children and named regions, metrics track failures',
    () async {
      final events = <LifecycleEvent>[];
      final metrics = RuntimeMetrics();
      final rt = Runtime(Unit.value, lifecycle: events.add, metrics: metrics);
      await rt.runExit(
        Effect.fail<int, String, Unit>('bad')
            .traced('query')
            .fork()
            .flatMap((child) => child.join<Unit>()),
      );
      final starts = events.where((e) => e.phase == 'start').toList();
      expect(starts.length, 2);
      expect(starts[1].parentId, starts[0].fiberId);
      expect(events.where((e) => e.phase == 'span.end').single.name, 'query');
      expect(metrics.failed, 2);
      expect(metrics.active, 0);
      await rt.shutdown();
    },
  );
  test('retry sleep cancellation does not rerun and predicates throwing are defects', () async {
    var calls = 0;
    final clock = TestClock();
    final rt = Runtime(Unit.value, clock: clock);
    final effect = Effect.defer<int, String, Unit>(() {
      calls++;
      return Effect.fail('busy');
    });
    final fiber = rt.fork(
      effect.retry(
        Schedule(recurrences: 3, initialDelay: const Duration(seconds: 3)),
        retryAfter: (_, _) => const Duration(seconds: 5),
      ),
    );
    await sleepers(clock, 1);
    await fiber.interruptAndAwait();
    expect(calls, 1);
    expect(clock.pendingSleeps, 0);
    final exit = await rt.runExit(
      effect.retry(
        Schedule(recurrences: 2),
        whileError: (_) => throw StateError('predicate'),
      ),
    );
    expect((exit as Failure<int, String>).cause, isA<Defect<String>>());
    await rt.shutdown();
  });
}
