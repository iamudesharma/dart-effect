// Development-only measurements; never imported by the published cache library.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:effect_core/effect_core.dart';

// Profile the requested local package without adding a core -> cache dependency.
// ignore: avoid_relative_lib_imports
import '../packages/effect_cache/lib/effect_cache.dart';
import 'performance_memory.dart';

Future<double> sample(bool cached, bool hit) async {
  final runtime = Runtime(Unit.value);
  final cache = EffectCache<int, int, String, Unit>(
    runtime: runtime,
    capacity: 32,
    ttl: const Duration(minutes: 1),
    lookup: (k) => Effect.succeed(k + 1),
  );
  final direct = <int, int>{0: 1};
  const count = 2000;
  await runtime.runFuture(cache.get(0));
  final watch = Stopwatch()..start();
  var sum = 0;
  for (var i = 0; i < count; i++) {
    final key = hit ? 0 : i + 1;
    sum += cached
        ? await runtime.runFuture(cache.get(key))
        : await Future.value(direct.putIfAbsent(key, () => key + 1));
    if (!hit) direct.remove(key);
  }
  watch.stop();
  check(sum > 0, 'result must be consumed');
  await cache.close();
  await runtime.shutdown();
  return watch.elapsedMicroseconds / count;
}

Future<Map<String, Object>> timing() async {
  final result = <String, Object>{};
  for (final hit in [true, false]) {
    for (final effect in [false, true]) {
      await sample(effect, hit);
    }
    final direct = <double>[], cache = <double>[];
    for (var i = 0; i < 7; i++) {
      // Alternate order to reduce consistently favoring the second candidate.
      if (i.isEven) {
        direct.add(await sample(false, hit));
        cache.add(await sample(true, hit));
      } else {
        cache.add(await sample(true, hit));
        direct.add(await sample(false, hit));
      }
    }
    double median(List<double> values) => (List<double>.of(values)..sort())[3];
    result[hit ? 'hit' : 'miss-churn'] = {
      'operationsPerSample': 2000,
      'directFutureUs': direct,
      'effectCacheUs': cache,
      'medianDirectUs': median(direct),
      'medianCacheUs': median(cache),
      'medianOverheadRatio': median(cache) / median(direct),
    };
  }
  return result;
}

Future<List<WeakReference<Object>>> churn() async {
  final rt = Runtime(Unit.value);
  final cache = EffectCache<int, Uint8List, String, Unit>(
    runtime: rt,
    capacity: 32,
    ttl: const Duration(minutes: 1),
    lookup: (_) => Effect.sync(() => Uint8List(65536)),
  );
  final refs = <WeakReference<Object>>[WeakReference(rt), WeakReference(cache)];
  for (var i = 0; i < 1000; i++) {
    final payload = await rt.runFuture(cache.get(i));
    if (i % 100 == 0) refs.add(WeakReference(payload));
    check(cache.size <= 32, 'resident capacity exceeded');
  }
  var acquired = 0, released = 0;
  final scoped = ScopedCache<int, Uint8List, String, Unit>(
    runtime: rt,
    capacity: 8,
    ttl: const Duration(minutes: 1),
    acquire: (_) => Effect.sync<Uint8List, String, Unit>(() {
      acquired++;
      return Uint8List(65536);
    }).acquireScoped((_) => Effect.sync(() => released++)),
  );
  refs.add(WeakReference(scoped));
  for (var i = 0; i < 200; i++) {
    await rt.runFuture(scoped.use(i, (v) => Effect.succeed(v.length)));
  }
  check(await scoped.close() == null, 'scoped cleanup diagnostics');
  check(
    acquired == released && scoped.stats.owners == 0,
    'resources still owned',
  );
  check(
    await cache.close() == null && cache.stats.owners == 0,
    'value owners still live',
  );
  await rt.shutdown();
  return refs;
}

Future<Map<String, Object?>> memory() async {
  final probe = await HeapProbe.connect();
  try {
    await churn();
    await probe.snapshot();
    final snapshots = <Map<String, Object?>>[];
    var collected = 0, total = 0;
    for (var cycle = 0; cycle < 3; cycle++) {
      final refs = await churn();
      final strong = Uint8List(128);
      final control = WeakReference<Object>(strong);
      snapshots.add(await probe.snapshot());
      check(
        control.target != null && strong.length == 128,
        'live control lost',
      );
      final dead = refs.where((r) => r.target == null).length;
      check(
        dead == refs.length,
        'closed cache/runtime/payload retained: ${refs.length - dead}',
      );
      collected += dead;
      total += refs.length;
    }
    return {
      ...memoryResult(snapshots, collected),
      'weakReferencesChecked': total,
      'cycles': 3,
      'valueLoadsPerCycle': 1000,
      'scopedAcquisitionsPerCycle': 200,
      'payloadBytes': 65536,
      'residentCapacity': 32,
    };
  } finally {
    await probe.close();
  }
}

Future<void> main(List<String> args) async {
  final report = <String, Object?>{
    'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'dart': Platform.version,
    'os': Platform.operatingSystem,
    'processors': Platform.numberOfProcessors,
    'mode': args.contains('--memory')
        ? 'JIT VM-service'
        : 'timing (run AOT separately)',
    'scope': 'Local synthetic microbenchmarks; direct Future/map baseline omits typed effects and lifecycle guarantees. No network speed or universal leak-freedom claim.',
  };
  if (args.contains('--memory')) {
    report['memory'] = await memory();
  } else {
    report['timing'] = await timing();
  }
  print(jsonEncode(report));
}
