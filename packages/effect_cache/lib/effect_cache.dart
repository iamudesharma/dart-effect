/// Bounded LRU caches with explicit shared-load ownership.
library;

import 'package:effect_core/effect_core.dart';

final class CacheStats {
  int hits = 0, misses = 0, loads = 0, evictions = 0;
}

final class _Entry<V, E> {
  _Entry(this.fiber);
  final Fiber<V, E> fiber;
  Duration? expires;
  bool finished = false;
}

/// Borrows [runtime]; close this cache before shutting that runtime down.
/// Waiter cancellation does not cancel a shared load. Invalidation and eviction
/// cancel and await the removed load. Failure caching is opt-in, Expected only.
final class EffectCache<K, V, E, R> {
  EffectCache({
    required this.runtime,
    required this.lookup,
    required this.capacity,
    required this.ttl,
    this.failureTtl,
  }) {
    if (capacity < 1 || ttl.isNegative || (failureTtl?.isNegative ?? false)) {
      throw ArgumentError('Invalid cache policy');
    }
  }
  final Runtime<R> runtime;
  final Effect<V, E, R> Function(K) lookup;
  final int capacity;
  final Duration ttl;
  final Duration? failureTtl;
  final stats = CacheStats();
  final _entries = <K, _Entry<V, E>>{};
  final _retiring = <Future<Exit<V, E>>>{};
  Future<void>? _closing;
  int get size => _entries.length;
  void _retire(_Entry<V, E> entry) {
    final future = entry.fiber.interruptAndAwait();
    _retiring.add(future);
    future.then((_) => _retiring.remove(future));
  }

  Effect<V, E, R> get(K key) => Effect.asyncExit((ctx) async {
    if (_closing != null) {
      return Failure(Defect(StateError('Cache is closed'), StackTrace.current));
    }
    var entry = _entries[key];
    if (entry != null &&
        entry.finished &&
        elapsedTime(runtime.clock) >= entry.expires!) {
      _entries.remove(key);
      _retire(entry);
      entry = null;
    }
    if (entry != null) {
      stats.hits++;
      _entries.remove(key);
      _entries[key] = entry;
    } else {
      stats.misses++;
      stats.loads++;
      if (_entries.length >= capacity) {
        final old = _entries.remove(_entries.keys.first)!;
        stats.evictions++;
        _retire(old);
      }
      entry = _Entry(runtime.fork(Effect.defer(() => lookup(key))));
      _entries[key] = entry;
      final inserted = entry;
      entry.fiber.awaitExit().then((exit) {
        inserted.finished = true;
        final duration = exit is Success<V, E>
            ? ttl
            : exit is Failure<V, E> && exit.cause is Expected<E>
            ? failureTtl
            : null;
        inserted.expires =
            elapsedTime(runtime.clock) + (duration ?? Duration.zero);
        if (duration == null && identical(_entries[key], inserted)) {
          _entries.remove(key);
        }
      });
    }
    return ctx.evaluate(entry.fiber.join<R>());
  });

  /// Nonloading inspection. Null means missing/pending/expired; Success(null)
  /// remains distinguishable from absence.
  Future<Exit<V, E>?> peek(K key) async {
    final entry = _entries[key];
    if (entry == null ||
        !entry.finished ||
        elapsedTime(runtime.clock) >= entry.expires!) {
      return null;
    }
    return entry.fiber.awaitExit();
  }

  Future<void> invalidate(K key) async {
    final entry = _entries.remove(key);
    if (entry != null) await entry.fiber.interruptAndAwait();
  }

  Future<void> invalidateAll() async {
    final entries = _entries.values.toList();
    _entries.clear();
    for (final entry in entries) {
      entry.fiber.interrupt();
    }
    await Future.wait(entries.map((e) => e.fiber.awaitExit()));
  }

  Effect<V, E, R> refresh(K key) =>
      Effect.fromFuture<void, E, R>(() => invalidate(key))
          .flatMap((_) => get(key));
  Future<void> close() => _closing ??= Future(() async {
    await invalidateAll();
    await Future.wait(_retiring.toList());
  });
}

final class _ResourceEntry<V, E> {
  final ready = Deferred<V, E>();
  final release = Deferred<Unit, E>();
  late final Fiber<Unit, E> owner;
  int borrowers = 0;
  bool retired = false;
  Duration? expires;
}

/// Resources remain alive while borrowed. Eviction retires an entry, and its
/// final borrower triggers release. Capacity bounds resident generations, not
/// generations still borrowed by active users. Close awaits all borrowers.
final class ScopedCache<K, V, E, R> {
  ScopedCache({
    required this.runtime,
    required this.acquire,
    required this.capacity,
    required this.ttl,
  }) {
    if (capacity < 1 || ttl.isNegative) {
      throw ArgumentError('Invalid scoped cache policy');
    }
  }
  final Runtime<R> runtime;
  final Effect<V, E, R> Function(K) acquire;
  final int capacity;
  final Duration ttl;
  final _entries = <K, _ResourceEntry<V, E>>{};
  final _owners = <_ResourceEntry<V, E>>{};
  Future<Cause<E>?>? _closing;
  Cause<E>? _cleanup;
  _ResourceEntry<V, E> _entry(K key) {
    final old = _entries[key];
    if (old != null &&
        (old.expires == null || elapsedTime(runtime.clock) < old.expires!)) {
      _entries.remove(key);
      _entries[key] = old;
      return old;
    }
    if (old != null) {
      _entries.remove(key);
      _retire(old);
    }
    if (_entries.length >= capacity) {
      _retire(_entries.remove(_entries.keys.first)!);
    }
    final entry = _ResourceEntry<V, E>();
    _entries[key] = entry;
    _owners.add(entry);
    entry.owner = runtime.fork(
      Effect.asyncExit<Unit, E, R>((ctx) async {
        final loaded = await ctx.evaluate(Effect.defer(() => acquire(key)));
        if (loaded is Failure<V, E>) {
          return Failure(loaded.cause);
        }
        entry.expires = elapsedTime(runtime.clock) + ttl;
        entry.ready.succeed((loaded as Success<V, E>).value);
        return ctx.evaluate(entry.release.awaitValue<R>());
      }),
    );
    entry.owner.awaitExit().then((exit) {
      if (entry.ready.poll() == null) {
        entry.ready.completeExit(
          exit is Failure<Unit, E>
              ? Failure(exit.cause)
              : Failure(
                  Defect(
                    StateError('Resource owner ended'),
                    StackTrace.current,
                  ),
                ),
        );
      }
      if (identical(_entries[key], entry)) _entries.remove(key);
      _owners.remove(entry);
      if (exit is Failure<Unit, E> && exit.cause is! Interrupted<E>) {
        _cleanup = _cleanup == null
            ? exit.cause
            : Sequential(_cleanup!, exit.cause);
      }
    });
    return entry;
  }

  void _retire(_ResourceEntry<V, E> entry) {
    entry.retired = true;
    if (entry.borrowers == 0) entry.release.succeed(Unit.value);
  }

  Effect<A, E, R> use<A>(K key, Effect<A, E, R> Function(V) f) =>
      Effect.asyncExit((ctx) async {
        while (true) {
          if (_closing != null) {
            return Failure(
              Defect(StateError('Scoped cache closed'), StackTrace.current),
            );
          }
          final entry = _entry(key);
          final loaded = await ctx.evaluate(entry.ready.awaitValue<R>());
          if (loaded is Failure<V, E>) return Failure(loaded.cause);
          if (ctx.token.isCancelled) return const Failure(Interrupted());
          if (entry.retired) continue;
          entry.borrowers++;
          try {
            return await ctx.evaluate(
              Effect.defer(() => f((loaded as Success<V, E>).value)).scoped(),
            );
          } finally {
            entry.borrowers--;
            if (entry.retired && entry.borrowers == 0) {
              entry.release.succeed(Unit.value);
            }
          }
        }
      });

  /// Invalidating a borrowed generation schedules release after its last user.
  void invalidate(K key) {
    final entry = _entries.remove(key);
    if (entry != null) _retire(entry);
  }

  Future<Cause<E>?> close() => _closing ??= Future(() async {
    final owners = _owners.toList();
    _entries.clear();
    for (final entry in owners) {
      _retire(entry);
    }
    await Future.wait(owners.map((e) => e.owner.awaitExit()));
    return _cleanup;
  });
}
