import 'package:effect_core/effect_core.dart';
import 'package:effect_test/effect_test.dart';
import 'package:test/test.dart';

Future<void> main() async {
  test('typed outcome', () async {
    final runtime = testRuntime(Unit.value);
    expect(
      await runtime.runExit(Effect.fail<int, String, Unit>('expected')),
      expectedFailure<String>(equals('expected')),
    );
  });
}
