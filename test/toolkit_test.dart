import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

final class JumpClock implements MonotonicClock {
  final delegate = TestClock();
  DateTime wall = DateTime.utc(2026);
  @override
  DateTime get now => wall;
  @override
  Duration get elapsed => delegate.elapsed;
  @override
  Future<void> sleep(Duration d, CancellationToken token) =>
      delegate.sleep(d, token);
}

Future<void> turn() => Future<void>.delayed(Duration.zero);
void main() {
  test(
    'managed graph shared across calls, work cleaned before service release',
    () async {
      final events = <String>[];
      final key = ServiceKey<int>('counter');
      final layer = Layer.resource<int, String>(
        key,
        Effect.sync(() => 1),
        (_) => Effect.sync(() => events.add('service')),
      );
      final created = await ManagedRuntime.fromLayer(layer);
      final runtime =
          (created as Success<ManagedRuntime<String>, String>).value;
      expect(await runtime.runFuture(key.effect<String>()), 1);
      expect(await runtime.runFuture(key.effect<String>()), 1);
      final started = Completer<void>();
      final work = runtime.runExit(
        Effect.fromFuture<int, String, Context>(() {
          started.complete();
          return Completer<int>().future;
        }).ensuring(
          Effect.sync<Unit, String, Context>(() {
            events.add('request');
            return Unit.value;
          }),
        ),
      );
      await started.future;
      expect(await runtime.close(), isA<Success<Unit, String>>());
      await work;
      expect(events, ['request', 'service']);
      expect(identical(runtime.close(), runtime.close()), true);
      expect(
        () => runtime.runExit(Effect.succeed<int, String, Context>(2)),
        throwsStateError,
      );
    },
  );
  test('managed startup and service cleanup failures are retained', () async {
    final key = ServiceKey<int>('bad');
    final created = await ManagedRuntime.fromLayer(
      Layer.resource<int, String>(
        key,
        Effect.succeed(1),
        (_) => Effect.fail('release'),
      ),
    );
    final runtime = (created as Success<ManagedRuntime<String>, String>).value;
    expect(
      ((await runtime.close() as Failure<Unit, String>).cause
              as Expected<String>)
          .error,
      'release',
    );
    final failed = await ManagedRuntime.fromLayer(
      Layer<String>(Effect.fail('startup')),
    );
    expect(failed, isA<Failure<ManagedRuntime<String>, String>>());
  });
  test(
    'composition is lazy, typed recovery does not catch defects/composites',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      var calls = 0;
      final effect = Effect.sync<int, String, Unit>(() => ++calls)
          .tap((_) => Effect.succeed(Unit.value));
      expect(calls, 0);
      expect(await rt.runFuture(effect.zip(Effect.succeed('ok'))), (1, 'ok'));
      final failed = Effect.fail<int, String, Unit>('bad')
          .ensuring(Effect.fail<Unit, String, Unit>('cleanup'))
          .catchIf((_) => true, (_) => Effect.succeed(1));
      final cause = (await rt.runExit(failed) as Failure<int, String>).cause;
      expect(cause.expectedErrors, ['bad', 'cleanup']);
      expect(cause.pretty(), contains('cleanup'));
      expect(await rt.runFuture(effect.when(() => false)), null);
      expect(calls, 1);
    },
  );
  test(
    'throwing onExit hooks append defects instead of replacing body cause',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      final result = await rt.runExit(
        Effect.fail<int, String, Unit>('body')
            .onExit((_) => throw StateError('observer')),
      );
      final cause =
          (result as Failure<int, String>).cause as Sequential<String>;
      expect((cause.first as Expected<String>).error, 'body');
      expect(cause.second, isA<Defect<String>>());
    },
  );
  test('raceFirst returns initial failure and awaits loser cleanup', () async {
    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    var cleaned = false;
    final ready = Completer<void>();
    final exit = await rt.runExit(
      Effect.fromFuture<int, String, Unit>(() async {
        await ready.future;
        throw 'first';
      }, onError: (e, _) => e.toString()).raceFirst(
        Effect.fromFuture<int, String, Unit>(() {
          ready.complete();
          return Completer<int>().future;
        }).ensuring(
          Effect.sync<Unit, String, Unit>(() {
            cleaned = true;
            return Unit.value;
          }),
        ),
      ),
    );
    expect(exit, isA<Failure<int, String>>());
    expect(cleaned, true);
  });
  test('stream concatenation, flatMap, groups, scans and unfolding remain lazy/reusable', () async {
    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    final stream =
        EffectStream.unfold<int, int, String, Unit>(
              () => 0,
              (n) => Effect.succeed(n == 5 ? null : (n, n + 1)),
            )
            .flatMap(
              (n) => EffectStream.fromIterable<int, String, Unit>([n, n]),
            )
            .grouped(3);
    for (var i = 0; i < 2; i++) {
      expect(await rt.runFuture(stream.runCollect()), [
        [0, 0, 1],
        [1, 2, 2],
        [3, 3, 4],
        [4],
      ]);
    }
  });
  test(
    'concurrent stream mapping bounds work and preserves source order',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      var active = 0, peak = 0;
      final stream =
          EffectStream.fromIterable<int, String, Unit>(
            List.generate(17, (i) => i),
          ).mapEffectConcurrent(
            (n) => Effect.fromFuture<int, String, Unit>(() async {
              active++;
              if (active > peak) peak = active;
              await turn();
              active--;
              return n * 2;
            }),
            concurrency: 3,
          );
      expect(
        await rt.runFuture(stream.runCollect()),
        List.generate(17, (i) => i * 2),
      );
      expect(peak, 3);
      expect(active, 0);
    },
  );
  test('queue graceful completion drains values, rejects producers and returns end', () async {
    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    final q = BoundedQueue<int>(2);
    q.tryOffer(1);
    q.tryOffer(2);
    q.complete();
    expect(q.tryOffer(3), false);
    expect(await rt.runFuture(q.takeOption<Unit>()), (1,));
    expect(await rt.runFuture(q.takeOption<Unit>()), (2,));
    expect(await rt.runFuture(q.takeOption<Unit>()), null);
    q.shutdown();
    expect(
      await rt.runExit(q.takeOption<Unit>()),
      isA<Failure<(int,)?, QueueClosed>>(),
    );
  });
  test(
    'wall-clock jumps do not alter built-in monotonic retry budgets',
    () async {
      final clock = JumpClock(), rt = Runtime(Unit.value);
      final timed = Runtime(Unit.value, clock: clock);
      addTearDown(rt.shutdown);
      addTearDown(timed.shutdown);
      var calls = 0;
      final work = Effect.defer<int, String, Unit>(() {
        calls++;
        clock.wall = clock.wall.add(const Duration(days: 5));
        clock.delegate.advance(const Duration(seconds: 1));
        return Effect.fail('retry');
      });
      await timed.runExit(
        work.retry(
          Schedule(recurrences: 9, elapsedBudget: const Duration(seconds: 2)),
        ),
      );
      expect(calls, 2);
    },
  );
  test(
    'PubSub replay is bounded and overflow policy remains explicit',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      final sliding = PubSub<int>(
        2,
        replay: 1,
        overflow: OverflowStrategy.sliding,
      );
      await rt.runFuture(sliding.publish<Unit>(1));
      final sub = sliding.subscribeUnsafe();
      await rt.runFuture(sliding.publish<Unit>(2));
      await rt.runFuture(sliding.publish<Unit>(3));
      expect(sub.tryTake(), (2,));
      expect(sub.tryTake(), (3,));
      sub.close();
      sliding.shutdown();
      final dropping = PubSub<int>(1, overflow: OverflowStrategy.dropping);
      final slow = dropping.subscribeUnsafe();
      expect(await rt.runFuture(dropping.publish<Unit>(1)), true);
      expect(await rt.runFuture(dropping.publish<Unit>(2)), false);
      expect(slow.tryTake(), (1,));
      dropping.shutdown();
    },
  );
  test(
    'unbounded repeat supports input continuation and fair cancellation',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      var calls = 0;
      final value = await rt.runFuture(
        Effect.sync<int, String, Unit>(() => ++calls)
            .repeat(Schedule.forever(), whileValue: (n) => n < 5),
      );
      expect(value, 5);
      final exit = await rt.runExit(
        Effect.fail<int, String, Unit>('retry')
            .retry(Schedule.forever())
            .timeout(const Duration(milliseconds: 1), () => 'timeout'),
      );
      expect(exit, isA<Failure<int, String>>());
    },
  );
}
