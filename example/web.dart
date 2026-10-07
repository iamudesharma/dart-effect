import 'package:effect_core/effect_core.dart';

/// Portable smoke entrypoint; web compile is separate from browser validation.
Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final result = await runtime.runFuture(
    Effect.succeed<int, String, Unit>(20).map((n) => n + 22),
  );
  print(result);
  await runtime.shutdown();
}
