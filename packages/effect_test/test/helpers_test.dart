import 'package:effect_core/effect_core.dart';
import 'package:effect_test/effect_test.dart';
import 'package:test/test.dart';

void main() {
  test('runtime teardown, cause matcher and suspended clock helper', () async {
    final clock = TestClock(), logs = CapturedLogs();
    final rt = testRuntime(Unit.value, clock: clock, logger: logs.call);
    final sleeping = rt.runFuture(
      Effect.sleep<String, Unit>(const Duration(seconds: 1)),
    );
    await advanceWhenSleeping(clock, const Duration(seconds: 1));
    await sleeping;
    expect(clock.pendingSleeps, 0);
    expect(
      await rt.runExit(Effect.fail<int, String, Unit>('typed')),
      expectedFailure<String>(equals('typed')),
    );
    await rt.runFuture(log<String, Unit>('hello'));
    expect(logs.records.single.message, 'hello');
  });
}
