import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:effect_batch/effect_batch.dart';
import 'package:test/test.dart';

void main() {
  test('deduplicates by group/key and bounds batch sizes without cross-tenant mixing', () async {
    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    final batches = <(Object, List<int>)>[];
    final resolver = RequestResolver<int, String, String, Unit>(
      runtime: rt,
      maxBatchSize: 2,
      onOverload: (_) => 'overloaded',
      resolve: (group, keys) => Effect.sync(() {
        batches.add((group, keys));
        return {for (final k in keys) k: Success('$group:$k')};
      }),
    );
    addTearDown(resolver.close);
    final futures = [
      for (final group in ['A', 'B'])
        for (final key in [1, 1, 2, 3])
          rt.runFuture(resolver.request(key, group: group)),
    ];
    final values = await Future.wait(futures);
    expect(values, ['A:1', 'A:1', 'A:2', 'A:3', 'B:1', 'B:1', 'B:2', 'B:3']);
    expect(batches.length, 4);
    expect(batches.every((b) => b.$2.length <= 2), true);
    expect(resolver.pendingCount, 0);
  });
  test(
    'individual cancellation leaves shared results available to other waiter',
    () async {
      final clock = TestClock();
      final rt = Runtime(Unit.value, clock: clock);
      addTearDown(rt.shutdown);
      final resolver = RequestResolver<int, int, String, Unit>(
        runtime: rt,
        window: const Duration(seconds: 1),
        onOverload: (_) => 'full',
        resolve: (_, keys) =>
            Effect.succeed({for (final k in keys) k: Success(k)}),
      );
      addTearDown(resolver.close);
      final a = rt.fork(resolver.request(1)), b = rt.fork(resolver.request(1));
      while (clock.pendingSleeps == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await a.interruptAndAwait();
      clock.advance(const Duration(seconds: 1));
      expect((await b.awaitExit() as Success<int, String>).value, 1);
    },
  );
  test('missing resolver keys are defects, overload and per-request failures are typed', () async {
    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    final resolver = RequestResolver<int, int, String, Unit>(
      runtime: rt,
      onOverload: (_) => 'full',
      resolve: (_, keys) => Effect.succeed({1: Failure(Expected('missing'))}),
    );
    addTearDown(resolver.close);
    expect(
      (await rt.runExit(resolver.request(1)) as Failure<int, String>).cause,
      isA<Expected<String>>(),
    );
    expect(
      (await rt.runExit(resolver.request(2)) as Failure<int, String>).cause,
      isA<Defect<String>>(),
    );
  });
}
