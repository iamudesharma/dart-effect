import 'package:effect_core/effect_core.dart';
import 'package:effect_batch/effect_batch.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final resolver = RequestResolver<int, int, String, Unit>(
    runtime: runtime,
    onOverload: (_) => 'busy',
    resolve: (group, ids) =>
        Effect.succeed({for (final id in ids) id: Success(id * 2)}),
  );
  try {
    print(await runtime.runFuture(resolver.request(3, group: 'tenant-a')));
  } finally {
    await resolver.close();
    await runtime.shutdown();
  }
}
