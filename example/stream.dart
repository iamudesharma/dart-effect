import 'package:effect_core/effect_core.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final values = EffectStream.fromIterable<int, String, Unit>([1, 2, 3, 4])
      .map((n) => n * 2)
      .filter((n) => n > 4)
      .buffer(2);
  print(await runtime.runFuture(values.runCollect())); // [6, 8]
  print(await runtime.runFuture(values.run(Sink.first()))); // (6,)
  await runtime.shutdown();
}
