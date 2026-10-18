import 'package:effect_core/effect_core.dart';
import 'package:effect_platform/effect_platform.dart';

int compute() => 6 * 7;

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  try {
    print(
      await runtime.runFuture(
        isolateTask<int, String, Unit>(
          compute,
          onError: (error, stack) => error.toString(),
        ),
      ),
    );
  } finally {
    await runtime.shutdown();
  }
}
