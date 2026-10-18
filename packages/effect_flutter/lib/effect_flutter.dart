/// Flutter-native owner for typed effects. Explicit close awaits asynchronous work.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:effect_core/effect_core.dart';

sealed class EffectState<A, E> {
  const EffectState();
}

final class EffectIdle<A, E> extends EffectState<A, E> {
  const EffectIdle();
}

final class EffectLoading<A, E> extends EffectState<A, E> {
  const EffectLoading();
}

final class EffectData<A, E> extends EffectState<A, E> {
  const EffectData(this.value);
  final A value;
}

final class EffectFailed<A, E> extends EffectState<A, E> {
  const EffectFailed(this.cause);
  final Cause<E> cause;
}

final class EffectCancelled<A, E> extends EffectState<A, E> {
  const EffectCancelled();
}

/// Latest invocation wins state updates. Previous work is interrupted and awaited
/// before a replacement starts. Use [close] before owner removal when cleanup
/// must be awaited. Flutter dispose cannot itself await asynchronous cleanup.
final class EffectController<A, E, R> extends ChangeNotifier
    implements ValueListenable<EffectState<A, E>> {
  EffectController(R environment, {Clock? clock})
    : _runtime = Runtime(environment, clock: clock);
  final Runtime<R> _runtime;
  EffectState<A, E> _value = const EffectIdle();
  @override
  EffectState<A, E> get value => _value;
  Fiber<A, E>? _current;
  int _generation = 0;
  bool _disposed = false, _closed = false;
  Future<void>? _closing;
  Future<void> _serial = Future.value();
  void _set(EffectState<A, E> state) {
    if (!_closed && !_disposed) {
      _value = state;
      notifyListeners();
    }
  }

  Future<Exit<A, E>> run(Effect<A, E, R> effect) {
    if (_closed) throw StateError('Controller is closed');
    final generation = ++_generation;
    final result = Completer<Exit<A, E>>();
    final previous = _current;
    previous?.interrupt();
    final start = _serial.then((_) async {
      await previous?.awaitExit();
      if (_closed || generation != _generation) {
        result.complete(const Failure(Interrupted()));
        return;
      }
      _set(const EffectLoading());
      final fiber = _runtime.fork(effect);
      _current = fiber;
      unawaited(
        fiber.awaitExit().then((exit) {
          if (generation == _generation) {
            _current = null;
            _set(switch (exit) {
              Success(:final value) => EffectData(value),
              Failure(:final cause) =>
                cause is Interrupted<E>
                    ? const EffectCancelled()
                    : EffectFailed(cause),
            });
          }
          result.complete(exit);
        }),
      );
    });
    _serial = start;
    return result.future;
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _generation++;
    _current?.interrupt();
    return _closing = Future(() async {
      await _serial;
      await _runtime.shutdown();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
