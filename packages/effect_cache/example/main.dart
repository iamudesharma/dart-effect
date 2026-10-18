import 'package:effect_core/effect_core.dart';
import 'package:effect_cache/effect_cache.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final cache = EffectCache<String, int, String, Unit>(
    runtime: runtime,
    capacity: 32,
    ttl: Duration(seconds: 10),
    lookup: (key) => Effect.succeed(key.length),
  );
  try {
    print(await runtime.runFuture(cache.get('hello')));
  } finally {
    await cache.close();
    await runtime.shutdown();
  }
}
