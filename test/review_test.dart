import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

Future<void> turn() => Future<void>.delayed(Duration.zero);
Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await turn();
  }
  expect(
    ready(),
    isTrue,
    reason: 'Controlled task did not reach expected checkpoint',
  );
}

void main() {
  test('map identity and flatMap identity/associativity', () async {
    final rt = Runtime(Unit.value);
    Effect<int, String, Unit> f(int n) => Effect.succeed(n + 2);
    Effect<int, String, Unit> g(int n) => Effect.succeed(n * 3);
    final m = Effect.succeed<int, String, Unit>(5);
    expect(await rt.runFuture(m.map((n) => n)), await rt.runFuture(m));
    expect(await rt.runFuture(m.flatMap((n) => Effect.succeed(n))), 5);
    expect(
      await rt.runFuture(Effect.succeed<int, String, Unit>(5).flatMap(f)),
      await rt.runFuture(f(5)),
    );
    expect(
      await rt.runFuture(m.flatMap(f).flatMap(g)),
      await rt.runFuture(m.flatMap((n) => f(n).flatMap(g))),
    );
  });
  test(
    'nullable errors survive existential storage and typed mapping',
    () async {
      final exit = await Runtime(Unit.value).runExit(
        Effect.fail<int, String?, Unit>(null).mapError((e) => e ?? 'null'),
      );
      expect(
        ((exit as Failure<int, String>).cause as Expected<String>).error,
        'null',
      );
    },
  );
  test('same-turn completion/cancellation releases once and does not recover interruption', () async {
    final start = Completer<void>(), gate = Completer<int>();
    var releases = 0, recovered = 0;
    final program =
        Effect.acquireUseRelease<int, int, String, Unit>(
          Effect.succeed(1),
          (_) => Effect.fromFuture(() {
            start.complete();
            return gate.future;
          }),
          (_, _) => Effect.sync(() {
            releases++;
            return null;
          }),
        ).catchAll((_) {
          recovered++;
          return Effect.succeed(0);
        });
    final fiber = Runtime(Unit.value).fork(program);
    await start.future;
    gate.complete(2);
    fiber.interrupt();
    expect((await fiber.awaitExit() as Failure).cause, isA<Interrupted>());
    expect(releases, 1);
    expect(recovered, 0);
  });
  test('cancellation hook defects do not replace interruption', () async {
    final started = Completer<void>();
    final fiber = Runtime(Unit.value).fork(
      Effect.fromFuture<int, String, Unit>(() {
        started.complete();
        return Completer<int>().future;
      }, onCancel: () => throw StateError('hook')),
    );
    await started.future;
    final cause =
        (await fiber.interruptAndAwait() as Failure).cause as Sequential;
    expect(cause.first, isA<Interrupted>());
    expect(cause.second, isA<Defect>());
  });
  test('scoped children complete cleanup before resource release', () async {
    final started = Completer<void>(), events = <String>[];
    final child =
        Effect.fromFuture<int, String, Unit>(() {
          started.complete();
          return Completer<int>().future;
        }).ensuring(
          Effect.sync(() {
            events.add('child-cleanup');
            return null;
          }),
        );
    final bracket = Effect.acquireUseRelease<int, int, String, Unit>(
      Effect.succeed(1),
      (_) => child.forkScoped().flatMap(
        (_) => Effect.fromFuture(() async {
          await started.future;
          return 1;
        }),
      ),
      (_, _) => Effect.sync(() {
        events.add('release');
        return null;
      }),
    );
    await Runtime(Unit.value).runFuture(bracket);
    expect(events, ['child-cleanup', 'release']);
  });
  test(
    'shutdown interrupts traversal children and restores all occupied slots',
    () async {
      final rt = Runtime(Unit.value);
      var started = 0, released = 0;
      final fiber = rt.fork(
        Effect.traverse<int, int, String, Unit>(
          [0, 1, 2, 3],
          (n) =>
              Effect.fromFuture<int, String, Unit>(() {
                started++;
                return Completer<int>().future;
              }).ensuring(
                Effect.sync(() {
                  released++;
                  return null;
                }),
              ),
          concurrency: 2,
        ),
      );
      await until(() => started == 2);
      await rt.shutdown();
      expect(await fiber.awaitExit(), isA<Failure>());
      expect(started, 2);
      expect(released, 2);
    },
  );
  test(
    'sleeping retry advances deterministic clock and cancels without rerun',
    () async {
      final clock = TestClock();
      final rt = Runtime(Unit.value, clock: clock);
      var runs = 0;
      final fiber = rt.fork(
        Effect.defer<int, String, Unit>(() {
          runs++;
          return Effect.fail('retry');
        }).retry(
          Schedule(
            recurrences: 3,
            initialDelay: Duration(seconds: 1),
            factor: 2,
          ),
        ),
      );
      await until(() => clock.pendingSleeps == 1);
      expect(runs, 1);
      clock.advance(Duration(seconds: 1));
      await until(() => runs == 2 && clock.pendingSleeps == 1);
      await fiber.interruptAndAwait();
      expect(runs, 2);
      expect(clock.pendingSleeps, 0);
    },
  );
  test('Context rejects variance-widened invalid values before insertion', () {
    final key = ServiceKey<String>('s');
    final ServiceKey<Object> widened = key;
    expect(() => Context().add(widened, 42), throwsArgumentError);
    expect(key.bind('ok').get(key), 'ok');
  });
  test(
    'concurrent cyclic layer roots do not await each others memo forever',
    () async {
      late Layer<String> a;
      late Layer<String> b;
      a = Layer.suspend(() => b, name: 'a');
      b = Layer.suspend(() => a, name: 'b');
      final program = Effect.asyncExit<Unit, String, Context>((ctx) async {
        final exits = await Future.wait([
          ctx.evaluate(a.build()),
          ctx.evaluate(b.build()),
        ]);
        for (final e in exits) {
          expect((e as Failure).cause, isA<Defect>());
        }
        return Success(Unit.value);
      });
      await Runtime(Context()).runFuture(program);
    },
  );
  test(
    'failed concurrent graph waits protected acquisition before cleanup',
    () async {
      final gate = Completer<int>(), start = Completer<void>();
      var releases = 0;
      final resource = Layer.resource<int, String>(
        ServiceKey<int>('resource'),
        Effect.fromFuture(() {
          start.complete();
          return gate.future;
        }),
        (_) => Effect.sync(() {
          releases++;
          return null;
        }),
      );
      final failed = Layer<String>(Effect.fail('failed'));
      final program = Effect.asyncExit<Unit, String, Context>((ctx) async {
        final acquiring = ctx.evaluate(resource.build());
        await start.future;
        final failing = ctx.evaluate(failed.build());
        var done = false;
        unawaited(
          failing.then((_) {
            done = true;
          }),
        );
        await turn();
        expect(done, false);
        gate.complete(1);
        await Future.wait([acquiring, failing]);
        expect(releases, 1);
        return Success(Unit.value);
      });
      await Runtime(Context()).runFuture(program);
      expect(releases, 1);
    },
  );
  test(
    'foreign low-level finalizer error is a defect rather than Future throw',
    () async {
      final exit = await Runtime(Unit.value).runExit(
        Effect.asyncExit<int, String, Unit>((ctx) {
          ctx.scope.addFinalizer(() => Expected(42));
          return Success(1);
        }),
      );
      expect((exit as Failure).cause, isA<Defect>());
    },
  );
  test('closure is marked before finalizers, with same future for concurrent close', () async {
    final scope = Scope();
    final begun = Completer<void>(), gate = Completer<void>();
    var calls = 0;
    scope.addFinalizer(() async {
      calls++;
      begun.complete();
      await gate.future;
      return null;
    });
    final first = scope.close(), second = scope.close();
    expect(identical(first, second), true);
    await begun.future;
    expect(() => scope.addFinalizer(() => null), throwsStateError);
    gate.complete();
    await first;
    expect(calls, 1);
  });
  test(
    'covariant requirement widening is documented and runtime guarded',
    () async {
      final Effect<int, String, Object> widened =
          Effect.environment<int, String, _Database>((_) => 1);
      final exit = await Runtime<Object>(Object()).runExit(widened);
      expect((exit as Failure).cause, isA<Defect>());
    },
  );
  test(
    'async adapter cancellation hook is awaited before fiber completes',
    () async {
      final started = Completer<void>(),
          abort = Completer<void>(),
          gate = Completer<void>();
      final fiber = Runtime(Unit.value).fork(
        Effect.fromFuture<int, String, Unit>(
          () {
            started.complete();
            return Completer<int>().future;
          },
          onCancel: () async {
            abort.complete();
            await gate.future;
          },
        ),
      );
      await started.future;
      fiber.interrupt();
      await abort.future;
      var done = false;
      unawaited(
        fiber.awaitExit().then((_) {
          done = true;
        }),
      );
      await turn();
      expect(done, false);
      gate.complete();
      await fiber.awaitExit();
      expect(done, true);
    },
  );
  test('finalizer-created children cannot escape root lifetime', () async {
    final started = Completer<void>();
    var releases = 0;
    final child =
        Effect.fromFuture<int, String, Unit>(() {
          started.complete();
          return Completer<int>().future;
        }).ensuring(
          Effect.sync(() {
            releases++;
            return null;
          }),
        );
    final program = Effect.asyncExit<int, String, Unit>((ctx) {
      ctx.scope.addFinalizer(() async {
        await ctx.masked().evaluate(child.fork());
        await started.future;
        return null;
      });
      return Success(1);
    });
    await Runtime(Unit.value).runFuture(program);
    expect(releases, 1);
  });
  test(
    'Future factories and deferred constructors are lazy and rerun',
    () async {
      var built = 0, invoked = 0;
      final effect = Effect.defer<int, String, Unit>(() {
        built++;
        return Effect.fromFuture(() async {
          invoked++;
          return invoked;
        });
      });
      expect(built, 0);
      expect(invoked, 0);
      final rt = Runtime(Unit.value);
      expect(await rt.runFuture(effect), 1);
      expect(await rt.runFuture(effect), 2);
      expect(built, 2);
      expect(invoked, 2);
    },
  );
  test(
    'resource local acquisition finalizers close even when acquisition fails',
    () async {
      var cleanup = 0, release = 0;
      final acquire = Effect.asyncExit<int, String, Unit>((ctx) {
        ctx.scope.addFinalizer(() {
          cleanup++;
          return null;
        });
        return Failure(Expected('acquire'));
      });
      final exit = await Runtime(Unit.value).runExit(
        Effect.acquireUseRelease<int, int, String, Unit>(
          acquire,
          (n) => Effect.succeed(n),
          (_, _) => Effect.sync(() {
            release++;
            return null;
          }),
        ),
      );
      expect((exit as Failure).cause, isA<Expected>());
      expect(cleanup, 1);
      expect(release, 0);
    },
  );
  test(
    'release callback defects append to a body defect with both traces',
    () async {
      final exit = await Runtime(Unit.value).runExit(
        Effect.acquireUseRelease<int, int, String, Unit>(
          Effect.succeed(1),
          (_) => Effect.sync(() => throw StateError('body')),
          (_, _) => throw StateError('release'),
        ),
      );
      final cause = (exit as Failure).cause as Sequential;
      expect(cause.first, isA<Defect>());
      expect(cause.second, isA<Defect>());
      expect((cause.first as Defect).stackTrace.toString(), isNotEmpty);
      expect((cause.second as Defect).stackTrace.toString(), isNotEmpty);
    },
  );
  test(
    'timeout clock defects remain defects rather than typed timeouts',
    () async {
      final effect = Effect.fromFuture<int, String, Unit>(
        () => Completer<int>().future,
      ).timeout(Duration(seconds: 1), () => 'timeout');
      final exit = await Runtime(
        Unit.value,
        clock: _BrokenClock(),
      ).runExit(effect);
      expect((exit as Failure).cause, isA<Defect>());
    },
  );
  test('joining child fibers propagates values and typed failures', () async {
    final rt = Runtime(Unit.value);
    expect(
      await rt.runFuture(
        Effect.succeed<int, String, Unit>(7)
            .fork()
            .flatMap((child) => child.join<Unit>()),
      ),
      7,
    );
    final exit = await rt.runExit(
      Effect.fail<int, String, Unit>('child')
          .fork()
          .flatMap((child) => child.join<Unit>()),
    );
    expect(((exit as Failure).cause as Expected).error, 'child');
  });
  test(
    'traversal callback defect interrupts and cleans active sibling',
    () async {
      final started = Completer<void>();
      var released = 0;
      final effect = Effect.traverse<int, int, String, Unit>([0, 1, 2], (n) {
        if (n == 0) {
          return Effect.fromFuture<int, String, Unit>(() {
            started.complete();
            return Completer<int>().future;
          }).ensuring(
            Effect.sync(() {
              released++;
              return null;
            }),
          );
        }
        if (n == 1) {
          return Effect.fromFuture(() async {
            await started.future;
            return 1;
          });
        }
        throw StateError('callback');
      }, concurrency: 2);
      expect(
        (await Runtime(Unit.value).runExit(effect) as Failure).cause,
        isA<Defect>(),
      );
      expect(released, 1);
    },
  );
  test(
    'interrupted Layer acquisition registers and releases exactly once',
    () async {
      final started = Completer<void>(), gate = Completer<int>();
      var released = 0;
      final key = ServiceKey<int>('protected');
      final layer = Layer.resource<int, String>(
        key,
        Effect.fromFuture(() {
          started.complete();
          return gate.future;
        }),
        (_) => Effect.sync(() {
          released++;
          return null;
        }),
      );
      final fiber = Runtime(Context()).fork(layer.use(key.effect<String>()));
      await started.future;
      fiber.interrupt();
      gate.complete(1);
      expect(await fiber.awaitExit(), isA<Failure>());
      expect(released, 1);
    },
  );
}

final class _Database {}

final class _BrokenClock implements Clock {
  @override
  DateTime get now => DateTime.utc(2000);
  @override
  Future<void> sleep(Duration duration, CancellationToken token) =>
      Future.error(StateError('clock'));
}
