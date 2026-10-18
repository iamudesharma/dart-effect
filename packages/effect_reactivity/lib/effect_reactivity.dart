/// Atomic current value plus a race-free, latest-value changes subscription.
library;

import 'dart:async';

import 'package:effect_core/effect_core.dart';

/// Slow listeners receive the latest value, not every transition. Each listener
/// retains at most one pending state. Initial snapshot and registration are atomic.
final class SubscriptionRef<T> {
  SubscriptionRef(this._value);
  T _value;
  bool _closed = false;
  final _listeners = <void Function(T)>{};
  final _closers = <void Function()>{};
  T get value => _value;
  int get subscriberCount => _listeners.length;
  void set(T value) {
    if (_closed) throw StateError('SubscriptionRef is closed');
    _value = value;
    for (final listener in List.of(_listeners)) {
      listener(value);
    }
  }

  U modify<U>((U, T) Function(T) f) {
    if (_closed) throw StateError('SubscriptionRef is closed');
    final pair = f(_value);
    set(pair.$2);
    return pair.$1;
  }

  Stream<T> get changes => Stream<T>.multi((controller) {
    if (_closed) {
      controller.closeSync();
      return;
    }
    var scheduled = false, pending = false;
    T latest = _value;
    void deliver() {
      if (scheduled) return;
      scheduled = true;
      scheduleMicrotask(() {
        scheduled = false;
        if (controller.isClosed || controller.isPaused || !pending) return;
        pending = false;
        controller.addSync(latest);
      });
    }

    void emit(T value) {
      latest = value;
      pending = true;
      deliver();
    }

    void close() => controller.closeSync();
    _listeners.add(emit);
    _closers.add(close);
    controller.addSync(_value);
    controller.onResume = deliver;
    controller.onCancel = () {
      _listeners.remove(emit);
      _closers.remove(close);
    };
  });
  EffectStream<T, E, R> stream<E, R>() =>
      EffectStream.fromNative(() => changes);
  void close() {
    if (_closed) return;
    _closed = true;
    for (final close in List.of(_closers)) {
      close();
    }
    _listeners.clear();
    _closers.clear();
  }
}

/// A typed graceful terminal protocol. Accepted values drain before completion.
sealed class ChannelItem<A, E> {
  const ChannelItem();
}

final class ChannelValue<A, E> extends ChannelItem<A, E> {
  const ChannelValue(this.value);
  final A value;
}

final class ChannelEnd<A, E> extends ChannelItem<A, E> {
  const ChannelEnd();
}

final class ChannelFailure<A, E> extends ChannelItem<A, E> {
  const ChannelFailure(this.error);
  final E error;
}

final class Channel<A, E> {
  Channel(int capacity) : _queue = BoundedQueue(capacity);
  final BoundedQueue<A> _queue;
  ChannelItem<A, E>? _terminal;
  Effect<bool, QueueClosed, R> offer<R>(A value) => _queue.offer(value);
  void complete() {
    _terminal ??= ChannelEnd();
    _queue.complete();
  }

  void fail(E error) {
    _terminal ??= ChannelFailure(error);
    _queue.complete();
  }

  void shutdown() => _queue.shutdown();
  Effect<ChannelItem<A, E>, QueueClosed, R> take<R>() => _queue
      .takeOption<R>()
      .map((next) => next == null ? _terminal! : ChannelValue(next.$1));
}
