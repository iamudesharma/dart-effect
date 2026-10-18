import 'core.dart';

extension CauseDiagnostics<E> on Cause<E> {
  Iterable<E> get expectedErrors sync* {
    final pending = <Cause<E>>[this];
    while (pending.isNotEmpty) {
      final cause = pending.removeLast();
      switch (cause) {
        case Expected(:final error):
          yield error;
        case Sequential(:final first, :final second):
          pending.addAll([second, first]);
        default:
          break;
      }
    }
  }

  Iterable<Defect<E>> get defects sync* {
    final pending = <Cause<E>>[this];
    while (pending.isNotEmpty) {
      final cause = pending.removeLast();
      switch (cause) {
        case Defect<E>():
          yield cause;
        case Sequential(:final first, :final second):
          pending.addAll([second, first]);
        default:
          break;
      }
    }
  }

  bool get isInterrupted {
    final pending = <Cause<E>>[this];
    while (pending.isNotEmpty) {
      final cause = pending.removeLast();
      if (cause is Interrupted<E>) return true;
      if (cause is Sequential<E>) pending.addAll([cause.first, cause.second]);
    }
    return false;
  }
}

extension EffectComposition<A, E, R> on Effect<A, E, R> {
  Effect<A, E, R> tap(Effect<Object?, E, R> Function(A) observe) =>
      flatMap((a) => observe(a).map((_) => a));
  Effect<B, E, R> asValue<B>(B value) => map((_) => value);
  Effect<Unit, E, R> get asUnit => asValue(Unit.value);
  Effect<(A, B), E, R> zip<B>(Effect<B, E, R> other) =>
      flatMap((a) => other.map((b) => (a, b)));
  Effect<C, E, R> zipWith<B, C>(Effect<B, E, R> other, C Function(A, B) f) =>
      zip(other).map((pair) => f(pair.$1, pair.$2));
  Effect<A?, E, R> when(bool Function() condition) => Effect.defer(
    () => condition() ? map<A?>((a) => a) : Effect.succeed(null),
  );
  Effect<A?, E, R> unless(bool Function() condition) =>
      when(() => !condition());
  Effect<A, E, R> catchIf(
    bool Function(E) predicate,
    Effect<A, E, R> Function(E) recover,
  ) => catchAll(
    (error) => predicate(error) ? recover(error) : Effect.fail(error),
  );
  Effect<A, E, R> catchType<F extends E>(Effect<A, E, R> Function(F) recover) =>
      catchIf((e) => e is F, (e) => recover(e as F));

  /// Captures an evaluated Exit. Parent cancellation can still interrupt the capture.
  Effect<Exit<A, E>, Never, R> outcome() =>
      Effect.asyncExit((ctx) async => Success(await ctx.evaluate(this)));
  Effect<B, E, R> match<B>({
    required B Function(A) success,
    required B Function(E) failure,
  }) => map(success).catchAll((error) => Effect.succeed(failure(error)));
  Effect<A, E, R> filterOrFail(
    bool Function(A) predicate,
    E Function(A) error,
  ) => flatMap((a) => predicate(a) ? Effect.succeed(a) : Effect.fail(error(a)));
  Effect<A, E, R> onExit(Effect<Object?, E, R> Function(Exit<A, E>) observe) =>
      Effect.asyncExit((ctx) async {
        final exit = await ctx.evaluate(this);
        final observed = await ctx.masked().evaluate(
          Effect.defer(() => observe(exit)),
        );
        if (observed is Failure<Object?, E>) {
          return Failure(
            exit is Failure<A, E>
                ? Sequential(exit.cause, observed.cause)
                : observed.cause,
          );
        }
        return exit;
      });
  Effect<A, E, R> onError(Effect<Object?, E, R> Function(Cause<E>) observe) =>
      onExit(
        (exit) => exit is Failure<A, E>
            ? observe(exit.cause)
            : Effect.succeed(Unit.value),
      );
  Effect<A, E, R> onInterrupt(Effect<Object?, E, R> cleanup) => onError(
    (cause) => cause.isInterrupted ? cleanup : Effect.succeed(Unit.value),
  );

  /// First terminal outcome wins, unlike first-success race. Loser cleanup is awaited.
  Effect<A, E, R> raceFirst(Effect<A, E, R> other) => Effect.asyncExit((
    ctx,
  ) async {
    final l = await ctx.evaluate(fork()), r = await ctx.evaluate(other.fork());
    if (l is Failure<Fiber<A, E>, E>) return Failure(l.cause);
    if (r is Failure<Fiber<A, E>, E>) return Failure(r.cause);
    final left = (l as Success<Fiber<A, E>, E>).value,
        right = (r as Success<Fiber<A, E>, E>).value;
    final first = await Future.any([
      left.awaitExit().then((e) => (true, e)),
      right.awaitExit().then((e) => (false, e)),
    ]);
    final stopped = await (first.$1 ? right : left).interruptAndAwait();
    // Preserve loser diagnostics only for a failed winner; a successful winner
    // uses race's established successful-loser policy.
    if (first.$2 is Failure<A, E> &&
        stopped is Failure<A, E> &&
        stopped.cause is! Interrupted<E>) {
      return Failure(
        Sequential((first.$2 as Failure<A, E>).cause, stopped.cause),
      );
    }
    return first.$2;
  });
}

extension FlattenEffect<A, E, R> on Effect<Effect<A, E, R>, E, R> {
  Effect<A, E, R> flatten() => flatMap((e) => e);
}

extension ScopedAcquisition<A, E, R> on Effect<A, E, R> {
  /// Register release in the current scope before making the value interruptible.
  Effect<A, E, R> acquireScoped(Effect<Object?, E, R> Function(A) release) =>
      Effect.asyncExit((ctx) async {
        final protected = ctx.masked();
        final exit = await protected.evaluate(this);
        if (exit is Failure<A, E>) return exit;
        final value = (exit as Success<A, E>).value;
        ctx.scope.addFinalizer(() async {
          final closed = await protected.evaluate(
            Effect.defer(() => release(value)),
          );
          return closed is Failure<Object?, E> ? closed.cause : null;
        });
        return exit;
      });
}

/// Pure expected result, deliberately without defect/interruption variants.
sealed class Result<A, E> {
  const Result();
  B fold<B>(B Function(A) success, B Function(E) failure) => switch (this) {
    Ok(:final value) => success(value),
    Err(:final error) => failure(error),
  };
}

final class Ok<A, E> extends Result<A, E> {
  const Ok(this.value);
  final A value;
}

final class Err<A, E> extends Result<A, E> {
  const Err(this.error);
  final E error;
}

Effect<A, E, R> trySync<A, E, R>(
  A Function() run,
  E Function(Object, StackTrace) onError,
) => Effect.asyncExit((_) {
  try {
    return Success(run());
  } catch (error, stack) {
    return Failure(Expected(onError(error, stack)));
  }
});
