import 'dart:async';
import 'dart:math';

import 'core.dart';

/// An identity-based key. Equal names do not alias services.
final class ServiceKey<A> {
  ServiceKey(this.name);
  final String name;
  bool accepts(Object? value) => value is A;
  Context bind(A value) => Context().add<A>(this, value);
  Effect<A, E, Context> effect<E>() =>
      Effect.environment<A, E, Context>((context) => context.get(this));
  @override
  String toString() => 'ServiceKey($name)';
}

final class MissingService implements Exception {
  MissingService(this.name);
  final String name;
  @override
  String toString() => 'Missing service: $name';
}

/// Immutable heterogeneous services. Context requirements are checked at run
/// time; use an aggregate environment for static dependency evidence.
final class Context {
  Context() : _entries = const {};
  Context._(Map<Object, Object?> entries)
    : _entries = Map.unmodifiable(entries);
  final Map<Object, Object?> _entries;
  Context add<A>(ServiceKey<A> key, A value) {
    if (!key.accepts(value)) {
      throw ArgumentError('Invalid service for ${key.name}');
    }
    return Context._({..._entries, key: value});
  }

  Context merge(Context other) => Context._({..._entries, ...other._entries});
  bool contains<A>(ServiceKey<A> key) => _entries.containsKey(key);
  A get<A>(ServiceKey<A> key) {
    if (!_entries.containsKey(key)) throw MissingService(key.name);
    // Only add<A> can install a value for a ServiceKey<A>. The checked cast
    // stays at this single existential boundary; there is no dynamic API.
    return _entries[key] as A;
  }
}

final class LayerCycle implements Exception {
  LayerCycle(this.path);
  final List<String> path;
  @override
  String toString() => 'Layer dependency cycle: ${path.join(' -> ')}';
}

/// A graph node memoized by identity within the enclosing scope.
///
/// [build] borrows that scope: all acquired services live until it closes.
/// [use] creates and owns a scope for a complete service-using operation.
final class Layer<E> {
  Layer(
    this.create, {
    this.name = 'layer',
    List<Layer<E>> dependencies = const [],
  }) : dependencies = List.unmodifiable(dependencies),
       _deferred = null;
  Layer.suspend(Layer<E> Function() make, {this.name = 'suspended layer'})
    : _deferred = make,
      dependencies = const [],
      create = null;
  final String name;
  final Effect<Context, E, Context>? create;
  final List<Layer<E>> dependencies;
  final Layer<E> Function()? _deferred;
  static final Expando<_LayerBuild<Object?>> _builds = Expando('layer builds');

  static Layer<E> service<A, E>(ServiceKey<A> key, A value) => Layer(
    Effect.succeed<Context, E, Context>(Context().add(key, value)),
    name: key.name,
  );

  static Layer<E> resource<A, E>(
    ServiceKey<A> key,
    Effect<A, E, Context> acquire,
    Effect<Object?, E, Context> Function(A) release, {
    List<Layer<E>> dependencies = const [],
  }) => Layer(
    Effect.asyncExit<Context, E, Context>((context) async {
      final protected = context.masked();
      final exit = await protected.evaluate(acquire);
      if (exit case Failure<A, E>(:final cause)) return Failure(cause);
      final value = (exit as Success<A, E>).value;
      context.scope.addFinalizer(() async {
        final released = await protected.evaluate(release(value));
        return released is Failure<Object?, E> ? released.cause : null;
      });
      return Success(Context().add(key, value));
    }),
    name: key.name,
    dependencies: dependencies,
  );

  Effect<Context, E, Context> build() =>
      Effect.asyncExit<Context, E, Context>((context) async {
        var build = _builds[context.scope];
        if (build == null || build.closed) {
          build = _LayerBuild<Object?>(Scope());
          _builds[context.scope] = build;
          context.scope.addFinalizer(build.finish);
        }
        final exit = await build.node(
          this,
          context.withScope(build.scope),
          const [],
        );
        if (exit is Failure<Context, E>) {
          final cleanup = await build.finish();
          if (cleanup != null) {
            return Failure(Sequential(exit.cause, _restoreCause<E>(cleanup)));
          }
        } else if (build.closed) {
          await build.close();
          return Failure(
            Defect(
              StateError(
                'Layer build scope was invalidated by a concurrent failure',
              ),
              StackTrace.current,
            ),
          );
        }
        return exit;
      });

  Effect<A, E, Context> use<A>(Effect<A, E, Context> effect) => build()
      .flatMap(
        (services) => Effect.asyncExit<A, E, Context>(
          (context) => context
              .withEnvironment(context.environment.merge(services))
              .evaluate(effect),
        ),
      )
      .scoped();
}

final class _LayerBuild<E> {
  _LayerBuild(this.scope);
  final Scope scope;
  bool closed = false;
  final Map<Object, Future<Exit<Context, Object?>>> _memo = Map.identity();
  final Map<Object, Set<Object>> _edges = Map.identity();
  Future<Cause<Object?>?>? _closing;
  bool _cleanupReported = false;
  Future<Cause<Object?>?> finish() async {
    final cause = await close();
    if (_cleanupReported) return null;
    _cleanupReported = true;
    return cause;
  }

  Future<Cause<Object?>?> close() {
    closed = true;
    return _closing ??= Future<Cause<Object?>?>.microtask(() async {
      // A protected acquisition may still be in flight. It must register its
      // release before closure; otherwise closing a failed sibling would leak it.
      await Future.wait(_memo.values.toList());
      return scope.close();
    });
  }

  bool _reaches(Object from, Object target, Set<Object> visited) {
    if (identical(from, target)) return true;
    if (!visited.add(from)) return false;
    return (_edges[from] ?? {}).any((next) => _reaches(next, target, visited));
  }

  Future<Exit<Context, F>> node<F>(
    Layer<F> layer,
    FiberContext<Context> context,
    List<Layer<Object?>> path,
  ) async {
    var cycle = path.any((entry) => identical(entry, layer));
    if (path.isNotEmpty) {
      final parent = path.last;
      cycle |= _reaches(layer, parent, Set.identity());
      (_edges[parent] ??= Set.identity()).add(layer);
    }
    if (cycle) {
      return Failure(
        Defect(
          LayerCycle([...path.map((e) => e.name), layer.name]),
          StackTrace.current,
        ),
      );
    }
    final existing = _memo[layer];
    if (existing != null) return await existing as Exit<Context, F>;
    final completer = Completer<Exit<Context, Object?>>();
    _memo[layer] = completer.future;
    Exit<Context, F> result;
    try {
      final next = [...path, layer];
      if (layer._deferred != null) {
        result = await node(layer._deferred(), context, next);
      } else {
        var services = context.environment;
        Cause<F>? failed;
        for (final dependency in layer.dependencies) {
          final exit = await node(
            dependency,
            context.withEnvironment(services),
            next,
          );
          if (exit is Failure<Context, F>) {
            failed = exit.cause;
            break;
          }
          services = services.merge((exit as Success<Context, F>).value);
        }
        result = failed != null
            ? Failure(failed)
            : await context.withEnvironment(services).evaluate(layer.create!);
        if (result is Success<Context, F>) {
          result = Success(services.merge(result.value));
        }
      }
    } catch (error, stack) {
      result = Failure(Defect(error, stack));
    }
    completer.complete(result);
    return result;
  }
}

/// Finite policy: [recurrences] counts additional executions, not the first.
final class Schedule {
  Schedule({
    required this.recurrences,
    this.initialDelay = Duration.zero,
    this.factor = 1,
    this.jitter = 0,
    this.seed = 0,
  }) {
    if (recurrences < 0 ||
        initialDelay.isNegative ||
        !factor.isFinite ||
        factor < 1 ||
        !jitter.isFinite ||
        jitter < 0 ||
        jitter > 1) {
      throw ArgumentError('Invalid schedule');
    }
  }
  final int recurrences;
  final Duration initialDelay;
  final double factor;
  final double jitter;
  final int seed;
  Duration delay(int iteration, Random random) {
    if (iteration < 0) throw ArgumentError.value(iteration, 'iteration');
    if (initialDelay == Duration.zero) return Duration.zero;
    final multiplier = 1 - jitter + random.nextDouble() * 2 * jitter;
    if (multiplier == 0) return Duration.zero;
    final micros =
        initialDelay.inMicroseconds * pow(factor, iteration) * multiplier;
    return Duration(microseconds: min(micros, 9007199254740991).round());
  }
}

extension EffectPolicy<A, E, R> on Effect<A, E, R> {
  Effect<A, E, R> retry(Schedule schedule) => _scheduled(schedule, false);
  Effect<A, E, R> repeat(Schedule schedule) => _scheduled(schedule, true);
  Effect<A, E, R> _scheduled(Schedule schedule, bool repeat) =>
      Effect.asyncExit<A, E, R>((context) async {
        final random = Random(schedule.seed);
        for (var iteration = 0; ; iteration++) {
          final exit = await context.evaluate(this);
          final again = repeat
              ? exit is Success<A, E>
              : exit is Failure<A, E> && exit.cause is Expected<E>;
          if (!again || iteration >= schedule.recurrences) return exit;
          final sleep = await context.evaluate(
            Effect.sleep<E, R>(schedule.delay(iteration, random)),
          );
          if (sleep is Failure<Unit, E>) return Failure(sleep.cause);
        }
      });
}

/// Emit an immutable structured log through the runtime's injected sink.
Effect<Unit, E, R> log<E, R>(
  String message, {
  String level = 'info',
  Map<String, Object?> fields = const {},
}) => Effect.asyncExit<Unit, E, R>((context) {
  context.logger(
    LogRecord(context.clock.now, level, message, Map.unmodifiable(fields)),
  );
  return Success(Unit.value);
});

Cause<E> _restoreCause<E>(Cause<Object?> cause) => switch (cause) {
  Expected(:final error) =>
    error is E
        ? Expected<E>(error)
        : Defect<E>(
            StateError('Cleanup error outside expected family: $error'),
            StackTrace.current,
          ),
  Defect(:final error, :final stackTrace) => Defect<E>(error, stackTrace),
  Interrupted() => Interrupted<E>(),
  Sequential(:final first, :final second) => Sequential<E>(
    _restoreCause<E>(first),
    _restoreCause<E>(second),
  ),
};
