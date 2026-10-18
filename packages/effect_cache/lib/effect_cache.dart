/// Portable value and resource caches with explicit runtime ownership.
library;

import 'package:effect_core/effect_core.dart';

/// Immutable point-in-time counters. Pending entries count toward size.
final class CacheStats {
  const CacheStats({
    required this.hits,
    required this.misses,
    required this.loads,
    required this.evictions,
    required this.expirations,
    required this.size,
    required this.owners,
    required this.droppedDiagnostics,
  });
  final int hits, misses, loads, evictions, expirations, size, owners;

  /// Errors beyond the 32 retained diagnostic records, until drained.
  final int droppedDiagnostics;
}

final class _Counters {
  int hits = 0, misses = 0, loads = 0, evictions = 0, expirations = 0;
  CacheStats snapshot(int size, int owners, int dropped) => CacheStats(
    hits: hits,
    misses: misses,
    loads: loads,
    evictions: evictions,
    expirations: expirations,
    size: size,
    owners: owners,
    droppedDiagnostics: dropped,
  );
}

Cause<E>? _append<E>(Cause<E>? a, Cause<E>? b) => a == null
    ? b
    : b == null
    ? a
    : Sequential(a, b);

final class _Diagnostics<E> {
  final _causes = <Cause<E>>[];
  int dropped = 0;
  void add(Cause<E>? cause) {
    if (cause == null) return;
    if (_causes.length == 32) {
      dropped++;
      return;
    }
    _causes.add(cause);
  }

  Cause<E>? get cause => _causes.fold<Cause<E>?>(null, _append);
  List<Cause<E>> take() {
    final result = List<Cause<E>>.unmodifiable(_causes);
    _causes.clear();
    dropped = 0;
    return result;
  }
}

Cause<E>? _withoutInterrupt<E>(Cause<E> cause) {
  final pending = <Cause<E>>[cause];
  Cause<E>? result;
  while (pending.isNotEmpty) {
    final next = pending.removeLast();
    if (next is Sequential<E>) {
      pending.addAll([next.second, next.first]);
    } else if (next is! Interrupted<E>) {
      result = _append(result, next);
    }
  }
  return result;
}

// The runtime safely retypes causes at evaluation boundaries, recreating nodes.
// Compare leaf identity and shape rather than relying on node identity.
bool _sameCause<E>(Cause<E> a, Cause<E> b) {
  final pending = <(Cause<E>, Cause<E>)>[(a, b)];
  while (pending.isNotEmpty) {
    final (x, y) = pending.removeLast();
    if (x is Sequential<E> && y is Sequential<E>) {
      pending.addAll([(x.first, y.first), (x.second, y.second)]);
    } else if (x is Expected<E> && y is Expected<E>) {
      if (!identical(x.error, y.error)) return false;
    } else if (x is Defect<E> && y is Defect<E>) {
      if (!identical(x.error, y.error) ||
          !identical(x.stackTrace, y.stackTrace)) {
        return false;
      }
    } else if (x is! Interrupted<E> || y is! Interrupted<E>) {
      return false;
    }
  }
  return true;
}

/// No background worker is started implicitly. One worker per cache at a time.
final class _Maintenance<E, R> {
  Fiber<Unit, E>? fiber;
  Fiber<Unit, E> start(
    Runtime<R> runtime,
    Duration interval,
    Effect<Unit, E, R> Function() tick,
  ) {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval');
    }
    if (fiber != null) throw StateError('Maintenance is already running');
    final started = runtime.fork(
      Effect.asyncExit<Unit, E, R>((ctx) async {
        while (true) {
          final slept = await ctx.evaluate(Effect.sleep<E, R>(interval));
          if (slept is Failure<Unit, E>) return slept;
          final result = await ctx.evaluate(Effect.defer(tick));
          if (result is Failure<Unit, E>) return result;
        }
      }),
    );
    fiber = started;
    started.awaitExit().then((_) {
      if (identical(fiber, started)) fiber = null;
    });
    return started;
  }

  Future<void> stop() async {
    await fiber?.interruptAndAwait();
  }
}

final class _Entry<V, E> {
  _Entry(this.fiber);
  final Fiber<V, E> fiber;
  Duration? expires;
  bool finished = false;
  Future<Cause<E>?>? retiring;
}

/// Bounded LRU value cache. TTL begins after lookup and its cleanup finish.
///
/// Borrows [runtime]; close before shutting it down. Even cancellation of the
/// last waiter leaves the shared load running. Eviction/invalidation/close stop
/// removed loads. Actual I/O needs an abort hook. Capacity bounds residents,
/// not cleanup still running after eviction; limit application concurrency too.
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

  /// Opt-in for single Expected failures. Defects/composites are never cached.
  final Duration? failureTtl;
  final _counters = _Counters();
  final _diagnostics = _Diagnostics<E>();
  final _maintenance = _Maintenance<E, R>();
  final _entries = <K, _Entry<V, E>>{};
  final _retiring = <Future<Cause<E>?>>{};
  Future<Cause<E>?>? _closing;
  int get size => _entries.length;
  bool get isClosed => _closing != null;
  CacheStats get stats => _counters.snapshot(
    size,
    _entries.values.where((e) => !e.finished).length + _retiring.length,
    _diagnostics.dropped,
  );
  void _checkOpen() {
    if (isClosed) throw StateError('Cache is closed');
  }

  bool _expired(_Entry<V, E> e) =>
      e.finished && elapsedTime(runtime.clock) >= e.expires!;
  List<K> get keys => List<K>.unmodifiable(
    _entries.entries.where((e) => !_expired(e.value)).map((e) => e.key),
  );

  /// Includes pending entries; excludes expired ones. Does not touch LRU order.
  bool containsKey(K key) {
    final e = _entries[key];
    return e != null && !_expired(e);
  }

  Future<Cause<E>?> _retire(_Entry<V, E> entry) {
    if (entry.retiring != null) return entry.retiring!;
    final pending = !entry.finished;
    entry.fiber.interrupt();
    final future = entry.fiber.awaitExit().then((exit) {
      final cause = pending && exit is Failure<V, E>
          ? _withoutInterrupt(exit.cause)
          : null;
      _diagnostics.add(cause);
      return cause;
    });
    entry.retiring = future;
    _retiring.add(future);
    future.then((_) => _retiring.remove(future));
    return future;
  }

  Effect<V, E, R> get(K key) => Effect.asyncExit((ctx) async {
    _checkOpen();
    var entry = _entries[key];
    if (entry != null && _expired(entry)) {
      _entries.remove(key);
      _counters.expirations++;
      _retire(entry);
      entry = null;
    }
    if (entry != null) {
      _counters.hits++;
      _entries.remove(key);
      _entries[key] = entry;
    } else {
      _counters.misses++;
      _counters.loads++;
      if (_entries.length >= capacity) {
        _retire(_entries.remove(_entries.keys.first)!);
        _counters.evictions++;
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
        if ((duration == null || duration == Duration.zero) &&
            identical(_entries[key], inserted)) {
          _entries.remove(key);
        }
      });
    }
    return ctx.evaluate(entry.fiber.join<R>());
  });

  /// Nonloading inspection. Success(null) is distinct from missing/pending.
  Future<Exit<V, E>?> peek(K key) async {
    final e = _entries[key];
    if (e == null || !e.finished || _expired(e)) return null;
    return e.fiber.awaitExit();
  }

  /// Detaches immediately and awaits cleanup; diagnostics also remain drainable.
  Future<Cause<E>?> invalidate(K key) async {
    final e = _entries.remove(key);
    return e == null ? null : _retire(e);
  }

  Future<Cause<E>?> invalidateAll() async {
    final entries = _entries.values.toList();
    _entries.clear();
    return (await Future.wait(entries.map(_retire)))
        .fold<Cause<E>?>(null, _append);
  }

  /// Strict replacement, not stale-while-revalidate. Concurrent refresh calls
  /// can invalidate one another; use get for single-flight reads.
  Effect<V, E, R> refresh(K key) => Effect.asyncExit((ctx) async {
    _checkOpen();
    final cause = await invalidate(key);
    if (cause != null) return Failure(cause);
    return ctx.evaluate(get(key));
  });

  /// Eager idle expiry on demand; get also expires its touched key.
  Future<Cause<E>?> purgeExpired() async {
    final entries = _entries.entries.where((e) => _expired(e.value)).toList();
    for (final e in entries) {
      _entries.remove(e.key);
      _counters.expirations++;
    }
    return (await Future.wait(entries.map((e) => _retire(e.value))))
        .fold<Cause<E>?>(null, _append);
  }

  /// Explicit periodic expiry, or sequential strict refresh of resident keys.
  /// Worker stops on the first failure: inspect the returned Fiber's Exit.
  Fiber<Unit, E> startMaintenance({
    required Duration interval,
    bool refresh = false,
  }) {
    _checkOpen();
    return _maintenance.start(
      runtime,
      interval,
      () => Effect.asyncExit((ctx) async {
        if (refresh) {
          for (final key in _entries.keys.toList()) {
            final result = await ctx.evaluate(this.refresh(key));
            if (result is Failure<V, E>) return Failure(result.cause);
          }
        } else {
          final cause = await purgeExpired();
          if (cause != null) return Failure(cause);
        }
        return const Success(Unit.value);
      }),
    );
  }

  /// Drains at most 32 retirement records and resets the dropped-record count.
  List<Cause<E>> takeDiagnostics() => _diagnostics.take();

  /// Rejects new loads immediately. Repeated calls share one completion.
  Future<Cause<E>?> close() => _closing ??= Future(() async {
    await _maintenance.stop();
    await invalidateAll();
    await Future.wait(_retiring.toList());
    return _diagnostics.cause;
  });
}

final class _ResourceEntry<V, E> {
  final ready = Deferred<V, E>();
  final release = Deferred<Unit, E>();
  late final Fiber<Unit, E> owner;
  int borrowers = 0;
  bool retired = false;
  Duration? expires;
  Cause<E>? acquisitionFailure;
}

/// Resource generations release after their last borrower's cleanup finishes.
/// Never return a raw resource from use or close inside its own borrow.
/// Capacity bounds residents; active retired generations need caller-side
/// concurrency limits. Use acquireScoped for cancel-safe acquisition.
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
  final _counters = _Counters();
  final _diagnostics = _Diagnostics<E>();
  final _maintenance = _Maintenance<E, R>();
  Future<Cause<E>?>? _closing;
  bool get isClosed => _closing != null;
  int get size => _entries.length;
  CacheStats get stats =>
      _counters.snapshot(size, _owners.length, _diagnostics.dropped);
  bool _expired(_ResourceEntry<V, E> e) =>
      e.expires != null && elapsedTime(runtime.clock) >= e.expires!;
  List<K> get keys => List<K>.unmodifiable(
    _entries.entries.where((e) => !_expired(e.value)).map((e) => e.key),
  );

  /// Metadata only, including pending acquisitions. Does not expose resources.
  bool containsKey(K key) {
    final e = _entries[key];
    return e != null && !_expired(e);
  }

  void _checkOpen() {
    if (isClosed) throw StateError('Scoped cache is closed');
  }

  _ResourceEntry<V, E> _entry(K key) {
    final old = _entries[key];
    if (old != null && !_expired(old)) {
      _counters.hits++;
      _entries.remove(key);
      _entries[key] = old;
      return old;
    }
    if (old != null) {
      _entries.remove(key);
      _counters.expirations++;
      _retire(old);
    }
    if (_entries.length >= capacity) {
      _counters.evictions++;
      _retire(_entries.remove(_entries.keys.first)!);
    }
    _counters.misses++;
    _counters.loads++;
    final entry = _ResourceEntry<V, E>();
    entry.owner = runtime.fork(
      Effect.asyncExit<Unit, E, R>((ctx) async {
        final loaded = await ctx.evaluate(Effect.defer(() => acquire(key)));
        if (loaded is Failure<V, E>) {
          entry.acquisitionFailure = loaded.cause;
          return Failure(loaded.cause);
        }
        entry.expires = elapsedTime(runtime.clock) + ttl;
        entry.ready.succeed((loaded as Success<V, E>).value);
        return ctx.evaluate(entry.release.awaitValue<R>());
      }),
    );
    _entries[key] = entry;
    _owners.add(entry);
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
      if (exit is Failure<Unit, E>) {
        var cause = exit.cause;
        // Acquisition outcomes go to the waiters. Only appended root cleanup
        // belongs in retirement diagnostics, not ordinary missing-key failures.
        if (entry.acquisitionFailure != null &&
            _sameCause(cause, entry.acquisitionFailure!)) {
          return;
        }
        if (cause is Sequential<E> &&
            entry.acquisitionFailure != null &&
            _sameCause(cause.first, entry.acquisitionFailure!)) {
          cause = cause.second;
        }
        _diagnostics.add(_withoutInterrupt(cause));
      }
    });
    return entry;
  }

  void _retire(_ResourceEntry<V, E> e) {
    if (e.retired) return;
    e.retired = true;
    if (e.borrowers == 0) {
      if (e.ready.poll() == null) {
        e.owner.interrupt();
      } else {
        e.release.succeed(Unit.value);
      }
    }
  }

  Effect<A, E, R> use<A>(K key, Effect<A, E, R> Function(V) f) =>
      Effect.asyncExit((ctx) async {
        while (true) {
          _checkOpen();
          final e = _entry(key);
          final loaded = await ctx.evaluate(e.ready.awaitValue<R>());
          if (loaded is Failure<V, E>) return Failure(loaded.cause);
          if (ctx.token.isCancelled) return const Failure(Interrupted());
          if (e.retired) continue;
          e.borrowers++;
          try {
            return await ctx.evaluate(
              Effect.defer(() => f((loaded as Success<V, E>).value)).scoped(),
            );
          } finally {
            e.borrowers--;
            if (e.retired && e.borrowers == 0) e.release.succeed(Unit.value);
          }
        }
      });

  /// Retires immediately; borrowers finish before release. Pending acquisition
  /// is interrupted; protected acquisition/cleanup can still wait.
  void invalidate(K key) {
    final e = _entries.remove(key);
    if (e != null) _retire(e);
  }

  void invalidateAll() {
    final entries = _entries.values.toList();
    _entries.clear();
    for (final e in entries) {
      _retire(e);
    }
  }

  void purgeExpired() {
    final entries = _entries.entries.where((e) => _expired(e.value)).toList();
    for (final e in entries) {
      _entries.remove(e.key);
      _counters.expirations++;
      _retire(e.value);
    }
  }

  /// Retire and borrow a new generation. Existing borrowers retain the old one.
  Effect<A, E, R> refresh<A>(K key, Effect<A, E, R> Function(V) f) =>
      Effect.defer(() {
        _checkOpen();
        invalidate(key);
        return use(key, f);
      });
  Fiber<Unit, E> startMaintenance({
    required Duration interval,
    bool refresh = false,
  }) {
    _checkOpen();
    return _maintenance.start(
      runtime,
      interval,
      () => Effect.defer(() {
        if (!refresh) {
          purgeExpired();
          return Effect.succeed(Unit.value);
        }
        return Effect.traverse<K, Unit, E, R>(
          _entries.keys.toList(),
          (key) => this.refresh(key, (_) => Effect.succeed(Unit.value)),
          concurrency: 1,
        ).asUnit;
      }),
    );
  }

  List<Cause<E>> takeDiagnostics() => _diagnostics.take();

  /// Close outside use; await this before shutting down the borrowed runtime.
  Future<Cause<E>?> close() => _closing ??= Future(() async {
    await _maintenance.stop();
    final owners = _owners.toList();
    _entries.clear();
    for (final e in owners) {
      _retire(e);
    }
    await Future.wait(owners.map((e) => e.owner.awaitExit()));
    return _diagnostics.cause;
  });
}
