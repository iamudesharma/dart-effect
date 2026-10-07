import 'dart:async';
import 'dart:collection';

import 'core.dart';

/// Atomic synchronous state in one isolate. Mutators run lazily, once per run.
final class Ref<A> {
  Ref(this._value);
  A _value;
  A get valueUnsafe => _value;
  Effect<A, Never, R> get<R>() => Effect.sync(() => _value);
  Effect<Unit, Never, R> set<R>(A value) => Effect.sync(() {
    _value = value;
    return Unit.value;
  });
  Effect<A, Never, R> update<R>(A Function(A) f) => Effect.sync(() {
    final next = f(_value);
    _value = next;
    return next;
  });
  Effect<B, Never, R> modify<B, R>((B, A) Function(A) f) => Effect.sync(() {
    final result = f(_value);
    _value = result.$2;
    return result.$1;
  });
}

/// Exactly one memoized outcome, shared by independent interruptible waiters.
final class Deferred<A, E> {
  Exit<A, E>? _exit;
  bool _claimed = false;
  final _waiters = <Completer<Exit<A, E>>>{};
  bool get isDone => _exit != null;
  int get waitingCount => _waiters.length;
  Exit<A, E>? poll() => _exit;
  bool completeExit(Exit<A, E> exit) {
    if (_claimed) return false;
    _claimed = true;
    _resolve(exit);
    return true;
  }

  void _resolve(Exit<A, E> exit) {
    _exit = exit;
    for (final waiter in _waiters.toList()) {
      waiter.complete(exit);
    }
    _waiters.clear();
  }

  bool succeed(A value) => completeExit(Success(value));
  bool fail(E error) => completeExit(Failure(Expected(error)));
  bool interrupt() => completeExit(const Failure(Interrupted()));
  bool die(Object error, StackTrace trace) =>
      completeExit(Failure(Defect(error, trace)));
  Effect<A, E, R> awaitValue<R>() => Effect.asyncExit((ctx) async {
    if (_exit case final exit?) return exit;
    if (ctx.token.isCancelled) return const Failure(Interrupted());
    final waiter = Completer<Exit<A, E>>();
    _waiters.add(waiter);
    final detach = ctx.token.onCancel(() {
      if (_waiters.remove(waiter)) {
        waiter.complete(const Failure(Interrupted()));
      }
    });
    try {
      return await waiter.future;
    } finally {
      detach();
      _waiters.remove(waiter);
    }
  });

  /// Claim before evaluation, memoize even failure/interruption, evaluate at most once.
  Effect<bool, E, R> complete<R>(Effect<A, E, R> effect) =>
      Effect.asyncExit((ctx) async {
        if (_claimed) return const Success(false);
        _claimed = true;
        final exit = await ctx.evaluate(effect);
        _resolve(exit);
        return const Success(true);
      });
}

final class _PermitWaiter {
  _PermitWaiter(this.count);
  final int count;
  final done = Completer<bool>();
  void Function() detach = () {};
}

/// Strict FIFO weighted permits. Larger head requests cannot be bypassed.
final class Semaphore {
  Semaphore(this.capacity) : _available = capacity {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }
  final int capacity;
  int _available;
  final _waiters = Queue<_PermitWaiter>();
  int get available => _available;
  int get waitingCount => _waiters.length;
  Future<bool> _acquire(int permits, CancellationToken token) async {
    if (token.isCancelled) return false;
    final waiter = _PermitWaiter(permits);
    _waiters.add(waiter);
    waiter.detach = token.onCancel(() {
      if (_waiters.remove(waiter)) {
        waiter.done.complete(false);
        _drain();
      }
    });
    _drain();
    return waiter.done.future;
  }

  void _drain() {
    while (_waiters.isNotEmpty && _waiters.first.count <= _available) {
      final waiter = _waiters.removeFirst();
      waiter.detach();
      _available -= waiter.count;
      waiter.done.complete(true);
    }
  }

  Effect<A, E, R> withPermits<A, E, R>(int permits, Effect<A, E, R> effect) {
    if (permits < 1 || permits > capacity) {
      throw ArgumentError.value(permits, 'permits');
    }
    return Effect.asyncExit((ctx) async {
      if (!await _acquire(permits, ctx.token)) {
        return const Failure(Interrupted());
      }
      try {
        return await ctx.evaluate(effect);
      } finally {
        _available += permits;
        _drain();
      }
    });
  }
}

/// Effectful atomic modification, serialized across asynchronous callbacks.
final class SynchronizedRef<A> {
  SynchronizedRef(this._value);
  A _value;
  final _lock = Semaphore(1);
  A get valueUnsafe => _value;
  Effect<B, E, R> modifyEffect<B, E, R>(Effect<(B, A), E, R> Function(A) f) =>
      _lock.withPermits(
        1,
        Effect.asyncExit((ctx) async {
          final exit = await ctx.evaluate(f(_value));
          if (exit is Failure<(B, A), E>) return Failure(exit.cause);
          final result = (exit as Success<(B, A), E>).value;
          _value = result.$2;
          return Success(result.$1);
        }),
      );
}

/// Shutdown is an expected channel error, separate from interruption/defects.
final class QueueClosed {
  const QueueClosed();
  @override
  String toString() => 'QueueClosed';
}

final class _QueueWaiter<A> {
  final done = Completer<Exit<A, QueueClosed>>();
  void Function() detach = () {};
  void finish(Exit<A, QueueClosed> exit) {
    detach();
    done.complete(exit);
  }
}

final class _Offer<A> extends _QueueWaiter<bool> {
  _Offer(this.value);
  final A value;
}

/// FIFO bounded channel; capacity zero rendezvous is supported. Shutdown drops
/// buffered items and wakes both producers and consumers. No graceful end alias.
final class BoundedQueue<A> {
  BoundedQueue(this.capacity) {
    if (capacity < 0) throw ArgumentError.value(capacity, 'capacity');
  }
  final int capacity;
  final _items = Queue<A>();
  final _offers = Queue<_Offer<A>>();
  final _takes = Queue<_QueueWaiter<A>>();
  final _shutdown = Completer<void>();
  void Function()? _onChange;
  bool get isShutdown => _shutdown.isCompleted;
  int get size => _items.length;
  int get waitingProducers => _offers.length;
  int get waitingConsumers => _takes.length;
  Future<void> get whenShutdown => _shutdown.future;
  bool get _canOffer =>
      !isShutdown && _offers.isEmpty && (_takes.isNotEmpty || size < capacity);
  void _drain() {
    if (isShutdown) return;
    while (true) {
      if (_takes.isNotEmpty && _items.isNotEmpty) {
        _takes.removeFirst().finish(Success(_items.removeFirst()));
      } else if (_takes.isNotEmpty && _offers.isNotEmpty) {
        final offer = _offers.removeFirst();
        _takes.removeFirst().finish(Success(offer.value));
        offer.finish(const Success(true));
      } else if (_offers.isNotEmpty && size < capacity) {
        final offer = _offers.removeFirst();
        _items.add(offer.value);
        offer.finish(const Success(true));
      } else {
        break;
      }
    }
    _onChange?.call();
  }

  /// Nonblocking acceptance. False means full or shut down; no message is stored.
  bool tryOffer(A value) {
    if (!_canOffer) return false;
    if (_takes.isNotEmpty) {
      _takes.removeFirst().finish(Success(value));
    } else {
      _items.add(value);
    }
    _onChange?.call();
    return true;
  }

  /// A record distinguishes an empty queue from a queued null value.
  (A,)? tryTake() {
    if (isShutdown || _items.isEmpty) return null;
    final value = _items.removeFirst();
    _drain();
    return (value,);
  }

  Effect<bool, QueueClosed, R> offer<R>(A value) =>
      Effect.asyncExit((ctx) async {
        if (isShutdown) return const Failure(Expected(QueueClosed()));
        if (ctx.token.isCancelled) return const Failure(Interrupted());
        final waiter = _Offer(value);
        _offers.add(waiter);
        waiter.detach = ctx.token.onCancel(() {
          if (_offers.remove(waiter)) {
            waiter.finish(const Failure(Interrupted()));
            _drain();
          }
        });
        _drain();
        return waiter.done.future;
      });
  Effect<A, QueueClosed, R> take<R>() => Effect.asyncExit((ctx) async {
    if (isShutdown) return const Failure(Expected(QueueClosed()));
    if (ctx.token.isCancelled) return const Failure(Interrupted());
    final waiter = _QueueWaiter<A>();
    _takes.add(waiter);
    waiter.detach = ctx.token.onCancel(() {
      if (_takes.remove(waiter)) {
        waiter.finish(const Failure(Interrupted()));
        _drain();
      }
    });
    _drain();
    return waiter.done.future;
  });
  void shutdown() {
    if (isShutdown) return;
    _shutdown.complete();
    _items.clear();
    while (_offers.isNotEmpty) {
      _offers.removeFirst().finish(const Failure(Expected(QueueClosed())));
    }
    while (_takes.isNotEmpty) {
      _takes.removeFirst().finish(const Failure(Expected(QueueClosed())));
    }
    _onChange?.call();
  }
}

final class _Publication<A> extends _QueueWaiter<bool> {
  _Publication(this.value);
  final A value;
}

/// A subscription belongs to its creation scope, or must be closed manually if
/// created through subscribeUnsafe. Closing never shuts down other subscribers.
final class Subscription<A> {
  Subscription._(this._hub, this._queue);
  final PubSub<A> _hub;
  final BoundedQueue<A> _queue;
  bool get isClosed => _queue.isShutdown;
  int get size => _queue.size;
  Effect<A, QueueClosed, R> take<R>() => _queue.take<R>();
  (A,)? tryTake() => _queue.tryTake();
  void close() {
    _hub._subscribers.remove(this);
    _queue.shutdown();
    _hub._drain();
  }
}

/// Atomic bounded fan-out to current subscribers. Slow subscribers backpressure
/// publishers; new subscribers receive future publications only (no replay).
final class PubSub<A> {
  PubSub(this.capacity) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }
  final int capacity;
  final _subscribers = <Subscription<A>>{};
  final _pending = Queue<_Publication<A>>();
  bool _closed = false, _draining = false;
  bool get isShutdown => _closed;
  int get subscriberCount => _subscribers.length;
  int get waitingPublishers => _pending.length;
  Subscription<A> subscribeUnsafe() {
    if (_closed) throw StateError('PubSub is shut down');
    final queue = BoundedQueue<A>(capacity);
    queue._onChange = _drain;
    final subscription = Subscription._(this, queue);
    _subscribers.add(subscription);
    return subscription;
  }

  Effect<Subscription<A>, QueueClosed, R> subscribe<R>() =>
      Effect.asyncExit((ctx) {
        if (_closed) return const Failure(Expected(QueueClosed()));
        final subscription = subscribeUnsafe();
        try {
          ctx.scope.addFinalizer(() {
            subscription.close();
            return null;
          });
        } catch (_) {
          subscription.close();
          rethrow;
        }
        return Success(subscription);
      });
  Effect<bool, QueueClosed, R> publish<R>(A value) =>
      Effect.asyncExit((ctx) async {
        if (_closed) return const Failure(Expected(QueueClosed()));
        if (ctx.token.isCancelled) return const Failure(Interrupted());
        final publication = _Publication(value);
        _pending.add(publication);
        publication.detach = ctx.token.onCancel(() {
          if (_pending.remove(publication)) {
            publication.finish(const Failure(Interrupted()));
            _drain();
          }
        });
        _drain();
        return publication.done.future;
      });
  void _drain() {
    if (_closed || _draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty &&
          _subscribers.every((s) => s._queue._canOffer)) {
        final publication = _pending.removeFirst();
        for (final subscription in _subscribers.toList()) {
          subscription._queue.tryOffer(publication.value);
        }
        publication.finish(const Success(true));
      }
    } finally {
      _draining = false;
    }
  }

  void shutdown() {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscribers.toList()) {
      subscription.close();
    }
    while (_pending.isNotEmpty) {
      _pending.removeFirst().finish(const Failure(Expected(QueueClosed())));
    }
  }
}
