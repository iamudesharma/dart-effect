import 'dart:async';

/// The environment of an effect with all dependencies supplied.
final class Unit {
  const Unit._();
  static const value = Unit._();
}

/// Expected errors, stack-traced defects, interruption, or ordered combinations.
sealed class Cause<E> {
  const Cause();
}

final class Expected<E> extends Cause<E> {
  const Expected(this.error);
  final E error;
}

final class Defect<E> extends Cause<E> {
  const Defect(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

final class Interrupted<E> extends Cause<E> {
  const Interrupted();
}

final class Sequential<E> extends Cause<E> {
  const Sequential(this.first, this.second);
  final Cause<E> first;
  final Cause<E> second;
}

/// The observable outcome after a fiber's children and resources are cleaned up.
sealed class Exit<A, E> {
  const Exit();
}

final class Success<A, E> extends Exit<A, E> {
  const Success(this.value);
  final A value;
}

final class Failure<A, E> extends Exit<A, E> {
  const Failure(this.cause);
  final Cause<E> cause;
}

final class EffectException<E> implements Exception {
  const EffectException(this.cause);
  final Cause<E> cause;
  @override
  String toString() => 'EffectException($cause)';
}

/// An idempotent cooperative signal. It cannot stop CPU loops or arbitrary I/O.
final class CancellationToken {
  final _cancelled = Completer<void>();
  final _listeners = <void Function()>{};

  /// Register a synchronous notification and return a function to detach it.
  /// Notifications must not throw; adapter abort hooks belong on fromFuture.
  void Function() onCancel(void Function() listener) {
    if (isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () {
      _listeners.remove(listener);
    };
  }

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) {
      _cancelled.complete();
      final listeners = List<void Function()>.of(_listeners);
      _listeners.clear();
      for (final listener in listeners) {
        listener();
      }
    }
  }
}

/// Injectable time source; sleep must stop waiting when its token is cancelled.
abstract interface class Clock {
  DateTime get now;
  Future<void> sleep(Duration duration, CancellationToken token);
}

final class RealClock implements Clock {
  const RealClock();
  @override
  DateTime get now => DateTime.now();
  @override
  Future<void> sleep(Duration duration, CancellationToken token) async {
    if (token.isCancelled) return;
    final done = Completer<void>();
    final timer = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    final detach = token.onCancel(() {
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      detach();
      timer.cancel();
    }
  }
}

/// Manual time, with no wall-clock delays. Advance after sleepers register.
final class TestClock implements Clock {
  TestClock([DateTime? initial]) : _now = initial ?? DateTime.utc(2000);
  DateTime _now;
  final _sleepers = <_Sleeper>[];
  @override
  DateTime get now => _now;
  int get pendingSleeps => _sleepers.length;
  @override
  Future<void> sleep(Duration duration, CancellationToken token) async {
    if (token.isCancelled || duration <= Duration.zero) return;
    final sleeper = _Sleeper(_now.add(duration));
    _sleepers.add(sleeper);
    final detach = token.onCancel(() {
      if (!sleeper.done.isCompleted) sleeper.done.complete();
    });
    try {
      await sleeper.done.future;
    } finally {
      detach();
      _sleepers.remove(sleeper);
    }
  }

  void advance(Duration duration) {
    if (duration.isNegative) throw ArgumentError.value(duration);
    _now = _now.add(duration);
    for (final s in List<_Sleeper>.of(_sleepers)) {
      if (!s.at.isAfter(_now)) {
        _sleepers.remove(s);
        s.done.complete();
      }
    }
  }
}

final class _Sleeper {
  _Sleeper(this.at);
  final DateTime at;
  final done = Completer<void>();
}

final class LogRecord {
  LogRecord(
    this.timestamp,
    this.level,
    this.message, [
    Map<String, Object?> fields = const {},
  ]) : fields = Map.unmodifiable(fields);
  final DateTime timestamp;
  final String level;
  final String message;
  final Map<String, Object?> fields;
}

typedef LogSink = void Function(LogRecord);
void _discardLog(LogRecord record) {}

/// Finalizers run once in reverse registration order, after scoped children.
final class Scope {
  final _finalizers = <FutureOr<Cause<Object?>?> Function()>[];
  final _children = <Fiber<Object?, Object?>>{};
  Future<Cause<Object?>?>? _closed;
  void addFinalizer(FutureOr<Cause<Object?>?> Function() finalizer) {
    if (_closed != null) throw StateError('Scope is closed');
    _finalizers.add(finalizer);
  }

  Future<Cause<Object?>?> close() =>
      _closed ??= Future<Cause<Object?>?>.microtask(_close);
  Future<Cause<Object?>?> _close() async {
    for (final child in List<Fiber<Object?, Object?>>.of(_children)) {
      child.interrupt();
    }
    for (final child in List<Fiber<Object?, Object?>>.of(_children)) {
      await child.awaitExit();
    }
    Cause<Object?>? cause;
    while (_finalizers.isNotEmpty) {
      Cause<Object?>? next;
      try {
        next = await _finalizers.removeLast()();
      } catch (e, s) {
        next = Defect(e, s);
      }
      if (next != null) cause = cause == null ? next : Sequential(cause, next);
    }
    return cause;
  }
}

/// Extension boundary for services and adapters. Custom waits must cooperate
/// with [token], or evaluate [Effect.fromFuture] to gain interruption handling.
final class FiberContext<R> {
  FiberContext._(
    this.environment,
    this.token,
    this.clock,
    this.scope,
    this.runtime,
    this.logger,
    this._children,
    this._masked,
  );
  final R environment;
  final CancellationToken token;
  final Clock clock;
  final Scope scope;
  final Runtime<Object?> runtime;
  final LogSink logger;
  final Set<Fiber<Object?, Object?>> _children;
  final bool _masked;

  /// Protect acquisition/cleanup, including direct token-aware adapter waits.
  FiberContext<R> masked() => FiberContext._(
    environment,
    CancellationToken(),
    clock,
    scope,
    runtime,
    logger,
    _children,
    true,
  );
  FiberContext<S> withEnvironment<S>(S environment) => FiberContext._(
    environment,
    token,
    clock,
    scope,
    runtime,
    logger,
    _children,
    _masked,
  );
  FiberContext<R> withScope(Scope scope) => FiberContext._(
    environment,
    token,
    clock,
    scope,
    runtime,
    logger,
    _children,
    _masked,
  );
  Future<Exit<A, E>> evaluate<A, E>(Effect<A, E, R> effect) async =>
      _typedExit<A, E>(await _interpret(effect._node, this));
  Future<Exit<A, E>> _wait<A, E>(
    Future<Exit<A, E>> future, [
    FutureOr<void> Function()? onCancel,
  ]) async {
    if (_masked) return future;
    final interrupted = Completer<Exit<A, E>>();
    final detach = token.onCancel(() {
      interrupted.complete(const Failure(Interrupted()));
    });
    late Exit<A, E> result;
    try {
      result = await Future.any<Exit<A, E>>([future, interrupted.future]);
    } finally {
      detach();
    }
    if (result is Failure<A, E> && result.cause is Interrupted<E>) {
      try {
        await onCancel?.call();
      } catch (e, s) {
        return Failure(Sequential(const Interrupted(), Defect(e, s)));
      }
    }
    return result;
  }

  Fiber<A, E> _fork<A, E>(Effect<A, E, R> effect, bool scoped) {
    if (scoped && scope._closed != null) {
      throw StateError('Cannot fork a child into a closed scope');
    }
    final child = runtime._start(effect, environment);
    final detach = _masked ? () {} : token.onCancel(child.interrupt);
    _children.add(child);
    if (scoped) scope._children.add(child);
    unawaited(
      child.awaitExit().then((_) {
        detach();
        _children.remove(child);
        scope._children.remove(child);
      }),
    );
    return child;
  }
}

/// A running same-isolate computation. Awaiting its Exit includes cleanup.
final class Fiber<A, E> {
  Fiber._(this._token, this._result);
  final CancellationToken _token;
  final Future<Exit<A, E>> _result;
  void interrupt() => _token.cancel();
  Future<Exit<A, E>> awaitExit() => _result;

  /// Signal cancellation and wait for protected cleanup; may wait indefinitely
  /// if acquisition, finalization, or custom noncooperative work never completes.
  Future<Exit<A, E>> interruptAndAwait() {
    interrupt();
    return _result;
  }

  Effect<A, E, R> join<R>() => Effect.asyncExit((ctx) => ctx._wait(_result));
}

/// Supplies an environment, clock and logger, and owns all externally forked
/// roots. Shutdown rejects new roots and awaits existing roots' cleanup.
final class Runtime<R> {
  Runtime(
    this.environment, {
    Clock? clock,
    LogSink? logger,
    this.yieldEvery = 1024,
  }) : clock = clock ?? const RealClock(),
       logger = logger ?? _discardLog {
    if (yieldEvery < 1) throw ArgumentError.value(yieldEvery);
  }
  final R environment;
  final Clock clock;
  final LogSink logger;
  final int yieldEvery;
  bool _shutdown = false;
  final _roots = <Fiber<Object?, Object?>>{};
  Fiber<A, E> _start<A, E, S>(Effect<A, E, S> effect, S environment) {
    final token = CancellationToken();
    final scope = Scope();
    final children = <Fiber<Object?, Object?>>{};
    final ctx = FiberContext._(
      environment,
      token,
      clock,
      scope,
      this,
      logger,
      children,
      false,
    );
    final result = Future<Exit<A, E>>(() async {
      late Exit<A, E> exit;
      try {
        exit = await ctx.evaluate(effect);
      } catch (error, stack) {
        exit = Failure(Defect(error, stack));
      }
      Future<void> finishChildren() async {
        while (children.isNotEmpty) {
          final active = List<Fiber<Object?, Object?>>.of(children);
          for (final child in active) {
            child.interrupt();
          }
          for (final child in active) {
            await child.awaitExit();
          }
        }
      }

      await finishChildren();
      final cleanup = await scope.close();
      // Low-level finalizers may start explicitly joined cleanup fibers. A
      // custom finalizer that forgets to join cannot leave them running.
      await finishChildren();
      if (cleanup != null) exit = _append(exit, _castCause<E>(cleanup));
      return exit;
    });
    return Fiber._(token, result);
  }

  Fiber<A, E> fork<A, E>(Effect<A, E, R> effect) {
    if (_shutdown) throw StateError('Runtime is shut down');
    final fiber = _start(effect, environment);
    _roots.add(fiber);
    unawaited(
      fiber.awaitExit().then((_) {
        _roots.remove(fiber);
      }),
    );
    return fiber;
  }

  Future<Exit<A, E>> runExit<A, E>(Effect<A, E, R> effect) =>
      fork(effect).awaitExit();
  Future<A> runFuture<A, E>(Effect<A, E, R> effect) async {
    final exit = await runExit(effect);
    if (exit is Success<A, E>) return exit.value;
    throw EffectException((exit as Failure<A, E>).cause);
  }

  Future<void> shutdown() async {
    _shutdown = true;
    final roots = List<Fiber<Object?, Object?>>.of(_roots);
    for (final fiber in roots) {
      fiber.interrupt();
    }
    for (final fiber in roots) {
      await fiber.awaitExit();
    }
  }
}

// Existential node storage stays private. Typed public constructors preserve A/E/R;
// the interpreter checks erased values only when reconstructing the typed Exit.
sealed class _Node {}

final class _Leaf extends _Node {
  _Leaf(this.run);
  final FutureOr<Exit<Object?, Object?>> Function(FiberContext<Object?>) run;
}

final class _Bind extends _Node {
  _Bind(this.source, this.next);
  final _Node source;
  final _Node Function(Object?) next;
}

final class _Recover extends _Node {
  _Recover(this.source, this.next);
  final _Node source;
  final _Node Function(Object?) next;
}

final class _Frame {
  _Frame(this.next, this.recover);
  final _Node Function(Object?) next;
  final bool recover;
}

Cause<E> _castCause<E>(Cause<Object?> c) => switch (c) {
  Expected() =>
    c.error is E
        ? Expected(c.error as E)
        : Defect(
            StateError('Finalizer error outside expected family: ${c.error}'),
            StackTrace.current,
          ),
  Defect() => Defect(c.error, c.stackTrace),
  Interrupted() => const Interrupted(),
  Sequential() => Sequential(_castCause<E>(c.first), _castCause<E>(c.second)),
};
Exit<A, E> _typedExit<A, E>(Exit<Object?, Object?> e) =>
    e is Success<Object?, Object?>
    ? Success(e.value as A)
    : Failure(_castCause<E>((e as Failure<Object?, Object?>).cause));
Exit<A, E> _append<A, E>(Exit<A, E> exit, Cause<E> cleanup) =>
    Failure(exit is Failure<A, E> ? Sequential(exit.cause, cleanup) : cleanup);
Future<Exit<Object?, Object?>> _interpret(
  _Node node,
  FiberContext<Object?> ctx,
) async {
  final stack = <_Frame>[];
  var ticks = 0;
  while (true) {
    if (++ticks >= ctx.runtime.yieldEvery) {
      ticks = 0;
      await Future<void>.delayed(Duration.zero);
    }
    Exit<Object?, Object?> exit;
    if (ctx.token.isCancelled && !ctx._masked) {
      exit = const Failure(Interrupted());
    } else if (node is _Bind) {
      stack.add(_Frame(node.next, false));
      node = node.source;
      continue;
    } else if (node is _Recover) {
      stack.add(_Frame(node.next, true));
      node = node.source;
      continue;
    } else {
      try {
        exit = await (node as _Leaf).run(ctx);
        if (exit is Success<Object?, Object?> &&
            ctx.token.isCancelled &&
            !ctx._masked) {
          exit = const Failure(Interrupted());
        }
      } catch (e, s) {
        exit = Failure(Defect(e, s));
      }
    }
    var resumed = false;
    while (stack.isNotEmpty) {
      if (++ticks >= ctx.runtime.yieldEvery) {
        ticks = 0;
        await Future<void>.delayed(Duration.zero);
      }
      final frame = stack.removeLast();
      try {
        if (exit is Success<Object?, Object?> && !frame.recover) {
          node = frame.next(exit.value);
          resumed = true;
          break;
        }
        if (exit is Failure<Object?, Object?> &&
            exit.cause is Expected<Object?> &&
            frame.recover) {
          node = frame.next((exit.cause as Expected<Object?>).error);
          resumed = true;
          break;
        }
      } catch (e, s) {
        exit = Failure(Defect(e, s));
      }
    }
    if (!resumed) return exit;
  }
}

/// Lazy reusable computation. [E] should be a shared sealed error family.
/// [R] describes its environment; Dart covariance allows widening R, so it is
/// not complete static provision evidence. Incorrect widened provision defects.
/// Ordinary map/flatMap/defer chains use a stack-safe instruction interpreter.
final class Effect<A, E, R> {
  const Effect._(this._node);
  final _Node _node;

  /// Advanced cooperative extension. No automatic race is placed around this
  /// callback: doing so could skip its resource cleanup. Prefer [fromFuture]
  /// for plain asynchronous work or evaluate interruptible effects in context.
  static Effect<A, E, R> asyncExit<A, E, R>(
    FutureOr<Exit<A, E>> Function(FiberContext<R>) run,
  ) => Effect._(_Leaf((ctx) => run(ctx.withEnvironment(ctx.environment as R))));
  static Effect<A, E, R> succeed<A, E, R>(A value) =>
      asyncExit((_) => Success(value));
  static Effect<A, E, R> fail<A, E, R>(E error) =>
      asyncExit((_) => Failure(Expected(error)));
  static Effect<A, E, R> sync<A, E, R>(A Function() run) =>
      asyncExit((_) => Success(run()));
  static Effect<A, E, R> defer<A, E, R>(Effect<A, E, R> Function() run) =>
      Effect._(_Bind(_Leaf((_) => const Success(null)), (_) => run()._node));

  /// Invoke a fresh Future factory on each run. Rejections are defects unless
  /// [onError] explicitly maps them to E. Interruption ignores late completion
  /// and awaits [onCancel]; without a hook the underlying I/O may continue.
  /// Allocate per-run abort state with [defer] when runs can overlap.
  static Effect<A, E, R> fromFuture<A, E, R>(
    Future<A> Function() run, {
    E Function(Object, StackTrace)? onError,
    FutureOr<void> Function()? onCancel,
  }) => asyncExit((ctx) {
    final future = Future<A>.sync(run).then<Exit<A, E>>(
      (a) => Success(a),
      onError: (Object e, StackTrace s) => onError == null
          ? Failure<A, E>(Defect(e, s))
          : Failure<A, E>(Expected(onError(e, s))),
    );
    return ctx._wait(future, onCancel);
  });
  static Effect<A, E, R> environment<A, E, R>(A Function(R) select) =>
      asyncExit((ctx) => Success(select(ctx.environment)));
  Effect<B, E, R> map<B>(B Function(A) f) =>
      flatMap((a) => Effect.sync(() => f(a)));
  Effect<B, E, R> flatMap<B>(Effect<B, E, R> Function(A) f) =>
      Effect._(_Bind(_node, (value) => f(value as A)._node));

  /// Recover only a standalone expected failure; defects, interruption and
  /// combined causes pass through unchanged.
  Effect<A, E, R> catchAll(Effect<A, E, R> Function(E) f) =>
      Effect._(_Recover(_node, (error) => f(error as E)._node));
  Effect<A, E2, R> mapError<E2>(E2 Function(E) f) => asyncExit((ctx) async {
    final exit = await ctx.evaluate(this);
    Cause<E2> convert(Cause<E> c) => switch (c) {
      Expected() => Expected(f(c.error)),
      Defect() => Defect(c.error, c.stackTrace),
      Interrupted() => const Interrupted(),
      Sequential() => Sequential(convert(c.first), convert(c.second)),
    };
    return exit is Success<A, E>
        ? Success(exit.value)
        : Failure(convert((exit as Failure<A, E>).cause));
  });
  Effect<A, E, Unit> provide(R environment) =>
      asyncExit((ctx) => ctx.withEnvironment(environment).evaluate(this));
  Effect<A, E, R> ensuring(Effect<Object?, E, R> finalizer) => asyncExit((
    ctx,
  ) async {
    Exit<A, E> body;
    try {
      body = await ctx.evaluate(this);
    } catch (e, s) {
      body = Failure(Defect(e, s));
    }
    final cleanup = await ctx.masked().evaluate(finalizer);
    return cleanup is Failure<Object?, E> ? _append(body, cleanup.cause) : body;
  });

  /// Create a local scope and await scoped children and LIFO finalizers.
  Effect<A, E, R> scoped() => asyncExit((ctx) async {
    final scope = Scope();
    final body = await ctx.withScope(scope).evaluate(this);
    final cause = await scope.close();
    return cause == null ? body : _append(body, _castCause<E>(cause));
  });

  /// Protected acquisition/release around interruptible use, in a local scope.
  /// Scoped children end before release. Cleanup failures follow body failures
  /// in a [Sequential] cause; every successful acquisition releases once.
  static Effect<B, E, R> acquireUseRelease<A, B, E, R>(
    Effect<A, E, R> acquire,
    Effect<B, E, R> Function(A) use,
    Effect<Object?, E, R> Function(A, Exit<B, E>) release,
  ) => asyncExit((ctx) async {
    final scope = Scope();
    final local = ctx.withScope(scope);
    final acquired = await local.masked().evaluate(acquire);
    if (acquired is Failure<A, E>) {
      final cleanup = await scope.close();
      final failed = Failure<B, E>(acquired.cause);
      return cleanup == null ? failed : _append(failed, _castCause<E>(cleanup));
    }
    final a = (acquired as Success<A, E>).value;
    Exit<B, E> body = const Failure(Interrupted());
    scope.addFinalizer(() async {
      final cleanup = await local.masked().evaluate(release(a, body));
      return cleanup is Failure<Object?, E> ? cleanup.cause : null;
    });
    try {
      body = await local.evaluate(use(a));
    } catch (e, s) {
      body = Failure(Defect(e, s));
    }
    final cleanup = await scope.close();
    return cleanup == null ? body : _append(body, _castCause<E>(cleanup));
  });

  /// Fork a child owned by the current parent fiber.
  Effect<Fiber<A, E>, E, R> fork() =>
      asyncExit((ctx) => Success(ctx._fork(this, false)));

  /// Fork a child bounded by both current parent and enclosing scope.
  /// This is intentionally narrower than upstream scope-only longevity.
  Effect<Fiber<A, E>, E, R> forkScoped() =>
      asyncExit((ctx) => Success(ctx._fork(this, true)));
  static Effect<Unit, E, R> sleep<E, R>(Duration duration) =>
      asyncExit((ctx) async {
        final token = ctx._masked ? CancellationToken() : ctx.token;
        await ctx.clock.sleep(duration, token);
        return token.isCancelled
            ? const Failure(Interrupted())
            : const Success(Unit.value);
      });

  /// Interrupt and await the worker before reporting a caller-supplied error.
  /// Protected cleanup can extend elapsed time beyond the requested duration.
  Effect<A, E, R> timeout(Duration duration, E Function() onTimeout) =>
      asyncExit((ctx) async {
        final worker = ctx._fork(this, false);
        final timer = ctx._fork(Effect.sleep<E, R>(duration), false);
        final first = await Future.any<(bool, Exit<Object?, E>)>([
          worker.awaitExit().then((exit) => (true, exit)),
          timer.awaitExit().then((exit) => (false, exit)),
        ]);
        if (first.$1) {
          await timer.interruptAndAwait();
          return first.$2 as Exit<A, E>;
        }
        await worker.interruptAndAwait();
        if (first.$2 case Failure<Object?, E>(:final cause)) {
          return Failure(cause);
        }
        return ctx.token.isCancelled
            ? const Failure(Interrupted())
            : Failure(Expected(onTimeout()));
      });

  /// First success wins; after an initial failure wait for the other branch.
  /// Await loser cleanup before returning. Loser failures are available on its
  /// fiber but do not replace a successful winner.
  Effect<A, E, R> race(Effect<A, E, R> other) => asyncExit((ctx) async {
    final left = ctx._fork(this, false), right = ctx._fork(other, false);
    final first = await Future.any([
      (left.awaitExit().then((e) => (true, e))),
      (right.awaitExit().then((e) => (false, e))),
    ]);
    final loser = first.$1 ? right : left;
    if (first.$2 is Success<A, E>) {
      await loser.interruptAndAwait();
      return first.$2;
    }
    final second = await loser.awaitExit();
    if (second is Success<A, E>) return second;
    return Failure(
      Sequential(
        (first.$2 as Failure<A, E>).cause,
        (second as Failure<A, E>).cause,
      ),
    );
  });

  /// Process with a positive concurrency bound and stable input result order.
  /// On failure, interrupt and await active siblings; do not start later work.
  static Effect<List<B>, E, R> traverse<A, B, E, R>(
    Iterable<A> values,
    Effect<B, E, R> Function(A) f, {
    int concurrency = 1,
  }) {
    if (concurrency < 1) throw ArgumentError.value(concurrency);
    return asyncExit((ctx) async {
      final inputs = values.toList();
      final results = List<B?>.filled(inputs.length, null);
      final active = <Fiber<B, E>>{};
      Cause<E>? failure;
      var next = 0;
      Future<void> worker() async {
        while (failure == null && next < inputs.length) {
          final index = next++;
          Fiber<B, E> fiber;
          try {
            fiber = ctx._fork(f(inputs[index]), false);
          } catch (e, s) {
            failure = Defect(e, s);
            for (final sibling in active) {
              sibling.interrupt();
            }
            return;
          }
          active.add(fiber);
          final exit = await fiber.awaitExit();
          active.remove(fiber);
          if (exit is Success<B, E>) {
            results[index] = exit.value;
          } else {
            failure ??= (exit as Failure<B, E>).cause;
            for (final sibling in active) {
              sibling.interrupt();
            }
          }
        }
      }

      await Future.wait(
        List.generate(
          inputs.length < concurrency ? inputs.length : concurrency,
          (_) => worker(),
        ),
      );
      return failure == null ? Success(results.cast<B>()) : Failure(failure!);
    });
  }
}
