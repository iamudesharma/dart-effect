import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:effect_cache/effect_cache.dart';

Future<void> main() async {
  final clock = TestClock();
  final runtime = Runtime(Unit.value, clock: clock);
  var backendCalls = 0;
  // Tenant and authorization identity must be part of keys for private values.
  final cache = EffectCache<(String, int), String, String, Unit>(
    runtime: runtime,
    capacity: 32,
    ttl: const Duration(seconds: 10),
    failureTtl: const Duration(seconds: 1),
    lookup: (key) => Effect.fromFuture(() async {
      backendCalls++;
      await Future<void>.delayed(Duration.zero);
      return '${key.$1}:user-${key.$2}';
    }, onError: (error, stack) => 'Backend unavailable'),
  );
  var acquired = 0, released = 0;
  final scoped = ScopedCache<String, int, String, Unit>(
    runtime: runtime,
    capacity: 4,
    ttl: const Duration(minutes: 1),
    acquire: (_) =>
        Effect.sync<int, String, Unit>(() => ++acquired)
            .acquireScoped((_) => Effect.sync(() => released++)),
  );
  try {
    final responses = await Future.wait(
      List.generate(30, (_) => runtime.runFuture(cache.get(('tenant-a', 7)))),
    );
    if (backendCalls != 1 || responses.any((v) => v != 'tenant-a:user-7')) {
      throw StateError('single-flight failed');
    }
    print('30 reads shared $backendCalls backend call');
    clock.advance(const Duration(seconds: 10));
    await runtime.runFuture(cache.get(('tenant-a', 7)));
    if (backendCalls != 2) throw StateError('expiry failed');
    print('TTL expired: $backendCalls total calls');
    // TTL is lazy unless explicitly maintained. This worker is owned by cache.
    cache.startMaintenance(interval: const Duration(seconds: 1));
    await runtime.runFuture(
      scoped.use('tenant-a', (resource) => Effect.succeed(resource)),
    );
    // Return derived data from use. Never retain a live client outside the borrow.
    await runtime.runFuture(
      scoped.refresh('tenant-a', (resource) => Effect.succeed(resource)),
    );
  } finally {
    final scopedFailure = await scoped.close();
    final valueFailure = await cache.close();
    await runtime.shutdown();
    if (scopedFailure != null) throw EffectException(scopedFailure);
    if (valueFailure != null) throw EffectException(valueFailure);
  }
  if (acquired != released) throw StateError('resource leak');
  print('$acquired scoped generations released exactly once');
}
