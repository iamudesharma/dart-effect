import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

final class JumpClock implements MonotonicClock {
  DateTime wall = DateTime.utc(2026);
  Duration tick = Duration.zero;
  final sleeps = <Duration>[];
  @override
  DateTime get now => wall;
  @override
  Duration get elapsed => tick;
  @override
  Future<void> sleep(Duration duration, CancellationToken token) async {
    sleeps.add(duration);
    if (duration > Duration.zero) tick += duration;
  }

  void jump() {
    wall = wall.subtract(const Duration(days: 1));
    tick += const Duration(milliseconds: 10);
  }
}

void main() {
  test(
    'bounded stream collection fails with typed error and runs release once',
    () async {
      final rt = Runtime(Unit.value);
      var released = 0;
      final source = EffectStream.acquireRelease<int, int, String, Unit>(
        Effect.succeed(1),
        (_) => Effect.sync(() {
          released++;
          return Unit.value;
        }),
        (_) => EffectStream.fromIterable([1, 2, 3, 4]),
      );
      final exit = await rt.runExit(
        source.runCollect(maxItems: 2, onLimit: () => 'too-large'),
      );
      expect(
        (exit as Failure<List<int>, String>).cause.expectedErrors.single,
        'too-large',
      );
      expect(released, 1);
      expect(
        await rt.runFuture(
          EffectStream.fromIterable<int, String, Unit>([1, 2])
              .runCollect(maxItems: 2),
        ),
        [1, 2],
      );
      expect(
        await rt.runFuture(
          Effect.traverse<int, int, String, Unit>(
            [],
            Effect.succeed,
            concurrency: 1000000,
          ),
        ),
        isEmpty,
      );
      await rt.shutdown();
    },
  );

  test(
    'wall rewind does not change metrics, span, limiter or breaker duration',
    () async {
      final clock = JumpClock(), metrics = RuntimeMetrics();
      final events = <LifecycleEvent>[];
      final rt = Runtime(
        Unit.value,
        clock: clock,
        metrics: metrics,
        lifecycle: events.add,
      );
      addTearDown(rt.shutdown);
      await rt.runExit(
        Effect.sync<int, String, Unit>(() {
          clock.jump();
          return 1;
        }).traced('jump'),
      );
      expect(metrics.totalDuration, const Duration(milliseconds: 10));
      expect(
        events.where((e) => e.phase == 'span.end').single.elapsed,
        const Duration(milliseconds: 10),
      );
      final limiter = RateLimiter(const Duration(milliseconds: 10));
      await rt.runExit(limiter.limit(Effect.succeed<int, String, Unit>(1)));
      clock.jump();
      await rt.runExit(limiter.limit(Effect.succeed<int, String, Unit>(1)));
      expect(clock.sleeps.every((d) => d == Duration.zero), isTrue);
      final breaker = CircuitBreaker(
        failureThreshold: 1,
        resetAfter: const Duration(milliseconds: 10),
      );
      await rt.runExit(
        breaker.protect(
          Effect.fail<int, String, Unit>('bad'),
          onOpen: () => 'open',
        ),
      );
      clock.jump();
      expect(
        await rt.runFuture(
          breaker.protect(
            Effect.succeed<int, String, Unit>(7),
            onOpen: () => 'open',
          ),
        ),
        7,
      );
    },
  );
  test('retry elapsed budget survives wall rewind', () async {
    final clock = JumpClock(), rt = Runtime(Unit.value);
    final timed = Runtime(Unit.value, clock: clock);
    addTearDown(rt.shutdown);
    addTearDown(timed.shutdown);
    var calls = 0;
    await timed.runExit(
      Effect.defer<int, String, Unit>(() {
        calls++;
        clock.jump();
        return Effect.fail('retry');
      }).retry(
        Schedule(
          recurrences: 100,
          elapsedBudget: const Duration(milliseconds: 25),
        ),
      ),
    );
    expect(calls, 3);
  });
  test(
    '50,000-node causes retain ordered typed errors through map and cleanup',
    () async {
      Cause<String> cause = const Expected('first');
      for (var i = 0; i < 50000; i++) {
        cause = Sequential(cause, Expected('$i'));
      }
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      final exit = await rt.runExit(
        Effect.asyncExit<int, String, Unit>((_) => Failure(cause))
            .mapError((e) => 'mapped:$e'),
      );
      final errors = (exit as Failure<int, String>).cause.expectedErrors
          .toList();
      expect(errors.length, 50001);
      expect(errors.first, 'mapped:first');
      expect(errors.last, 'mapped:49999');
      final scoped = Effect.succeed<int, String, Unit>(1)
          .flatMap(
            (_) => Effect.asyncExit<int, String, Unit>((ctx) {
              ctx.scope.addFinalizer(() => cause);
              return const Success(1);
            }),
          )
          .scoped();
      expect(
        (await rt.runExit(
          scoped,
        ) as Failure<int, String>).cause.expectedErrors.length,
        50001,
      );
    },
  );
  test(
    'erased foreign leaves become defects without dropping adjacent errors',
    () {
      final Cause<Object?> cause = Sequential(
        const Expected('ok'),
        Sequential(
          const Expected(42),
          Defect(StateError('oops'), StackTrace.current),
        ),
      );
      final converted = restoreCause<String>(cause);
      expect(converted.expectedErrors, ['ok']);
      expect(converted.defects.length, 2);
    },
  );
  test('traverse pulls only demand and catches iterator defects with sibling cleanup', () async {
    var generated = 0;
    Iterable<int> values() sync* {
      for (var i = 0; i < 10000; i++) {
        generated++;
        yield i;
      }
    }

    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    await rt.runExit(
      Effect.traverse<int, int, String, Unit>(
        values(),
        (_) => Effect.fail('stop'),
      ),
    );
    expect(generated, 1);
    expect(
      await rt.runFuture(
        Effect.traverse<int, int, String, Unit>(
          [3, 2, 1],
          (v) => Effect.succeed(v * 2),
          concurrency: 2,
        ),
      ),
      [6, 4, 2],
    );
    Iterable<int> broken() sync* {
      yield 1;
      throw StateError('iterator');
    }

    final exit = await rt.runExit(
      Effect.traverse<int, int, String, Unit>(
        broken(),
        (_) =>
            Effect.sleep<String, Unit>(const Duration(days: 1)).map((_) => 1),
        concurrency: 2,
      ),
    );
    expect(
      (exit as Failure<List<int>, String>).cause.defects.single.error,
      isA<StateError>(),
    );
  });
  test(
    'pending queue and hub bounds reject overflow and remain usable',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      final q = BoundedQueue<int>(1, maxPending: 0);
      addTearDown(q.shutdown);
      expect(await rt.runFuture(q.offer<Unit>(1)), true);
      final overflow = await rt.runExit(q.offer<Unit>(2));
      expect(
        (overflow as Failure<bool, QueueClosed>).cause.expectedErrors.single,
        isA<QueueFull>(),
      );
      expect(q.waitingProducers, 0);
      expect(await rt.runFuture(q.take<Unit>()), 1);
      final hub = PubSub<int>(1, maxPending: 0, maxSubscribers: 1);
      addTearDown(hub.shutdown);
      final sub = hub.subscribeUnsafe();
      await rt.runFuture(hub.publish<Unit>(1));
      expect(
        (await rt.runExit(
          hub.publish<Unit>(2),
        ) as Failure<bool, QueueClosed>).cause.expectedErrors.single,
        isA<QueueFull>(),
      );
      expect(
        (await rt.runExit(hub.subscribe<Unit>())
                as Failure<Subscription<int>, QueueClosed>)
            .cause
            .expectedErrors
            .single,
        isA<QueueFull>(),
      );
      expect(await rt.runFuture(sub.take<Unit>()), 1);
      expect(hub.waitingPublishers, 0);
    },
  );
  test('semaphore overload is typed and cancellation releases pending reservations', () async {
    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    final sem = Semaphore(1, maxPending: 0),
        started = Completer<void>(),
        gate = Completer<int>();
    final first = rt.fork(
      sem.withPermits(
        1,
        Effect.fromFuture<int, String, Unit>(() {
          started.complete();
          return gate.future;
        }),
      ),
    );
    await started.future;
    final exit = await rt.runExit(
      sem.withPermits(
        1,
        Effect.succeed<int, String, Unit>(2),
        onFull: () => 'full',
      ),
    );
    expect((exit as Failure<int, String>).cause.expectedErrors.single, 'full');
    expect(sem.waitingCount, 0);
    gate.complete(1);
    await first.awaitExit();
    expect(sem.available, 1);
  });
  test('lazy cancellation future remains completed and detached listeners never run', () async {
    final token = CancellationToken();
    var calls = 0;
    final detach = token.onCancel(() => calls++);
    detach();
    token.cancel();
    token.cancel();
    await token.whenCancelled;
    token.onCancel(() => calls++);
    expect(calls, 1);
  });
  test('repeated tiny roots preserve event queue fairness and cancellation before start', () async {
    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    var heartbeat = false, ran = false;
    Timer.run(() => heartbeat = true);
    for (var i = 0; i < 100; i++) {
      await rt.runFuture(Effect.succeed<int, String, Unit>(i));
    }
    expect(heartbeat, true);
    final fiber = rt.fork(
      Effect.sync<int, String, Unit>(() {
        ran = true;
        return 1;
      }),
    );
    fiber.interrupt();
    expect(
      (await fiber.awaitExit() as Failure<int, String>).cause.isInterrupted,
      true,
    );
    expect(ran, false);
  });
}
