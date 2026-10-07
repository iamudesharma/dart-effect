import 'dart:async';

import 'package:blot_effect/blot_effect.dart';
import 'package:test/test.dart';

Future<void> turn() => Future<void>.delayed(Duration.zero);
void main() {
  test('lazy constructors rerun and compose', () async {
    var calls = 0;
    final effect = Effect.sync<int, String, Unit>(() => ++calls)
        .map((n) => n + 1)
        .flatMap((n) => Effect.succeed(n * 2));
    expect(calls, 0);
    final rt = Runtime(Unit.value);
    expect(await rt.runFuture(effect), 4);
    expect(await rt.runFuture(effect), 6);
  });
  test('deep bind chain is stack safe and yields to event queue', () async {
    var event = false;
    var effect = Effect.sync<int, String, Unit>(() {
      Timer.run(() {
        event = true;
      });
      return 0;
    });
    for (var i = 0; i < 100000; i++) {
      effect = effect.flatMap((n) => Effect.succeed(n + 1));
    }
    expect(await Runtime(Unit.value).runFuture(effect), 100000);
    expect(event, isTrue);
  });
  test('expected recovery excludes defects and interruption', () async {
    final rt = Runtime(Unit.value);
    expect(
      await rt.runFuture(
        Effect.fail<int, String, Unit>('x').catchAll((_) => Effect.succeed(7)),
      ),
      7,
    );
    final defect = await rt.runExit(
      Effect.sync<int, String, Unit>(() => throw StateError('bug'))
          .catchAll((_) => Effect.succeed(7)),
    );
    expect((defect as Failure).cause, isA<Defect>());
    final fiber = rt.fork(
      Effect.succeed<int, String, Unit>(1).catchAll((_) => Effect.succeed(7)),
    );
    fiber.interrupt();
    expect((await fiber.awaitExit() as Failure).cause, isA<Interrupted>());
  });
  test(
    'future cancellation hook fires once and late value is ignored',
    () async {
      final result = Completer<int>(), started = Completer<void>();
      var cancelled = 0;
      final fiber = Runtime(Unit.value).fork(
        Effect.fromFuture<int, String, Unit>(() {
          started.complete();
          return result.future;
        }, onCancel: () => cancelled++),
      );
      await started.future;
      fiber.interrupt();
      fiber.interrupt();
      expect((await fiber.awaitExit() as Failure).cause, isA<Interrupted>());
      result.complete(9);
      await turn();
      expect(cancelled, 1);
    },
  );
  test('finalizers are masked, awaited and failures append', () async {
    final started = Completer<void>(), finish = Completer<void>();
    var released = 0;
    final fiber = Runtime(Unit.value).fork(
      Effect.fail<int, String, Unit>('body').ensuring(
        Effect.fromFuture<Object?, String, Unit>(() {
          released++;
          started.complete();
          return finish.future;
        }),
      ),
    );
    await started.future;
    fiber.interrupt();
    var completed = false;
    unawaited(
      fiber.awaitExit().then((_) {
        completed = true;
      }),
    );
    await turn();
    expect(completed, isFalse);
    finish.complete();
    expect((await fiber.awaitExit() as Failure).cause, isA<Expected>());
    expect(released, 1);
    final failed = await Runtime(Unit.value).runExit(
      Effect.fail<int, String, Unit>('body')
          .ensuring(Effect.fail<Object?, String, Unit>('cleanup')),
    );
    final cause = (failed as Failure<int, String>).cause as Sequential<String>;
    expect((cause.first as Expected).error, 'body');
    expect((cause.second as Expected).error, 'cleanup');
  });
  test(
    'acquisition is protected until release runs after cancellation',
    () async {
      final start = Completer<void>(), acquired = Completer<int>();
      var releases = 0, uses = 0;
      final effect = Effect.acquireUseRelease<int, int, String, Unit>(
        Effect.fromFuture(() {
          start.complete();
          return acquired.future;
        }),
        (a) => Effect.sync(() {
          uses++;
          return a;
        }),
        (a, exit) => Effect.sync(() {
          releases++;
          return null;
        }),
      );
      final fiber = Runtime(Unit.value).fork(effect);
      await start.future;
      fiber.interrupt();
      acquired.complete(4);
      expect((await fiber.awaitExit() as Failure).cause, isA<Interrupted>());
      expect(uses, 0);
      expect(releases, 1);
    },
  );
  test('release occurs even if use callback throws', () async {
    var releases = 0;
    final exit = await Runtime(Unit.value).runExit(
      Effect.acquireUseRelease<int, int, String, Unit>(
        Effect.succeed(1),
        (a) => throw StateError('use'),
        (a, e) => Effect.sync(() {
          releases++;
          return null;
        }),
      ),
    );
    expect((exit as Failure).cause, isA<Defect>());
    expect(releases, 1);
  });
  test('scope closes once with LIFO finalizers retaining defects', () async {
    final scope = Scope(), events = <int>[];
    scope.addFinalizer(() {
      events.add(1);
      return null;
    });
    scope.addFinalizer(() {
      events.add(2);
      throw StateError('release');
    });
    expect(await scope.close(), isA<Defect>());
    await scope.close();
    expect(events, [2, 1]);
    expect(() => scope.addFinalizer(() => null), throwsStateError);
  });
  test(
    'race waits loser cleanup and waits success after initial failure',
    () async {
      final loserStarted = Completer<void>(), winner = Completer<int>();
      var cleanup = 0;
      final loser =
          Effect.fromFuture<int, String, Unit>(() {
            loserStarted.complete();
            return Completer<int>().future;
          }).ensuring(
            Effect.sync(() {
              cleanup++;
              return null;
            }),
          );
      final fiber = Runtime(Unit.value)
          .fork(loser.race(Effect.fromFuture(() => winner.future)));
      await loserStarted.future;
      winner.complete(7);
      expect((await fiber.awaitExit() as Success).value, 7);
      expect(cleanup, 1);
      expect(
        await Runtime(Unit.value).runFuture(
          Effect.fail<int, String, Unit>('first').race(Effect.succeed(8)),
        ),
        8,
      );
    },
  );
  test('parent completion and shutdown await child cleanup', () async {
    final childStarted = Completer<void>();
    var released = 0;
    final child =
        Effect.fromFuture<int, String, Unit>(() {
          childStarted.complete();
          return Completer<int>().future;
        }).ensuring(
          Effect.sync(() {
            released++;
            return null;
          }),
        );
    final parent = child.fork().flatMap(
      (_) => Effect.fromFuture<Unit, String, Unit>(() async {
        await childStarted.future;
        return Unit.value;
      }),
    );
    await Runtime(Unit.value).runFuture(parent);
    expect(released, 1);
    final rt = Runtime(Unit.value);
    final began = Completer<void>();
    final root = rt.fork(
      Effect.fromFuture<int, String, Unit>(() {
        began.complete();
        return Completer<int>().future;
      }).ensuring(
        Effect.sync(() {
          released++;
          return null;
        }),
      ),
    );
    await began.future;
    await rt.shutdown();
    expect((await root.awaitExit() as Failure).cause, isA<Interrupted>());
    expect(released, 2);
    expect(
      () => rt.fork(Effect.succeed<int, String, Unit>(1)),
      throwsStateError,
    );
  });
  test(
    'bounded traversal preserves order and cancels failing siblings',
    () async {
      var active = 0, max = 0;
      final effect = Effect.traverse<int, int, String, Unit>(
        List.generate(12, (i) => i),
        (n) => Effect.fromFuture(() async {
          active++;
          if (active > max) max = active;
          await turn();
          active--;
          return n * 2;
        }),
        concurrency: 3,
      );
      expect(
        await Runtime(Unit.value).runFuture(effect),
        List.generate(12, (i) => i * 2),
      );
      expect(max, 3);
      expect(active, 0);
      final started = Completer<void>();
      var released = 0;
      final failed = Effect.traverse<int, int, String, Unit>(
        [0, 1],
        (n) => n == 0
            ? Effect.fromFuture<int, String, Unit>(() {
                started.complete();
                return Completer<int>().future;
              }).ensuring(
                Effect.sync(() {
                  released++;
                  return null;
                }),
              )
            : Effect.fromFuture<int, String, Unit>(() async {
                await started.future;
                throw 'failure';
              }, onError: (e, s) => '$e'),
        concurrency: 2,
      );
      expect(
        (await Runtime(Unit.value).runExit(failed) as Failure).cause,
        isA<Expected>(),
      );
      expect(released, 1);
    },
  );
  test('test clock timeout interrupts worker and removes sleepers', () async {
    final clock = TestClock(), rt = Runtime(Unit.value, clock: TestClock());
    final timerRuntime = Runtime(Unit.value, clock: clock);
    final fiber = timerRuntime.fork(
      Effect.sleep<String, Unit>(const Duration(seconds: 10))
          .timeout(const Duration(seconds: 2), () => 'timeout'),
    );
    while (clock.pendingSleeps < 2) {
      await turn();
    }
    clock.advance(const Duration(seconds: 2));
    expect(
      ((await fiber.awaitExit() as Failure).cause as Expected).error,
      'timeout',
    );
    expect(clock.pendingSleeps, 0);
    await rt.shutdown();
  });
  test('interrupting race cancels both branches', () async {
    final starts = [Completer<void>(), Completer<void>()];
    var cleanups = 0;
    Effect<int, String, Unit> branch(int i) =>
        Effect.fromFuture<int, String, Unit>(() {
          starts[i].complete();
          return Completer<int>().future;
        }).ensuring(
          Effect.sync(() {
            cleanups++;
            return null;
          }),
        );
    final fiber = Runtime(Unit.value).fork(branch(0).race(branch(1)));
    await Future.wait(starts.map((s) => s.future));
    fiber.interrupt();
    expect((await fiber.awaitExit() as Failure).cause, isA<Sequential>());
    expect(cleanups, 2);
  });
}
