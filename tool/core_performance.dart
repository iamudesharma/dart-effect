import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:effect_core/effect_core.dart';

import 'performance_memory.dart';

final class Work {
  Work(this.effect);
  final bool effect;
  final runtime = Runtime(Unit.value);
  Future<void> batch(String workload) async {
    if (workload.startsWith('chain')) {
      final n = workload == 'chain-10000' ? 10000 : 100000;
      if (effect) {
        var chain = Effect.succeed<int, String, Unit>(0);
        for (var i = 0; i < n; i++) {
          chain = chain.flatMap((v) => Effect.succeed(v + 1));
        }
        check(await runtime.runFuture(chain) == n, 'chain result');
      } else {
        var chain = Future.value(0);
        for (var i = 0; i < n; i++) {
          chain = chain.then((v) => v + 1);
        }
        check(await chain == n, 'chain result');
      }
    } else if (workload == 'bounded-8') {
      var active = 0, peak = 0;
      Future<int> operation(int n) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        return n;
      }

      List<int> result;
      if (effect) {
        result = await runtime.runFuture(
          Effect.traverse<int, int, String, Unit>(
            List.generate(1000, (i) => i),
            (n) => Effect.fromFuture(() => operation(n)),
            concurrency: 8,
          ),
        );
      } else {
        var next = 0;
        result = List.filled(1000, -1);
        await Future.wait(
          List.generate(8, (_) async {
            while (next < 1000) {
              final n = next++;
              result[n] = await operation(n);
            }
          }),
        );
      }
      check(
        active == 0 &&
            peak <= 8 &&
            result.asMap().entries.every((e) => e.key == e.value),
        'bounded ordering',
      );
    } else if (workload == 'stream-fold') {
      final values = List.generate(1000, (i) => i);
      final int sum;
      if (effect) {
        sum = await runtime.runFuture(
          EffectStream.fromIterable<int, String, Unit>(values)
              .run(Sink.fold(() => 0, (a, b) => Effect.succeed((a + b, true)))),
        );
      } else {
        sum = await Stream.fromIterable(values).fold<int>(0, (a, b) => a + b);
      }
      check(sum == 499500, 'stream result');
    } else if (workload == 'resources') {
      var acquired = 0, released = 0;
      for (var i = 0; i < 100; i++) {
        if (effect) {
          final op = Effect.acquireUseRelease<int, int, String, Unit>(
            Effect.sync(() => ++acquired),
            (n) => Effect.succeed(n),
            (_, _) => Effect.sync(() {
              released++;
              return Unit.value;
            }),
          );
          await runtime.runFuture(op);
        } else {
          acquired++;
          try {
            await Future.value(acquired);
          } finally {
            released++;
          }
        }
      }
      check(
        acquired == 100 && released == 100,
        'exactly once resource release',
      );
    } else if (workload == 'failures') {
      for (var i = 0; i < 100; i++) {
        if (effect) {
          final exit = await runtime.runExit(
            Effect.fail<int, String, Unit>('expected'),
          );
          check(
            exit is Failure<int, String> && exit.cause is Expected<String>,
            'expected distinction',
          );
        } else {
          try {
            await Future<int>.error('expected');
            throw StateError('missing error');
          } catch (e) {
            check(e == 'expected', 'failure result');
          }
        }
      }
    } else if (workload == 'cancel') {
      for (var i = 0; i < 100; i++) {
        final pending = Completer<int>();
        if (effect) {
          final started = Completer<void>();
          final fiber = runtime.fork(
            Effect.fromFuture<int, String, Unit>(() {
              started.complete();
              return pending.future;
            }),
          );
          await started.future;
          final exit = await fiber.interruptAndAwait();
          check(
            exit is Failure<int, String> && exit.cause is Interrupted<String>,
            'interruption',
          );
        } else {
          final token = CancellationToken();
          final waiting = Future.any([
            pending.future,
            token.whenCancelled.then((_) => -1),
          ]);
          token.cancel();
          check(await waiting == -1, 'cancel result');
        }
        pending.complete(1);
      }
      await Future<void>.delayed(Duration.zero);
    } else {
      throw ArgumentError(workload);
    }
  }
}

@pragma('vm:never-inline')
Future<List<WeakReference<Object>>> churn() async {
  final refs = <WeakReference<Object>>[];
  for (var i = 0; i < 30; i++) {
    final runtime = Runtime(Unit.value);
    final payload = Uint8List(256 * 1024)..[0] = 1;
    final op = Effect.sync<int, String, Unit>(() => payload[0]);
    check(await runtime.runFuture(op) == 1, 'captured payload');
    await runtime.shutdown();
    refs.addAll([
      WeakReference(runtime),
      WeakReference(payload),
      WeakReference(op),
    ]);
  }
  return refs;
}

Future<void> main(List<String> args) async {
  final workload = args[0], effect = args[1] == 'effect';
  final work = Work(effect);
  try {
    if (workload == 'memory') {
      final probe = await HeapProbe.connect();
      try {
        for (var i = 0; i < 3; i++) {
          for (final name in [
            'chain-10000',
            'bounded-8',
            'stream-fold',
            'resources',
            'failures',
            'cancel',
          ]) {
            await work.batch(name);
          }
        }
        final snapshots = [await probe.snapshot()];
        var collected = 0;
        for (var i = 0; i < 6; i++) {
          for (final name in [
            'chain-10000',
            'bounded-8',
            'stream-fold',
            'resources',
            'failures',
            'cancel',
          ]) {
            await work.batch(name);
          }
          final refs = effect ? await churn() : <WeakReference<Object>>[];
          snapshots.add(await probe.snapshot());
          check(
            refs.every((r) => r.target == null),
            'closed runtime/payload/effect retained',
          );
          collected += refs.length;
        }
        final strong = Object();
        final positive = WeakReference(strong);
        await probe.snapshot();
        check(positive.target == strong, 'positive reachability control');
        print(
          jsonEncode({
            'implementation': args[1],
            'mode': 'JIT',
            ...memoryResult(snapshots, collected),
          }),
        );
      } finally {
        await probe.close();
      }
    } else {
      for (var i = 0; i < 3; i++) {
        await work.batch(workload);
      }
      final samples = <int>[];
      for (var i = 0; i < 9; i++) {
        final clock = Stopwatch()..start();
        await work.batch(workload);
        samples.add(clock.elapsedMicroseconds);
      }
      print(
        jsonEncode({
          'implementation': args[1],
          'workload': workload,
          'mode': const bool.fromEnvironment('benchmark.aot') ? 'AOT' : 'JIT',
          'samplesMicros': samples,
          'rssBytes': ProcessInfo.currentRss,
          'peakRssBytes': ProcessInfo.maxRss,
        }),
      );
    }
  } finally {
    await work.runtime.shutdown();
  }
}
