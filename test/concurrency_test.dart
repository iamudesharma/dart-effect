// Original scenarios derived from pinned MIT Effect tests; upstream attribution:
// references/effect/licenses/effect-MIT.txt. See docs/effect-port/testing/.
import 'dart:async';
import 'dart:math';

import 'package:blot_effect/blot_effect.dart';
import 'package:test/test.dart';

import 'support/checkpoints.dart';

void main() {
  group('Ref', () {
    test(
      '[R01] mutations are lazy and modify returns independent output',
      () async {
        final ref = Ref(1);
        final update = ref.update<Unit>((n) => n + 1);
        expect(ref.valueUnsafe, 1);
        final rt = Runtime(Unit.value);
        expect(await rt.runFuture(update), 2);
        expect(await rt.runFuture(update), 3);
        expect(
          await rt.runFuture(
            ref.modify<String, Unit>((n) => ('old:$n', n * 2)),
          ),
          'old:3',
        );
        expect(ref.valueUnsafe, 6);
      },
    );
    test('[R02] callback defects preserve the old value', () async {
      final ref = Ref(5);
      final exit = await Runtime(Unit.value)
          .runExit(ref.update<Unit>((_) => throw StateError('update')));
      expect((exit as Failure).cause, isA<Defect>());
      expect(ref.valueUnsafe, 5);
    });
    test(
      '[R03] seeded operation sequences agree with pure state model',
      () async {
        final rt = Runtime(Unit.value);
        for (var seed = 0; seed < 30; seed++) {
          final random = Random(seed), ref = Ref(0);
          var expected = 0;
          for (var op = 0; op < 50; op++) {
            final delta = random.nextInt(21) - 10;
            expected += delta;
            expect(
              await rt.runFuture(ref.update<Unit>((n) => n + delta)),
              expected,
              reason: 'seed=$seed op=$op',
            );
          }
        }
      },
    );
  });
  group('Deferred', () {
    test('[D01] first completion wins including a nullable value', () async {
      final d = Deferred<int?, String>();
      expect(d.poll(), null);
      expect(d.succeed(null), true);
      expect(d.fail('later'), false);
      expect(await Runtime(Unit.value).runFuture(d.awaitValue<Unit>()), null);
      expect(d.isDone, true);
    });
    test(
      '[D02] typed failures, defects and interruption stay distinct',
      () async {
        final rt = Runtime(Unit.value);
        final expected = Deferred<int, String>()..fail('bad');
        final defect = Deferred<int, String>()
          ..die(StateError('bug'), StackTrace.current);
        final interrupted = Deferred<int, String>()..interrupt();
        expect(
          (await rt.runExit(expected.awaitValue<Unit>()) as Failure).cause,
          isA<Expected>(),
        );
        expect(
          (await rt.runExit(defect.awaitValue<Unit>()) as Failure).cause,
          isA<Defect>(),
        );
        expect(
          (await rt.runExit(interrupted.awaitValue<Unit>()) as Failure).cause,
          isA<Interrupted>(),
        );
      },
    );
    test(
      '[D03] cancelling one waiter leaves other waiters and Deferred alive',
      () async {
        final rt = Runtime(Unit.value), d = Deferred<int, String>();
        final first = rt.fork(d.awaitValue<Unit>()),
            second = rt.fork(d.awaitValue<Unit>());
        await checkpoint(() => d.waitingCount == 2);
        await first.interruptAndAwait();
        expect(d.waitingCount, 1);
        expect(d.isDone, false);
        d.succeed(7);
        expect((await second.awaitExit() as Success).value, 7);
        expect(d.waitingCount, 0);
      },
    );
    test(
      '[D04] complete effect evaluates once and memoizes its failure',
      () async {
        var evaluations = 0;
        final d = Deferred<int, String>();
        final rt = Runtime(Unit.value);
        final effect = Effect.defer<int, String, Unit>(() {
          evaluations++;
          return Effect.fail('memo');
        });
        expect(await rt.runFuture(d.complete(effect)), true);
        expect(await rt.runFuture(d.complete(effect)), false);
        for (var i = 0; i < 2; i++) {
          expect(
            ((await rt.runExit(d.awaitValue<Unit>()) as Failure).cause
                    as Expected)
                .error,
            'memo',
          );
        }
        expect(evaluations, 1);
      },
    );
    test(
      '[D05] concurrent effect completion claims before suspension',
      () async {
        final gate = Completer<int>(), started = Completer<void>();
        var calls = 0;
        final d = Deferred<int, String>(), rt = Runtime(Unit.value);
        final first = rt.fork(
          d.complete(
            Effect.fromFuture<int, String, Unit>(() {
              calls++;
              started.complete();
              return gate.future;
            }),
          ),
        );
        await started.future;
        expect(
          await rt.runFuture(d.complete(Effect.succeed<int, String, Unit>(99))),
          false,
        );
        expect(d.succeed(100), false);
        gate.complete(1);
        await first.awaitExit();
        expect(calls, 1);
        expect(await rt.runFuture(d.awaitValue<Unit>()), 1);
      },
    );
  });
  group('Semaphore', () {
    test(
      '[P01] strict FIFO weighted waits and cancelled head withdrawal',
      () async {
        final sem = Semaphore(3), rt = Runtime(Unit.value);
        final hold = Completer<int>(), started = Completer<void>();
        final owner = rt.fork(
          sem.withPermits(
            2,
            Effect.fromFuture<int, String, Unit>(() {
              started.complete();
              return hold.future;
            }),
          ),
        );
        await started.future;
        final large = rt.fork(
          sem.withPermits(2, Effect.succeed<int, String, Unit>(2)),
        );
        await checkpoint(() => sem.waitingCount == 1);
        final small = rt.fork(
          sem.withPermits(1, Effect.succeed<int, String, Unit>(1)),
        );
        await checkpoint(() => sem.waitingCount == 2);
        expect(sem.available, 1);
        await large.interruptAndAwait();
        expect((await small.awaitExit() as Success).value, 1);
        hold.complete(7);
        await owner.awaitExit();
        expect(sem.available, 3);
        expect(sem.waitingCount, 0);
      },
    );
    for (final outcome in ['success', 'failure', 'defect', 'interruption']) {
      test('[P02/$outcome] permits return on every body exit', () async {
        final sem = Semaphore(2), rt = Runtime(Unit.value);
        final started = Completer<void>();
        final body = switch (outcome) {
          'success' => Effect.succeed<int, String, Unit>(1),
          'failure' => Effect.fail<int, String, Unit>('error'),
          'defect' => Effect.sync<int, String, Unit>(
            () => throw StateError('defect'),
          ),
          _ => Effect.fromFuture<int, String, Unit>(() {
            started.complete();
            return Completer<int>().future;
          }),
        };
        final fiber = rt.fork(sem.withPermits(2, body));
        if (outcome == 'interruption') {
          await started.future;
          fiber.interrupt();
        }
        await fiber.awaitExit();
        expect(sem.available, 2);
        expect(sem.waitingCount, 0);
      });
    }
    test(
      '[P03] cancellation after grant before continuation restores permit',
      () async {
        final sem = Semaphore(1),
            rt = Runtime(Unit.value),
            gate = Completer<int>(),
            start = Completer<void>();
        final owner = rt.fork(
          sem.withPermits(
            1,
            Effect.fromFuture<int, String, Unit>(() {
              start.complete();
              return gate.future;
            }),
          ),
        );
        await start.future;
        final waiter = rt.fork(
          sem.withPermits(1, Effect.succeed<int, String, Unit>(2)),
        );
        await checkpoint(() => sem.waitingCount == 1);
        gate.complete(1);
        waiter.interrupt();
        await owner.awaitExit();
        await waiter.awaitExit();
        expect(sem.available, 1);
      },
    );
    test('[P04] invalid weights fail explicitly rather than park forever', () {
      final sem = Semaphore(2);
      expect(
        () => sem.withPermits(3, Effect.succeed<int, String, Unit>(1)),
        throwsArgumentError,
      );
      expect(
        () => sem.withPermits(0, Effect.succeed<int, String, Unit>(1)),
        throwsArgumentError,
      );
    });
    test(
      '[P05] asynchronous Ref modifications serialize without lost updates',
      () async {
        final ref = SynchronizedRef(0), rt = Runtime(Unit.value);
        final exits = await Future.wait(
          List.generate(
            20,
            (_) => rt.runFuture(
              ref.modifyEffect<int, String, Unit>(
                (n) => Effect.fromFuture(() async {
                  await eventTurn();
                  return (n + 1, n + 1);
                }),
              ),
            ),
          ),
        );
        expect(exits, List.generate(20, (n) => n + 1));
        expect(ref.valueUnsafe, 20);
      },
    );
    test(
      '[P06] failed async modification preserves state and restores lock',
      () async {
        final ref = SynchronizedRef(0), rt = Runtime(Unit.value);
        await rt.runExit(
          ref.modifyEffect<int, String, Unit>((_) => Effect.fail('bad')),
        );
        expect(ref.valueUnsafe, 0);
        expect(
          await rt.runFuture(
            ref.modifyEffect<int, String, Unit>(
              (n) => Effect.succeed((n + 1, n + 1)),
            ),
          ),
          1,
        );
      },
    );
  });
  group('BoundedQueue', () {
    for (final capacity in [0, 1, 2, 5]) {
      test(
        '[Q01/capacity=$capacity] FIFO transfer never loses wake-ups or duplicates',
        () async {
          final q = BoundedQueue<int>(capacity), rt = Runtime(Unit.value);
          final values = List.generate(25, (n) => n);
          final producer = rt.fork(
            Effect.asyncExit<Unit, QueueClosed, Unit>((ctx) async {
              for (final n in values) {
                final exit = await ctx.evaluate(q.offer<Unit>(n));
                if (exit is Failure<bool, QueueClosed>) {
                  return Failure(exit.cause);
                }
                expect(q.size, lessThanOrEqualTo(capacity));
              }
              return Success(Unit.value);
            }),
          );
          final received = <int>[];
          for (var i = 0; i < values.length; i++) {
            received.add(await rt.runFuture(q.take<Unit>()));
          }
          await producer.awaitExit();
          expect(received, values);
          expect(q.size, 0);
          q.shutdown();
        },
      );
    }
    test(
      '[Q02] bounded producer resumes only after capacity is released',
      () async {
        final q = BoundedQueue<int>(1), rt = Runtime(Unit.value);
        q.tryOffer(0);
        final blocked = rt.fork(q.offer<Unit>(1));
        await checkpoint(() => q.waitingProducers == 1);
        expect(q.size, 1);
        expect(await rt.runFuture(q.take<Unit>()), 0);
        expect((await blocked.awaitExit() as Success).value, true);
        expect(await rt.runFuture(q.take<Unit>()), 1);
      },
    );
    test('[Q03] cancelling suspended offer withdraws its message', () async {
      final q = BoundedQueue<int>(1), rt = Runtime(Unit.value);
      q.tryOffer(0);
      final blocked = rt.fork(q.offer<Unit>(1));
      await checkpoint(() => q.waitingProducers == 1);
      await blocked.interruptAndAwait();
      expect(q.waitingProducers, 0);
      expect(q.tryTake(), (0,));
      expect(q.tryTake(), null);
    });
    test(
      '[Q04] cancelling first consumer preserves FIFO for remaining consumers',
      () async {
        final q = BoundedQueue<int>(0), rt = Runtime(Unit.value);
        final first = rt.fork(q.take<Unit>());
        await checkpoint(() => q.waitingConsumers == 1);
        final second = rt.fork(q.take<Unit>());
        await checkpoint(() => q.waitingConsumers == 2);
        await first.interruptAndAwait();
        await rt.runFuture(q.offer<Unit>(7));
        expect((await second.awaitExit() as Success).value, 7);
      },
    );
    test('[Q05] shutdown discards values, wakes all sides, rejects subsequent operations', () async {
      final rt = Runtime(Unit.value),
          full = BoundedQueue<int>(1),
          empty = BoundedQueue<int>(1);
      full.tryOffer(0);
      final producer = rt.fork(full.offer<Unit>(1)),
          consumer = rt.fork(empty.take<Unit>());
      await checkpoint(
        () => full.waitingProducers == 1 && empty.waitingConsumers == 1,
      );
      full.shutdown();
      full.shutdown();
      empty.shutdown();
      for (final exit in [
        await producer.awaitExit(),
        await consumer.awaitExit(),
        await rt.runExit(full.offer<Unit>(2)),
        await rt.runExit(empty.take<Unit>()),
      ]) {
        expect((exit as Failure).cause, isA<Expected<QueueClosed>>());
      }
      expect(full.size, 0);
      expect(full.waitingProducers, 0);
      expect(empty.waitingConsumers, 0);
      await full.whenShutdown;
    });
    test('[Q06] poll distinguishes null value from an empty queue', () {
      final q = BoundedQueue<int?>(1);
      expect(q.tryOffer(null), true);
      expect(q.tryTake(), (null,));
      expect(q.tryTake(), null);
    });
    test('[Q07] producers register atomically even with interpreter yield budget one', () async {
      final rt = Runtime(Unit.value, yieldEvery: 1), q = BoundedQueue<int>(0);
      for (var i = 0; i < 30; i++) {
        final offer = rt.fork(q.offer<Unit>(i)), take = rt.fork(q.take<Unit>());
        expect((await take.awaitExit() as Success).value, i);
        await offer.awaitExit();
      }
      expect(q.waitingConsumers + q.waitingProducers, 0);
    });
  });
  group('PubSub', () {
    test(
      '[H01] both subscribers receive each accepted publication exactly once',
      () async {
        final hub = PubSub<int>(2),
            rt = Runtime(Unit.value),
            a = hub.subscribeUnsafe(),
            b = hub.subscribeUnsafe();
        await rt.runFuture(hub.publish<Unit>(1));
        await rt.runFuture(hub.publish<Unit>(2));
        expect([a.tryTake(), a.tryTake(), a.tryTake()], [(1,), (2,), null]);
        expect([b.tryTake(), b.tryTake()], [(1,), (2,)]);
        hub.shutdown();
      },
    );
    test(
      '[H02] slow subscriber backpressures atomic publication to all',
      () async {
        final hub = PubSub<int>(1),
            rt = Runtime(Unit.value),
            fast = hub.subscribeUnsafe(),
            slow = hub.subscribeUnsafe();
        await rt.runFuture(hub.publish<Unit>(1));
        expect(fast.tryTake(), (1,));
        final blocked = rt.fork(hub.publish<Unit>(2));
        await checkpoint(() => hub.waitingPublishers == 1);
        expect(fast.size, 0);
        expect(slow.tryTake(), (1,));
        await blocked.awaitExit();
        expect(fast.tryTake(), (2,));
        expect(slow.tryTake(), (2,));
        hub.shutdown();
      },
    );
    test('[H03] cancelled publication reaches no subscriber', () async {
      final hub = PubSub<int>(1),
          rt = Runtime(Unit.value),
          a = hub.subscribeUnsafe(),
          b = hub.subscribeUnsafe();
      await rt.runFuture(hub.publish<Unit>(1));
      a.tryTake();
      final blocked = rt.fork(hub.publish<Unit>(2));
      await checkpoint(() => hub.waitingPublishers == 1);
      await blocked.interruptAndAwait();
      b.tryTake();
      expect(a.tryTake(), null);
      expect(b.tryTake(), null);
      expect(hub.waitingPublishers, 0);
      hub.shutdown();
    });
    test(
      '[H04] unsubscribe wakes publishers without losing other subscriber data',
      () async {
        final hub = PubSub<int>(1),
            rt = Runtime(Unit.value),
            a = hub.subscribeUnsafe(),
            b = hub.subscribeUnsafe();
        await rt.runFuture(hub.publish<Unit>(1));
        a.tryTake();
        final blocked = rt.fork(hub.publish<Unit>(2));
        await checkpoint(() => hub.waitingPublishers == 1);
        b.close();
        await blocked.awaitExit();
        expect(a.tryTake(), (2,));
        expect(hub.subscriberCount, 1);
        hub.shutdown();
      },
    );
    test(
      '[H05] scope closes subscriptions and shutdown wakes blocked takes',
      () async {
        final hub = PubSub<int>(1), rt = Runtime(Unit.value);
        await rt.runFuture(
          hub.subscribe<Unit>().map((_) {
            expect(hub.subscriberCount, 1);
            return Unit.value;
          }),
        );
        expect(hub.subscriberCount, 0);
        final sub = hub.subscribeUnsafe(), fiber = rt.fork(sub.take<Unit>());
        await eventTurn();
        hub.shutdown();
        expect(
          (await fiber.awaitExit() as Failure).cause,
          isA<Expected<QueueClosed>>(),
        );
        expect(sub.isClosed, true);
      },
    );
    test(
      '[H07] rejected scope registration does not leak a subscriber',
      () async {
        final hub = PubSub<int>(1), scope = Scope();
        await scope.close();
        final exit = await Runtime(Unit.value).runExit(
          Effect.asyncExit<Subscription<int>, QueueClosed, Unit>(
            (ctx) => ctx.withScope(scope).evaluate(hub.subscribe<Unit>()),
          ),
        );
        expect((exit as Failure).cause, isA<Defect>());
        expect(hub.subscriberCount, 0);
        hub.shutdown();
      },
    );
    test('[H06] new subscribers have no replay and no-subscriber publishing succeeds', () async {
      final hub = PubSub<int>(1), rt = Runtime(Unit.value);
      expect(await rt.runFuture(hub.publish<Unit>(1)), true);
      final sub = hub.subscribeUnsafe();
      expect(sub.tryTake(), null);
      hub.shutdown();
    });
  });
}
