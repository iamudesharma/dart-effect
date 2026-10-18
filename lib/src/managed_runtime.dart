import 'dart:async';

import 'core.dart';
import 'services.dart';

/// Owns one Layer graph across requests. Close interrupts requests before services.
final class ManagedRuntime<E> {
  ManagedRuntime._(this._runtime, this._owner, this._release);
  final Runtime<Context> _runtime;
  final Fiber<Unit, E> _owner;
  final Completer<void> _release;
  Future<Exit<Unit, E>>? _closing;
  static Future<Exit<ManagedRuntime<E>, E>> fromLayer<E>(
    Layer<E> layer, {
    Context? context,
    Clock? clock,
  }) async {
    final bootstrap = Runtime(context ?? Context(), clock: clock);
    final ready = Completer<Exit<Context, E>>(), release = Completer<void>();
    final owner = bootstrap.fork(
      layer.use(
        Effect.asyncExit<Unit, E, Context>((ctx) async {
          ready.complete(Success(ctx.environment));
          await release.future;
          return const Success(Unit.value);
        }),
      ),
    );
    unawaited(
      owner.awaitExit().then((exit) {
        if (!ready.isCompleted) {
          ready.complete(
            exit is Failure<Unit, E>
                ? Failure(exit.cause)
                : Failure(
                    Defect(
                      StateError('Layer owner ended before initialization'),
                      StackTrace.current,
                    ),
                  ),
          );
        }
      }),
    );
    final initialized = await ready.future;
    if (initialized is Failure<Context, E>) {
      await bootstrap.shutdown();
      return Failure(initialized.cause);
    }
    final managed = ManagedRuntime<E>._(
      Runtime((initialized as Success<Context, E>).value, clock: clock),
      owner,
      release,
    );
    // Owner's runtime must remain reachable until its lifetime completes.
    unawaited(owner.awaitExit().then((_) => bootstrap.shutdown()));
    return Success(managed);
  }

  Future<Exit<A, E>> runExit<A>(Effect<A, E, Context> effect) {
    if (_closing != null) throw StateError('Managed runtime is closed');
    return _runtime.runExit(effect);
  }

  Future<A> runFuture<A>(Effect<A, E, Context> effect) async {
    final result = await runExit(effect);
    if (result is Success<A, E>) return result.value;
    throw EffectException((result as Failure<A, E>).cause);
  }

  /// Idempotent; failures of service release are observable in the returned Exit.
  Future<Exit<Unit, E>> close() => _closing ??= Future(() async {
    await _runtime.shutdown();
    _release.complete();
    return _owner.awaitExit();
  });
}
