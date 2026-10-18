/// Explicit bounded, tenant-partitioned request batching with shared results.
library;

import 'package:effect_core/effect_core.dart';

final class _Request<K, V, E> {
  _Request(this.key, this.group);
  final K key;
  final Object group;
  final result = Deferred<V, E>();
}

/// Equality is the pair (group,key). Always include tenant/auth scope in group.
/// A single worker bounds backend concurrency to one batch. Waiter cancellation
/// withdraws only that waiter; accepted requests still participate in the batch.
final class RequestResolver<K, V, E, R> {
  RequestResolver({
    required this.runtime,
    required this.resolve,
    required this.onOverload,
    this.maxBatchSize = 100,
    this.maxPending = 1024,
    this.window = Duration.zero,
  }) {
    if (maxBatchSize < 1 || maxPending < 1 || window.isNegative) {
      throw ArgumentError('Invalid batch bounds');
    }
  }
  final Runtime<R> runtime;
  final Effect<Map<K, Exit<V, E>>, E, R> Function(Object group, List<K> keys)
  resolve;
  final E Function(K) onOverload;
  final int maxBatchSize, maxPending;
  final Duration window;
  final _entries = <(Object, K), _Request<K, V, E>>{};
  final _pending = <_Request<K, V, E>>[];
  Fiber<Unit, E>? _worker;
  Future<void>? _closing;
  int get pendingCount => _entries.length;
  Effect<V, E, R> request(K key, {Object group = Unit.value}) =>
      Effect.asyncExit((ctx) async {
        if (_closing != null) {
          return Failure(
            Defect(StateError('Resolver is closed'), StackTrace.current),
          );
        }
        var entry = _entries[(group, key)];
        if (entry == null) {
          if (_entries.length >= maxPending) {
            return Failure(Expected(onOverload(key)));
          }
          entry = _Request(key, group);
          _entries[(group, key)] = entry;
          _pending.add(entry);
          _start();
        }
        return ctx.evaluate(entry.result.awaitValue<R>());
      });
  void _start() {
    if (_worker != null || _closing != null) return;
    final fiber = runtime.fork(
      Effect.asyncExit<Unit, E, R>((ctx) async {
        while (_pending.isNotEmpty && !ctx.token.isCancelled) {
          final waited = await ctx.evaluate(Effect.sleep<E, R>(window));
          if (waited is Failure<Unit, E>) return waited;
          final group = _pending.first.group;
          final batch = _pending
              .where((e) => e.group == group)
              .take(maxBatchSize)
              .toList();
          for (final entry in batch) {
            _pending.remove(entry);
          }
          final exit = await ctx.evaluate(
            Effect.defer(
              () => resolve(group, List.unmodifiable(batch.map((e) => e.key))),
            ),
          );
          for (final entry in batch) {
            final result = exit is Failure<Map<K, Exit<V, E>>, E>
                ? Failure<V, E>(exit.cause)
                : (exit as Success<Map<K, Exit<V, E>>, E>).value[entry.key] ??
                      Failure<V, E>(
                        Defect(
                          StateError('Resolver omitted a requested key'),
                          StackTrace.current,
                        ),
                      );
            entry.result.completeExit(result);
            _entries.remove((group, entry.key));
          }
        }
        return const Success(Unit.value);
      }),
    );
    _worker = fiber;
    fiber.awaitExit().then((exit) {
      _worker = null;
      if (exit is Failure<Unit, E>) {
        for (final entry in _entries.values) {
          entry.result.completeExit(Failure(exit.cause));
        }
        _entries.clear();
        _pending.clear();
      }
      if (_pending.isNotEmpty) _start();
    });
  }

  Future<void> close() => _closing ??= Future(() async {
    await _worker?.interruptAndAwait();
    for (final entry in _entries.values) {
      entry.result.interrupt();
    }
    _entries.clear();
    _pending.clear();
  });
}
