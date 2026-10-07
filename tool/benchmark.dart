import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:blot_effect/blot_effect.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final workloads = <String, Future<void> Function()>{
    'future-chain-10000': () async {
      var chain = Future.value(0);
      for (var i = 0; i < 10000; i++) {
        chain = chain.then((n) => n + 1);
      }
      if (await chain != 10000) throw StateError('baseline result');
    },
    'effect-chain-10000': () async {
      var chain = Effect.succeed<int, String, Unit>(0);
      for (var i = 0; i < 10000; i++) {
        chain = chain.flatMap((n) => Effect.succeed(n + 1));
      }
      if (await runtime.runFuture(chain) != 10000) {
        throw StateError('effect result');
      }
    },
    'future-deep-100000': () async {
      var chain = Future.value(0);
      for (var i = 0; i < 100000; i++) {
        chain = chain.then((n) => n + 1);
      }
      if (await chain != 100000) throw StateError('baseline result');
    },
    'effect-deep-100000': () async {
      var chain = Effect.succeed<int, String, Unit>(0);
      for (var i = 0; i < 100000; i++) {
        chain = chain.flatMap((n) => Effect.succeed(n + 1));
      }
      if (await runtime.runFuture(chain) != 100000) {
        throw StateError('effect result');
      }
    },
    'future-bounded-2000-8': () async {
      var next = 0;
      await Future.wait(
        List.generate(8, (_) async {
          while (next < 2000) {
            next++;
            await Future<void>.delayed(Duration.zero);
          }
        }),
      );
    },
    'effect-bounded-2000-8': () async {
      await runtime.runFuture(
        Effect.traverse<int, int, String, Unit>(
          List.generate(2000, (n) => n),
          (n) => Effect.fromFuture(() async {
            await Future<void>.delayed(Duration.zero);
            return n;
          }),
          concurrency: 8,
        ),
      );
    },
    'future-cancel-100': () async {
      for (var i = 0; i < 100; i++) {
        final pending = Completer<int>();
        final token = CancellationToken();
        final interrupted = Future.any([
          pending.future,
          token.whenCancelled.then((_) => -1),
        ]);
        token.cancel();
        await interrupted;
        pending.complete(1);
      }
    },
    'effect-cancel-100': () async {
      for (var i = 0; i < 100; i++) {
        final pending = Completer<int>();
        final started = Completer<void>();
        final fiber = runtime.fork(
          Effect.fromFuture<int, String, Unit>(() {
            started.complete();
            return pending.future;
          }),
        );
        await started.future;
        await fiber.interruptAndAwait();
        pending.complete(1);
      }
    },
  };
  final results = <String, Object?>{};
  for (final entry in workloads.entries) {
    for (var warmup = 0; warmup < 3; warmup++) {
      await entry.value();
    }
    final samples = <int>[];
    for (var sample = 0; sample < 11; sample++) {
      final timer = Stopwatch()..start();
      await entry.value();
      timer.stop();
      samples.add(timer.elapsedMicroseconds);
    }
    final sorted = [...samples]..sort();
    results[entry.key] = {
      'samplesMicros': samples,
      'minMicros': sorted.first,
      'medianMicros': sorted[5],
      'p90Micros': sorted[9],
      'meanMicros': samples.reduce((a, b) => a + b) / samples.length,
    };
  }
  await runtime.shutdown();
  print(
    jsonEncode({
      'sdk': Platform.version,
      'platform': Platform.operatingSystem,
      'processors': Platform.numberOfProcessors,
      'mode': const bool.fromEnvironment('benchmark.aot') ? 'AOT' : 'JIT',
      'samples': 11,
      'warmups': 3,
      'results': results,
      'processCurrentRssBytes': ProcessInfo.currentRss,
      'processMaxRssBytes': ProcessInfo.maxRss,
      'memoryNote': 'Process-wide RSS, not per-operation allocations; no allocation attribution.',
      'method': 'Chain construction + execution included for both. Zero-duration event-loop I/O, fixed bound 8. Cancellation baseline is Future.any with token; Effect additionally owns fiber/scope cleanup.',
      'budgets': 'Descriptive baseline only; no agreed regression budget or speedup claim.',
      'deferred': ['streams'],
    }),
  );
}
