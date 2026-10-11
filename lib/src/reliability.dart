import 'core.dart';

/// A snapshot of a circuit's admission state.
enum CircuitState { closed, open, halfOpen }

/// Single-isolate circuit breaker. Only selected expected errors count.
/// A single probe is admitted after cooldown; cancellation releases the probe.
final class CircuitBreaker {
  CircuitBreaker({
    this.failureThreshold = 5,
    this.resetAfter = const Duration(seconds: 30),
  }) {
    if (failureThreshold < 1 || resetAfter.isNegative) {
      throw ArgumentError('Invalid breaker');
    }
  }
  final int failureThreshold;
  final Duration resetAfter;
  int _failures = 0, _generation = 0;
  DateTime? _opened;
  bool _probe = false;
  CircuitState get state => _probe
      ? CircuitState.halfOpen
      : _opened != null
      ? CircuitState.open
      : CircuitState.closed;

  Effect<A, E, R> protect<A, E, R>(
    Effect<A, E, R> effect, {
    required E Function() onOpen,
    bool Function(E)? countsAsFailure,
  }) => Effect.asyncExit((ctx) async {
    final opened = _opened;
    final probe = opened != null;
    if (probe && (_probe || ctx.clock.now.difference(opened) < resetAfter)) {
      return Failure(Expected(onOpen()));
    }
    if (probe) _probe = true;
    final generation = _generation;
    try {
      final exit = await ctx.evaluate(effect);
      if (generation != _generation) return exit;
      final failed =
          exit is Failure<A, E> &&
          exit.cause is Expected<E> &&
          (countsAsFailure?.call((exit.cause as Expected<E>).error) ?? true);
      if (failed) {
        if (probe || ++_failures >= failureThreshold) {
          _opened = ctx.clock.now;
          _generation++;
        }
      } else if (exit is Success<A, E>) {
        _failures = 0;
        if (probe) {
          _opened = null;
          _generation++;
        }
      }
      return exit;
    } finally {
      if (probe) _probe = false;
    }
  });
}

/// Spaces admissions with the injected clock. A cancelled reservation leaves
/// an unused slot, preventing bursts. No tasks or timers are retained by helper.
final class RateLimiter {
  RateLimiter(this.interval) {
    if (interval.isNegative) throw ArgumentError.value(interval);
  }
  final Duration interval;
  DateTime? _next;
  Effect<A, E, R> limit<A, E, R>(Effect<A, E, R> effect) => Effect.asyncExit((
    ctx,
  ) async {
    final now = ctx.clock.now;
    final next = _next;
    final slot = next != null && next.isAfter(now) ? next : now;
    _next = slot.add(interval);
    final wait = await ctx.evaluate(Effect.sleep<E, R>(slot.difference(now)));
    if (wait is Failure<Unit, E>) return Failure(wait.cause);
    return ctx.evaluate(effect);
  });
}
