// Original tests derived from pinned Stream.test.ts/Sink.test.ts contracts.
import 'dart:async';
import 'dart:math';

import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

import 'support/checkpoints.dart';

void main() {
  test('[S01] lazy reusable source and maps rerun per consumption', () async {
    var invoked = 0;
    final rt = Runtime(Unit.value);
    final source = EffectStream.fromEffect<int, String, Unit>(
      Effect.sync(() => ++invoked),
    ).map((n) => n * 2);
    expect(invoked, 0);
    expect(await rt.runFuture(source.runCollect()), [2]);
    expect(await rt.runFuture(source.runCollect()), [4]);
  });
  test('[S02] map/filter/take agree with List for seeded inputs', () async {
    final rt = Runtime(Unit.value);
    for (var seed = 0; seed < 30; seed++) {
      final random = Random(seed);
      final values = List.generate(50, (_) => random.nextInt(100));
      final limit = random.nextInt(20);
      final source = EffectStream.fromIterable<int, String, Unit>(values)
          .map((n) => n + 1)
          .filter((n) => n.isEven)
          .take(limit);
      expect(
        await rt.runFuture(source.runCollect()),
        values.map((n) => n + 1).where((n) => n.isEven).take(limit).toList(),
        reason: 'seed=$seed',
      );
    }
  });
  test('[S03] take zero does not acquire upstream resources', () async {
    var acquired = 0;
    final source = EffectStream.acquireRelease<int, int, String, Unit>(
      Effect.sync(() => ++acquired),
      (_) => Effect.succeed(null),
      (n) => EffectStream.fromIterable([n]),
    );
    expect(
      await Runtime(Unit.value).runFuture(source.take(0).runCollect()),
      isEmpty,
    );
    expect(acquired, 0);
  });
  for (final result in [
    'success',
    'failure',
    'defect',
    'interruption',
    'early-exit',
  ]) {
    test(
      '[S04/$result] resource release runs once after every consumption exit',
      () async {
        var releases = 0;
        final started = Completer<void>();
        final rt = Runtime(Unit.value);
        final body = switch (result) {
          'failure' => Effect.fail<int, String, Unit>('body'),
          'defect' => Effect.sync<int, String, Unit>(
            () => throw StateError('body'),
          ),
          'interruption' => Effect.fromFuture<int, String, Unit>(() {
            started.complete();
            return Completer<int>().future;
          }),
          _ => Effect.succeed<int, String, Unit>(1),
        };
        final source = EffectStream.acquireRelease<int, int, String, Unit>(
          Effect.succeed(1),
          (_) => Effect.sync(() {
            releases++;
            return null;
          }),
          (_) => result == 'early-exit'
              ? EffectStream.fromIterable([1, 2, 3])
              : EffectStream.fromEffect(body),
        );
        final fiber = rt.fork(
          source.take(result == 'early-exit' ? 1 : 10).runCollect(),
        );
        if (result == 'interruption') {
          await started.future;
          fiber.interrupt();
        }
        final exit = await fiber.awaitExit();
        expect(releases, 1);
        expect(
          exit,
          result == 'success' || result == 'early-exit'
              ? isA<Success>()
              : isA<Failure>(),
        );
      },
    );
  }
  test('[S05] body and release expected failures are retained once', () async {
    final source = EffectStream.acquireRelease<int, int, String, Unit>(
      Effect.succeed(1),
      (_) => Effect.fail('release'),
      (_) => EffectStream.fromEffect(Effect.fail('body')),
    );
    final exit = await Runtime(Unit.value).runExit(
      source.map((n) => n + 1).filter((_) => true).take(2).runCollect(),
    );
    final cause = (exit as Failure).cause as Sequential;
    expect((cause.first as Expected).error, 'body');
    expect((cause.second as Expected).error, 'release');
  });
  test(
    '[S06] stream factory callback defects still release acquired resource',
    () async {
      var releases = 0;
      final source = EffectStream.acquireRelease<int, int, String, Unit>(
        Effect.succeed(1),
        (_) => Effect.sync(() {
          releases++;
          return null;
        }),
        (_) => throw StateError('factory'),
      );
      expect(
        (await Runtime(
          Unit.value,
        ).runExit(source.runCollect()) as Failure).cause,
        isA<Defect>(),
      );
      expect(releases, 1);
    },
  );
  test('[S07] release is protected and awaited during interruption', () async {
    final releaseStart = Completer<void>(), releaseGate = Completer<void>();
    var aborted = 0;
    final source = EffectStream.acquireRelease<int, int, String, Unit>(
      Effect.succeed(1),
      (_) => Effect.fromFuture(
        () {
          releaseStart.complete();
          return releaseGate.future;
        },
        onCancel: () {
          aborted++;
        },
      ),
      (_) => EffectStream.fromIterable([1]),
    );
    final fiber = Runtime(Unit.value).fork(source.runDrain());
    await releaseStart.future;
    fiber.interrupt();
    var done = false;
    unawaited(
      fiber.awaitExit().then((_) {
        done = true;
      }),
    );
    await eventTurn();
    expect(done, false);
    expect(aborted, 0);
    releaseGate.complete();
    await fiber.awaitExit();
    expect(aborted, 0);
  });
  for (final capacity in [1, 2, 5]) {
    test(
      '[S08/capacity=$capacity] slow consumer bounds read-ahead and early exit awaits producer',
      () async {
        var produced = 0, released = 0;
        final consuming = Completer<void>(), gate = Completer<Unit>();
        final source = EffectStream.acquireRelease<int, int, String, Unit>(
          Effect.succeed(1),
          (_) => Effect.sync(() {
            released++;
            return null;
          }),
          (_) =>
              EffectStream.fromIterable<int, String, Unit>(
                List.generate(100, (n) => n),
              ).map((n) {
                produced++;
                return n;
              }),
        ).buffer(capacity);
        final sink = Sink<int, Unit, String, Unit>.fold(
          () => Unit.value,
          (_, _) => Effect.fromFuture<Unit, String, Unit>(() {
            consuming.complete();
            return gate.future;
          }).map((_) => (Unit.value, false)),
        );
        final fiber = Runtime(Unit.value).fork(source.run(sink));
        await consuming.future;
        await checkpoint(() => produced == capacity + 2);
        for (var i = 0; i < 3; i++) {
          await eventTurn();
        }
        expect(produced, capacity + 2);
        expect(released, 0);
        gate.complete(Unit.value);
        await fiber.awaitExit();
        expect(released, 1);
        expect(produced, capacity + 2);
      },
    );
  }
  test(
    '[S09] buffered source failures arrive after preceding values',
    () async {
      final seen = <int>[];
      final source = EffectStream.fromIterable<int, String, Unit>([1, 2, 3])
          .mapEffect((n) => n == 3 ? Effect.fail('stop') : Effect.succeed(n))
          .buffer(1);
      final exit = await Runtime(Unit.value).runExit(
        source.runForEach(
          (n) => Effect.sync(() {
            seen.add(n);
            return Unit.value;
          }),
        ),
      );
      expect(seen, [1, 2]);
      expect(((exit as Failure).cause as Expected).error, 'stop');
    },
  );
  test(
    '[S10] buffered producer is cancelled while consumer awaits an idle source',
    () async {
      final started = Completer<void>();
      var released = 0;
      final source = EffectStream.fromEffect<int, String, Unit>(
        Effect.fromFuture<int, String, Unit>(() {
          started.complete();
          return Completer<int>().future;
        }).ensuring(
          Effect.sync(() {
            released++;
            return null;
          }),
        ),
      ).buffer(2);
      final fiber = Runtime(Unit.value).fork(source.runCollect());
      await started.future;
      await fiber.interruptAndAwait();
      expect(released, 1);
    },
  );
  test(
    '[S11] native input factory is lazy and subscription cancels on early exit',
    () async {
      var factories = 0, cancelled = 0;
      final source = EffectStream.fromNative<int, String, Unit>(() {
        factories++;
        late StreamController<int> c;
        c = StreamController<int>(
          onListen: () {
            c.add(1);
            c.add(2);
          },
          onCancel: () {
            cancelled++;
          },
        );
        return c.stream;
      });
      expect(factories, 0);
      expect(await Runtime(Unit.value).runFuture(source.take(1).runCollect()), [
        1,
      ]);
      expect(factories, 1);
      expect(cancelled, 1);
    },
  );
  test(
    '[S12] native input errors are defects unless explicitly mapped',
    () async {
      Stream<int> failed() => Stream.error(StateError('native'));
      final rt = Runtime(Unit.value);
      expect(
        (await rt.runExit(
          EffectStream.fromNative<int, String, Unit>(failed).runCollect(),
        ) as Failure).cause,
        isA<Defect>(),
      );
      final exit = await rt.runExit(
        EffectStream.fromNative<int, String, Unit>(
          failed,
          onError: (e, s) => 'mapped',
        ).runCollect(),
      );
      expect(((exit as Failure).cause as Expected).error, 'mapped');
    },
  );
  test('[S13] native output pauses demand and resumes in order', () async {
    final rt = Runtime(Unit.value);
    var produced = 0;
    final received = <int>[], done = Completer<void>();
    final source = EffectStream.fromIterable<int, String, Unit>([1, 2, 3, 4, 5])
        .map((n) {
          produced++;
          return n;
        });
    late StreamSubscription<int> subscription;
    subscription = source.toNative(rt).listen((n) {
      received.add(n);
      if (n == 1) subscription.pause();
    }, onDone: done.complete);
    await checkpoint(() => received.length == 1 && produced == 2);
    for (var i = 0; i < 3; i++) {
      await eventTurn();
    }
    expect(produced, 2);
    expect(received, [1]);
    subscription.resume();
    await done.future;
    expect(received, [1, 2, 3, 4, 5]);
    await rt.shutdown();
  });
  test('[S14] cancelling native output interrupts an in-flight pull and awaits release', () async {
    final native = StreamController<int>();
    var released = 0;
    final source = EffectStream.acquireRelease<int, int, String, Unit>(
      Effect.succeed(1),
      (_) => Effect.sync(() {
        released++;
        return null;
      }),
      (_) => EffectStream.fromNative(() => native.stream),
    );
    final rt = Runtime(Unit.value);
    final sub = source.toNative(rt).listen((_) {});
    await checkpoint(() => native.hasListener);
    await sub.cancel();
    expect(released, 1);
    expect(native.hasListener, false);
    await native.close();
    await rt.shutdown();
  });
  test(
    '[S15] native output exposes typed Cause through EffectException',
    () async {
      final rt = Runtime(Unit.value);
      final source = EffectStream.fromEffect<int, String, Unit>(
        Effect.fail('typed'),
      );
      await expectLater(
        source.toNative(rt),
        emitsInOrder([emitsError(isA<EffectException<String>>()), emitsDone]),
      );
      await rt.shutdown();
    },
  );
  test(
    '[S16] fold and first sinks allocate reusable independent state',
    () async {
      final rt = Runtime(Unit.value);
      final source = EffectStream.fromIterable<int, String, Unit>([1, 2, 3]);
      final sink = Sink<int, int, String, Unit>.fold(
        () => 0,
        (sum, n) => Effect.succeed((sum + n, true)),
      );
      expect(await rt.runFuture(source.run(sink)), 6);
      expect(await rt.runFuture(source.run(sink)), 6);
      expect(await rt.runFuture(source.run(Sink.first())), (1,));
      expect(
        await rt.runFuture(
          EffectStream.fromIterable<int, String, Unit>([]).run(Sink.first()),
        ),
        null,
      );
    },
  );
  test(
    '[S20] nullable sink result can widen through an Object consumer',
    () async {
      final source = EffectStream.fromIterable<int, String, Unit>([6, 8])
          .buffer(2);
      final Sink<int, Object?, String, Unit> sink =
          Sink.first<int, String, Unit>();
      final Object? result = await Runtime(Unit.value)
          .runFuture(source.run(sink));
      expect(result, (6,));
    },
  );
  test('[S17] sink failure stops reads and releases source', () async {
    var read = 0, released = 0;
    final source = EffectStream.acquireRelease<int, int, String, Unit>(
      Effect.succeed(1),
      (_) => Effect.sync(() {
        released++;
        return null;
      }),
      (_) => EffectStream.fromIterable<int, String, Unit>([1, 2, 3]).map((n) {
        read++;
        return n;
      }),
    );
    final exit = await Runtime(Unit.value)
        .runExit(source.runForEach((_) => Effect.fail('sink')));
    expect((exit as Failure).cause, isA<Expected>());
    expect(read, 1);
    expect(released, 1);
  });
  test('[S18] invalid buffer/take parameters reject synchronously', () {
    final source = EffectStream.fromIterable<int, String, Unit>([]);
    expect(() => source.buffer(0), throwsArgumentError);
    expect(() => source.take(-1), throwsArgumentError);
  });
  test(
    '[S19] long filtered source yields to the event queue while running',
    () async {
      var event = false;
      final source =
          EffectStream.fromIterable<int, String, Unit>(
                List.generate(10000, (n) => n),
              )
              .map((n) {
                if (n == 0) {
                  Timer.run(() {
                    event = true;
                  });
                }
                return n;
              })
              .filter((n) => n == 9999);
      expect(await Runtime(Unit.value).runFuture(source.runCollect()), [9999]);
      expect(event, true);
    },
  );
}
