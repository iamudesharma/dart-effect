import 'dart:async';

import 'core.dart';
import 'concurrency.dart';

sealed class Pull<A> {
  const Pull();
}

final class StreamValue<A> extends Pull<A> {
  const StreamValue(this.value);
  final A value;
}

final class StreamEnd<A> extends Pull<A> {
  const StreamEnd();
}

final class _Cursor<A, E, R> {
  _Cursor(this._pull, [this._release]);
  final FutureOr<Exit<Pull<A>, E>> Function(FiberContext<R>) _pull;
  final FutureOr<Cause<E>?> Function()? _release;
  Future<Cause<E>?>? _closing;
  Effect<Pull<A>, E, R> pull() => Effect.asyncExit((ctx) {
    if (_closing != null) return const Success(StreamEnd());
    return _pull(ctx);
  });
  Future<Cause<E>?> close() =>
      _closing ??= Future<Cause<E>?>.microtask(() async {
        try {
          return await _release?.call();
        } catch (e, s) {
          return Defect(e, s);
        }
      });
}

/// Reusable sink; each consumption allocates fresh state. False stops upstream.
final class Sink<A, B, E, R> {
  Sink.fold(this._initial, this._step);
  final B Function() _initial;
  final Effect<(B, bool), E, R> Function(B, A) _step;
  // Invoke in this instance's original generic context. Reading the function
  // field through a covariantly widened Sink would cast its parameter type.
  Effect<(B, bool), E, R> _advance(B state, A value) => _step(state, value);
  static Sink<A, List<A>, E, R> collect<A, E, R>() => Sink.fold(
    () => <A>[],
    (values, value) => Effect.sync(() {
      values.add(value);
      return (values, true);
    }),
  );
  static Sink<A, (A,)?, E, R> first<A, E, R>() =>
      Sink.fold(() => null, (_, value) => Effect.succeed(((value,), false)));
  static Sink<A, Unit, E, R> drain<A, E, R>() =>
      Sink.fold(() => Unit.value, (_, _) => Effect.succeed((Unit.value, true)));
}

/// Pull-based effects with a local scope per consumption. No implicit buffers.
final class EffectStream<A, E, R> {
  EffectStream._(this._open);
  final Future<Exit<_Cursor<A, E, R>, E>> Function(FiberContext<R>) _open;
  static EffectStream<A, E, R> fromIterable<A, E, R>(Iterable<A> values) =>
      EffectStream._((_) async {
        final iterator = values.iterator;
        return Success(
          _Cursor(
            (_) => Success(
              iterator.moveNext()
                  ? StreamValue(iterator.current)
                  : const StreamEnd(),
            ),
          ),
        );
      });
  static EffectStream<A, E, R> fromEffect<A, E, R>(Effect<A, E, R> effect) =>
      EffectStream._((_) async {
        var consumed = false;
        return Success(
          _Cursor((ctx) async {
            if (consumed) return const Success(StreamEnd());
            consumed = true;
            final exit = await ctx.evaluate(effect);
            return exit is Success<A, E>
                ? Success(StreamValue(exit.value))
                : Failure((exit as Failure<A, E>).cause);
          }),
        );
      });

  /// StreamIterator pauses between demands. A native source ignoring pause may
  /// buffer externally; the package cannot bound that source's internal memory.
  static EffectStream<A, E, R> fromNative<A, E, R>(
    Stream<A> Function() factory, {
    E Function(Object, StackTrace)? onError,
  }) => EffectStream._((_) async {
    final iterator = StreamIterator(factory());
    return Success(
      _Cursor(
        (ctx) async {
          final exit = await ctx.evaluate(
            Effect.fromFuture<bool, E, R>(
              iterator.moveNext,
              onError: onError,
              onCancel: iterator.cancel,
            ),
          );
          if (exit is Failure<bool, E>) return Failure(exit.cause);
          return Success(
            (exit as Success<bool, E>).value
                ? StreamValue(iterator.current)
                : const StreamEnd(),
          );
        },
        () async {
          await iterator.cancel();
          return null;
        },
      ),
    );
  });
  static EffectStream<A, E, R> acquireRelease<Resource, A, E, R>(
    Effect<Resource, E, R> acquire,
    Effect<Object?, E, R> Function(Resource) release,
    EffectStream<A, E, R> Function(Resource) stream,
  ) => EffectStream._((ctx) async {
    final exit = await ctx.masked().evaluate(acquire);
    if (exit is Failure<Resource, E>) return Failure(exit.cause);
    final resource = (exit as Success<Resource, E>).value;
    ctx.scope.addFinalizer(() async {
      final closed = await ctx.masked().evaluate(release(resource));
      return closed is Failure<Object?, E> ? closed.cause : null;
    });
    if (ctx.token.isCancelled) return const Failure(Interrupted());
    return stream(resource)._open(ctx);
  });
  EffectStream<B, E, R> map<B>(B Function(A) f) =>
      mapEffect((a) => Effect.sync(() => f(a)));
  EffectStream<B, E, R> mapEffect<B>(
    Effect<B, E, R> Function(A) f,
  ) => EffectStream._((ctx) async {
    final opened = await _open(ctx);
    if (opened is Failure<_Cursor<A, E, R>, E>) return Failure(opened.cause);
    final source = (opened as Success<_Cursor<A, E, R>, E>).value;
    return Success(
      _Cursor((ctx) async {
        final next = await ctx.evaluate(source.pull());
        if (next is Failure<Pull<A>, E>) return Failure(next.cause);
        final item = (next as Success<Pull<A>, E>).value;
        if (item is StreamEnd<A>) return const Success(StreamEnd());
        final mapped = await ctx.evaluate(f((item as StreamValue<A>).value));
        return mapped is Success<B, E>
            ? Success(StreamValue(mapped.value))
            : Failure((mapped as Failure<B, E>).cause);
      }, source.close),
    );
  });
  EffectStream<A, E, R> filter(bool Function(A) predicate) =>
      EffectStream._((ctx) async {
        final opened = await _open(ctx);
        if (opened is Failure<_Cursor<A, E, R>, E>) return opened;
        final source = (opened as Success<_Cursor<A, E, R>, E>).value;
        return Success(
          _Cursor(
            (ctx) async {
              var skipped = 0;
              while (true) {
                final exit = await ctx.evaluate(source.pull());
                if (exit is Failure<Pull<A>, E>) return exit;
                final item = (exit as Success<Pull<A>, E>).value;
                if (item is StreamEnd<A> ||
                    predicate((item as StreamValue<A>).value)) {
                  return exit;
                }
                if (++skipped % ctx.runtime.yieldEvery == 0) {
                  await Future<void>.delayed(Duration.zero);
                }
              }
            },
            () async {
              return source.close();
            },
          ),
        );
      });
  EffectStream<A, E, R> take(int count) {
    if (count < 0) throw ArgumentError.value(count, 'count');
    if (count == 0) return EffectStream.fromIterable(const []);
    return EffectStream._((ctx) async {
      final opened = await _open(ctx);
      if (opened is Failure<_Cursor<A, E, R>, E>) return opened;
      final source = (opened as Success<_Cursor<A, E, R>, E>).value;
      var remaining = count;
      return Success(
        _Cursor((ctx) async {
          if (remaining-- <= 0) return const Success(StreamEnd());
          return ctx.evaluate(source.pull());
        }, source.close),
      );
    });
  }

  /// At most capacity queued outcomes plus one in-flight upstream pull. Early
  /// exit interrupts and awaits the producer before closing the upstream cursor.
  EffectStream<A, E, R> buffer(int capacity) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
    return EffectStream._((ctx) async {
      final opened = await _open(ctx);
      if (opened is Failure<_Cursor<A, E, R>, E>) return opened;
      final source = (opened as Success<_Cursor<A, E, R>, E>).value;
      final queue = BoundedQueue<Exit<Pull<A>, E>>(capacity);
      final producer = Effect.asyncExit<Unit, E, R>((child) async {
        while (true) {
          final next = await child.evaluate(source.pull());
          final offered = await child.evaluate(queue.offer<R>(next));
          if (offered is Failure<bool, QueueClosed>) {
            return const Failure(Interrupted());
          }
          if (next is Failure<Pull<A>, E> ||
              (next as Success<Pull<A>, E>).value is StreamEnd<A>) {
            return const Success(Unit.value);
          }
        }
      });
      final forked = await ctx.evaluate(producer.forkScoped());
      if (forked is Failure<Fiber<Unit, E>, E>) {
        final cleanup = await source.close();
        return Failure(
          cleanup == null ? forked.cause : Sequential(forked.cause, cleanup),
        );
      }
      final fiber = (forked as Success<Fiber<Unit, E>, E>).value;
      return Success(
        _Cursor(
          (ctx) async {
            final next = await ctx.evaluate(queue.take<R>());
            if (next is Failure<Exit<Pull<A>, E>, QueueClosed>) {
              return Failure(_channelCause<E>(next.cause));
            }
            return (next as Success<Exit<Pull<A>, E>, QueueClosed>).value;
          },
          () async {
            queue.shutdown();
            await fiber.interruptAndAwait();
            return source.close();
          },
        ),
      );
    });
  }

  Effect<B, E, R> run<B>(Sink<A, B, E, R> sink) => Effect.asyncExit((
    ctx,
  ) async {
    final scope = Scope();
    final local = ctx.withScope(scope);
    _Cursor<A, E, R>? cursor;
    late Exit<B, E> result;
    try {
      final opened = await _open(local);
      if (opened is Failure<_Cursor<A, E, R>, E>) {
        result = Failure(opened.cause);
      } else {
        cursor = (opened as Success<_Cursor<A, E, R>, E>).value;
        var state = sink._initial();
        var processed = 0;
        while (true) {
          final pulled = await local.evaluate(cursor.pull());
          if (pulled is Failure<Pull<A>, E>) {
            result = Failure(pulled.cause);
            break;
          }
          final item = (pulled as Success<Pull<A>, E>).value;
          if (item is StreamEnd<A>) {
            result = Success(state);
            break;
          }
          final stepped = await local.evaluate(
            sink._advance(state, (item as StreamValue<A>).value),
          );
          if (stepped is Failure<(B, bool), E>) {
            result = Failure(stepped.cause);
            break;
          }
          final next = (stepped as Success<(B, bool), E>).value;
          state = next.$1;
          if (!next.$2) {
            result = Success(state);
            break;
          }
          if (++processed % ctx.runtime.yieldEvery == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      }
    } catch (e, s) {
      result = Failure(Defect(e, s));
    }
    final cursorFailure = await cursor?.close();
    if (cursorFailure != null) result = _append(result, cursorFailure);
    final finalizers = await scope.close();
    if (finalizers != null) result = _append(result, _restore<E>(finalizers));
    return result;
  });
  Effect<List<A>, E, R> runCollect() => run(Sink.collect());
  Effect<Unit, E, R> runDrain() => run(Sink.drain());
  Effect<Unit, E, R> runForEach(Effect<Unit, E, R> Function(A) f) => run(
    Sink.fold(() => Unit.value, (_, a) => f(a).map((_) => (Unit.value, true))),
  );

  /// Single-subscription native stream. Pause suspends demand (at most one
  /// prefetched value); cancel interrupts the fiber and awaits upstream cleanup.
  Stream<A> toNative(Runtime<R> runtime) {
    late StreamController<A> controller;
    Fiber<Unit, E>? fiber;
    Deferred<Unit, Never>? paused;
    var cancelled = false;
    controller = StreamController<A>(
      sync: true,
      onPause: () {
        paused ??= Deferred();
      },
      onResume: () {
        paused?.succeed(Unit.value);
        paused = null;
      },
      onCancel: () async {
        cancelled = true;
        await fiber?.interruptAndAwait();
      },
      onListen: () {
        try {
          fiber = runtime.fork(
            runForEach(
              (a) => Effect.asyncExit((ctx) async {
                final gate = paused;
                if (gate != null) {
                  final exit = await ctx.evaluate(gate.awaitValue<R>());
                  if (exit is Failure<Unit, Never>) {
                    return Failure(_restore<E>(exit.cause));
                  }
                }
                if (cancelled) return const Failure(Interrupted());
                controller.add(a);
                return const Success(Unit.value);
              }),
            ),
          );
          unawaited(
            fiber!.awaitExit().then((exit) async {
              if (exit is Failure<Unit, E> && !cancelled) {
                controller.addError(EffectException(exit.cause));
              }
              await controller.close();
            }),
          );
        } catch (e, s) {
          controller.addError(e, s);
          unawaited(controller.close());
        }
      },
    );
    return controller.stream;
  }
}

Cause<E> _channelCause<E>(Cause<QueueClosed> cause) => switch (cause) {
  Expected() || Interrupted() => const Interrupted(),
  Defect(:final error, :final stackTrace) => Defect(error, stackTrace),
  Sequential(:final first, :final second) => Sequential(
    _channelCause(first),
    _channelCause(second),
  ),
};
Cause<E> _restore<E>(Cause<Object?> cause) => switch (cause) {
  Expected(:final error) =>
    error is E
        ? Expected(error)
        : Defect(
            StateError('Foreign stream finalizer error: $error'),
            StackTrace.current,
          ),
  Defect(:final error, :final stackTrace) => Defect(error, stackTrace),
  Interrupted() => const Interrupted(),
  Sequential(:final first, :final second) => Sequential(
    _restore(first),
    _restore(second),
  ),
};
Exit<A, E> _append<A, E>(Exit<A, E> body, Cause<E> cause) =>
    Failure(body is Failure<A, E> ? Sequential(body.cause, cause) : cause);
