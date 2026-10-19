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
