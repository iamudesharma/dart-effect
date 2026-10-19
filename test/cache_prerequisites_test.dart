import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

final class LegacyClock implements Clock {
  final TestClock delegate = TestClock();
  @override
  DateTime get now => delegate.now;
  @override
  Future<void> sleep(Duration delay, CancellationToken token) =>
      delegate.sleep(delay, token);
}

void main() {
  test(
    'real clock exposes monotonic capability without constructor changes',
    () {
      const clock = RealClock();
      final before = clock.elapsed;
      expect(elapsedTime(clock) >= before, isTrue);
    },
  );
  test(
    'manual monotonic elapsed advances independently from initial wall date',
    () {
      final clock = TestClock(DateTime.utc(2050));
      expect(clock.elapsed, Duration.zero);
      clock.advance(const Duration(seconds: 2));
      expect(elapsedTime(clock), const Duration(seconds: 2));
      expect(clock.now, DateTime.utc(2050).add(const Duration(seconds: 2)));
    },
  );
  test('legacy clock uses documented wall-time fallback', () {
    final clock = LegacyClock();
    expect(
      elapsedTime(clock),
      Duration(microseconds: clock.now.microsecondsSinceEpoch),
    );
  });
  test(
    'Cause inspection stays iterative and ordered across deep cleanup causes',
    () {
      Cause<String> cause = const Interrupted();
      for (var i = 0; i < 10000; i++) {
        cause = Sequential(cause, Expected('$i'));
      }
      expect(cause.isInterrupted, isTrue);
      expect(cause.expectedErrors.length, 10000);
      expect(cause.expectedErrors.first, '0');
      expect(cause.defects, isEmpty);
    },
  );
  test(
    'scoped acquisition masks until release is registered during cancellation',
    () async {
      final runtime = Runtime(Unit.value);
      final started = Completer<void>(), gate = Completer<int>();
      var released = 0;
      final fiber = runtime.fork(
        Effect.fromFuture<int, String, Unit>(() {
          started.complete();
          return gate.future;
        }).acquireScoped((_) => Effect.sync(() => released++)),
      );
      await started.future;
      fiber.interrupt();
      gate.complete(1);
      expect(
        (await fiber.awaitExit() as Failure<int, String>).cause.isInterrupted,
        isTrue,
      );
      expect(released, 1);
      await runtime.shutdown();
    },
  );
  test('failed scoped acquisition never registers a release', () async {
    final runtime = Runtime(Unit.value);
    var released = 0;
    final result = await runtime.runExit(
      Effect.fail<int, String, Unit>('acquire')
          .acquireScoped((_) => Effect.sync(() => released++)),
    );
    expect((result as Failure<int, String>).cause.expectedErrors, ['acquire']);
    expect(released, 0);
    await runtime.shutdown();
  });
  test('scoped release preserves expected errors and defects', () async {
    final runtime = Runtime(Unit.value);
    final result = await runtime.runExit(
      Effect.succeed<int, String, Unit>(1)
          .acquireScoped((_) => Effect.fail('release')),
    );
    expect((result as Failure<int, String>).cause.expectedErrors, ['release']);
    await runtime.shutdown();
  });
}
