import 'package:effect_core/effect_core.dart';

Future<void> main() async {
  final program = Effect.traverse<int, int, String, Unit>(
    [1, 2, 3, 4],
    (value) =>
        Effect.sleep<String, Unit>(const Duration(milliseconds: 5))
            .map((_) => value * 2),
    concurrency: 2,
  );
  print(await Runtime(Unit.value).runFuture(program));
}
