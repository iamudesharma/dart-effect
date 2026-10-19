// Development audit of the merged runtime; no production behavior is changed.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:effect_core/effect_core.dart';

// Audit the local optional package without adding it as a core dependency.
// ignore: avoid_relative_lib_imports
import '../packages/effect_cache/lib/effect_cache.dart';
import 'performance_memory.dart';

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 1000; i++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Audit condition did not settle');
}

final class Payload {
  Payload(int bytes) : data = Uint8List(bytes);
  final Uint8List data;
}

Future<Map<String, Object?>> heap(HeapProbe probe) async {
  await Future<void>.delayed(const Duration(milliseconds: 30));
  final profile = await probe.rpc('getAllocationProfile', {
    'isolateId': developer.Service.getIsolateId(Isolate.current),
    'gc': true,
  });
  final classes = <String, Object?>{};
  for (final row in profile['members'] as List) {
    final c = row['class'] as Map;
    final name = c['name'] as String;
    if ([
      'Payload',
      'Fiber',
      'Scope',
      'CancellationToken',
      '_Entry',
      '_ResourceEntry',
    ].contains(name)) {
      classes['$name:${c['id']}'] = {
        'instances': row['instancesCurrent'],
        'bytes': row['bytesCurrent'],
      };
    }
  }
  return {
    'gcTimestamp': profile['dateLastServiceGC'],
    'heap': profile['memoryUsage'],
    'classes': classes,
  };
}

Effect<int, String, Unit> chain(int n) {
  var effect = Effect.succeed<int, String, Unit>(0);
  for (var i = 0; i < n; i++) {
    effect = effect.map((v) => v + 1);
  }
  return effect;
}

Future<Map<String, Object?>> scheduling() async {
  final rt = Runtime(Unit.value);
  final cache = EffectCache<int, int, String, Unit>(
    runtime: rt,
    capacity: 8,
    ttl: const Duration(minutes: 1),
    lookup: Effect.succeed,
  );
  await rt.runFuture(cache.get(1));
  final counts = <String, Object?>{};
  Future<void> count(
    String name,
    int n,
    Future<void> Function(int) operation,
  ) async {
    var timers = 0, microtasks = 0, positiveTimers = 0;
    await runZoned(
      () async {
        for (var i = 0; i < n; i++) {
          await operation(i);
        }
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          timers++;
          if (duration > Duration.zero) positiveTimers++;
          return parent.createTimer(zone, duration, callback);
        },
        scheduleMicrotask: (self, parent, zone, callback) {
          microtasks++;
          parent.scheduleMicrotask(zone, callback);
        },
      ),
    );
    counts[name] = {
      'operations': n,
      'timers': timers,
      'positiveDurationTimers': positiveTimers,
      'microtaskSchedules': microtasks,
    };
  }

  await count('future-value', 50, (_) async {
    await Future.value(1);
  });
  await count('root-success', 50, (_) async {
    await rt.runFuture(Effect.succeed<int, String, Unit>(1));
  });
  await count('root-fromFuture', 50, (_) async {
    await rt.runFuture(
      Effect.fromFuture<int, String, Unit>(() => Future.value(1)),
    );
  });
  await count('cache-hit', 50, (_) async {
    await rt.runFuture(cache.get(1));
  });
  await count('cache-miss', 50, (i) async {
    await rt.runFuture(cache.get(i + 100));
  });
  final mapped = chain(1000);
  await count('map-1000', 10, (_) async {
    await rt.runFuture(mapped);
  });
  await cache.close();
  await rt.shutdown();
  final fairness = <String, Object?>{};
  for (final useMicrotasks in [true, false]) {
    var heartbeat = false, observedDuring = false;
    final beat = Completer<void>();
    Timer.run(() {
      heartbeat = true;
      beat.complete();
    });
    for (var i = 0; i < 10000; i++) {
      if (useMicrotasks) {
        await Future<int>.microtask(() => 1);
      } else {
        await Future<int>(() => 1);
      }
      observedDuring |= heartbeat;
    }
    await beat.future;
    fairness[useMicrotasks ? 'microtask-only-loop' : 'event-queue-loop'] = {
      'iterations': 10000,
      'timerHeartbeatRanDuringWork': observedDuring,
    };
  }
  return {
    'zoneCounts': counts,
    'primitiveFairnessControl': fairness,
    'note': 'Zone interception adds overhead. Counts are diagnostic; timings run separately. Fairness control compares Dart primitives, not an optimized runtime.',
  };
}

Future<Map<String, Object?>> timing() async {
  final rt = Runtime(Unit.value);
  final cache = EffectCache<int, int, String, Unit>(
    runtime: rt,
    capacity: 32,
    ttl: const Duration(minutes: 1),
    lookup: Effect.succeed,
  );
  await rt.runFuture(cache.get(1));
  final effect = Effect.succeed<int, String, Unit>(1);
  final results = <String, Object?>{};
  final ops = <String, Future<int> Function()>{
    'direct-Future.value': () => Future.value(1),
    'root-success': () => rt.runFuture(effect),
    'cache-hit': () => rt.runFuture(cache.get(1)),
  };
  for (final entry in ops.entries) {
    for (var i = 0; i < 500; i++) {
      await entry.value();
    }
    final samples = <int>[];
    for (var i = 0; i < 2000; i++) {
      final watch = Stopwatch()..start();
      final value = await entry.value();
      watch.stop();
      if (value != 1) throw StateError('Wrong value');
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    results[entry.key] = {
      'samples': samples.length,
      'p50us': samples[1000],
      'p95us': samples[1900],
      'p99us': samples[1980],
      'meanUs': samples.reduce((a, b) => a + b) / samples.length,
    };
  }
  await cache.close();
  await rt.shutdown();
  return results;
}

Future<List<Object?>> causes() async {
  final rows = <Object?>[];
  for (final depth in [100, 1000, 5000, 10000, 50000]) {
    Cause<String> cause = const Expected('body');
    for (var i = 0; i < depth; i++) {
      cause = Sequential(cause, const Expected('cleanup'));
    }
    final rt = Runtime(Unit.value);
    final result = await rt.runExit(
      Effect.asyncExit<int, String, Unit>((_) => Failure(cause)),
    );
    final failure = (result as Failure<int, String>).cause;
    rows.add({
      'depth': depth,
      'expectedErrorsRetained': failure.expectedErrors.length,
      'defectTypes': failure.defects
          .map((d) => d.error.runtimeType.toString())
          .toList(),
    });
    await rt.shutdown();
  }
  return rows;
}

Future<List<WeakReference<Payload>>> seedExpired(
  EffectCache<int, Payload, String, Unit> cache,
  Runtime<Unit> rt,
) async {
  final refs = <WeakReference<Payload>>[];
  for (var i = 0; i < 8; i++) {
    refs.add(WeakReference(await rt.runFuture(cache.get(i))));
  }
  return refs;
}

Future<Map<String, Object?>> expiredValues(HeapProbe probe) async {
  final clock = TestClock(), rt = Runtime(Unit.value);
  // The cache's own runtime supplies its clock.
  final owner = Runtime(Unit.value, clock: clock);
  final cache = EffectCache<int, Payload, String, Unit>(
    runtime: owner,
    capacity: 8,
    ttl: const Duration(seconds: 1),
    lookup: (_) => Effect.sync(() => Payload(1024 * 1024)),
  );
  final refs = await seedExpired(cache, rt);
  clock.advance(const Duration(days: 1));
  final before = await heap(probe);
  final liveBefore = refs.where((r) => r.target != null).length;
  final hiddenKeys = cache.keys.length, slots = cache.size;
  await cache.purgeExpired();
  final after = await heap(probe);
  final liveAfter = refs.where((r) => r.target != null).length;
  await cache.close();
  await owner.shutdown();
  await rt.shutdown();
  return {
    'logicalVisibleKeysAfterTtl': hiddenKeys,
    'residentSlotsAfterTtl': slots,
    'payloadBytes': 1024 * 1024,
    'livePayloadsBeforePurge': liveBefore,
    'livePayloadsAfterPurge': liveAfter,
    'before': before,
    'after': after,
  };
}

Future<Map<String, Object?>> retiringLoads(HeapProbe probe) async {
  final rt = Runtime(Unit.value), gate = Completer<void>();
  var started = 0;
  final refs = <WeakReference<Payload>>[];
  final cache = EffectCache<int, int, String, Unit>(
    runtime: rt,
    capacity: 1,
    ttl: const Duration(minutes: 1),
    lookup: (_) => Effect.defer(() {
      final payload = Payload(128 * 1024);
      refs.add(WeakReference(payload));
      started++;
      return Effect.succeed<int, String, Unit>(1).ensuring(
        Effect.fromFuture<Unit, String, Unit>(() async {
          await gate.future;
          if (payload.data.length != 128 * 1024) throw StateError('payload');
          return Unit.value;
        }),
      );
    }),
  );
  for (var i = 0; i < 64; i++) {
    final waiter = rt.fork(cache.get(i));
    await until(() => started == i + 1);
    await waiter.interruptAndAwait();
  }
  final before = await heap(probe);
  final live = refs.where((r) => r.target != null).length;
  final resident = cache.size, owners = cache.stats.owners;
  gate.complete();
  await cache.close();
  await rt.shutdown();
  final after = await heap(probe);
  return {
    'capacity': 1,
    'residentSlots': resident,
    'unfinishedOwners': owners,
    'livePayloadsUnderSlowCleanup': live,
    'payloadBytes': 128 * 1024,
    'livePayloadsAfterRelease': refs.where((r) => r.target != null).length,
    'before': before,
    'after': after,
  };
}

Future<Map<String, Object?>> blockedOffers(HeapProbe probe) async {
  final rt = Runtime(Unit.value), queue = BoundedQueue<Payload>(1);
  final refs = <WeakReference<Payload>>[];
  queue.tryOffer(Payload(128 * 1024));
  final fibers = <Fiber<bool, QueueClosed>>[];
  for (var i = 0; i < 64; i++) {
    final value = Payload(128 * 1024);
    refs.add(WeakReference(value));
    fibers.add(rt.fork(queue.offer<Unit>(value)));
  }
  await until(() => queue.waitingProducers == 64);
  final before = await heap(probe);
  final live = refs.where((r) => r.target != null).length;
  final buffered = queue.size, pending = queue.waitingProducers;
  queue.shutdown();
  for (final fiber in fibers) {
    await fiber.awaitExit();
  }
  await rt.shutdown();
  final after = await heap(probe);
  return {
    'capacity': 1,
    'buffered': buffered,
    'waitingProducers': pending,
    'payloadBytes': 128 * 1024,
    'liveBlockedPayloads': live,
    'livePayloadsAfterShutdown': refs.where((r) => r.target != null).length,
    'before': before,
    'after': after,
  };
}

Future<Map<String, Object?>> memory() async {
  final probe = await HeapProbe.connect();
  try {
    return {
      'expiredCache': await expiredValues(probe),
      'retiringLoads': await retiringLoads(probe),
      'blockedQueueOffers': await blockedOffers(probe),
    };
  } finally {
    await probe.close();
  }
}

final class JumpClock implements MonotonicClock {
  DateTime wall = DateTime.utc(2026);
  Duration monotonic = Duration.zero;
  final sleeps = <Duration>[];
  @override
  DateTime get now => wall;
  @override
  Duration get elapsed => monotonic;
  @override
  Future<void> sleep(Duration duration, CancellationToken token) async {
    sleeps.add(duration);
  }
}

Future<Map<String, Object?>> metricClock() async {
  final clock = JumpClock(), metrics = RuntimeMetrics();
  final rt = Runtime(Unit.value, clock: clock, metrics: metrics);
  await rt.runFuture(
    Effect.sync<int, String, Unit>(() {
      clock.wall = clock.wall.subtract(const Duration(days: 1));
      clock.monotonic += const Duration(milliseconds: 10);
      return 1;
    }),
  );
  await rt.shutdown();
  final policyClock = JumpClock();
  final owner = Runtime(Unit.value, clock: policyClock);
  final limiter = RateLimiter(const Duration(milliseconds: 10));
  await owner.runFuture(limiter.limit(Effect.succeed<int, String, Unit>(1)));
  policyClock.wall = policyClock.wall.subtract(const Duration(days: 1));
  policyClock.monotonic += const Duration(milliseconds: 10);
  await owner.runFuture(limiter.limit(Effect.succeed<int, String, Unit>(1)));
  await owner.shutdown();
  return {
    'monotonicWorkUs': clock.monotonic.inMicroseconds,
    'reportedRuntimeDurationUs': metrics.totalDuration.inMicroseconds,
    'rateLimiterRequestedSleepUsAfterWallRewind':
        policyClock.sleeps.last.inMicroseconds,
    'rateLimiterMonotonicElapsedUs': policyClock.monotonic.inMicroseconds,
    'clockNote':
        'The custom clock captures requested delays without waiting a day.',
  };
}

Future<Map<String, Object?>> traversalMaterialization() async {
  var generated = 0, firstCallGenerated = 0, calls = 0;
  final rt = Runtime(Unit.value);
  final input = Iterable<int>.generate(10000, (i) {
    generated++;
    return i;
  });
  final result = await rt.runExit(
    Effect.traverse<int, int, String, Unit>(input, (i) {
      calls++;
      firstCallGenerated = generated;
      return Effect.fail('audit-stop');
    }, concurrency: 1),
  );
  await rt.shutdown();
  return {
    'inputItemsGeneratedBeforeFirstWork': firstCallGenerated,
    'workCalls': calls,
    'failedAsRequested': result is Failure<List<int>, String>,
  };
}

Future<void> main(List<String> args) async {
  final report = <String, Object?>{
    'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'sdk': Platform.version,
    'os': Platform.operatingSystem,
    'productionCodeModified': false,
  };
  if (args.contains('--memory')) {
    report['memory'] = await memory();
  } else if (args.contains('--timing')) {
    report['timing'] = await timing();
  } else {
    report['scheduling'] = await scheduling();
    report['deepCauses'] = await causes();
    report['metricClockJump'] = await metricClock();
    report['traversalMaterialization'] = await traversalMaterialization();
  }
  print(jsonEncode(report));
}
