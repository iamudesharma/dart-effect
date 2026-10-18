/// Deterministic testing helpers. This is a development dependency only.
library;

import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

Runtime<R> testRuntime<R>(
  R environment, {
  Clock? clock,
  LogSink? logger,
  LifecycleSink? lifecycle,
}) {
  final runtime = Runtime(
    environment,
    clock: clock,
    logger: logger,
    lifecycle: lifecycle,
  );
  addTearDown(runtime.shutdown);
  return runtime;
}

final class CapturedLogs {
  final _records = <LogRecord>[];
  List<LogRecord> get records => List.unmodifiable(_records);
  void call(LogRecord record) => _records.add(record);
}

Matcher expectedFailure<E>(Matcher error) => isA<Failure<Object?, E>>().having(
  (exit) => exit.cause,
  'cause',
  isA<Expected<E>>().having((cause) => cause.error, 'error', error),
);

/// Wait for an observable suspension condition, never an arbitrary long delay.
Future<void> awaitCondition(bool Function() ready, {int turns = 1000}) async {
  for (var i = 0; i < turns; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Suspension condition not reached after $turns event turns');
}

Future<void> advanceWhenSleeping(
  TestClock clock,
  Duration duration, {
  int sleepers = 1,
}) async {
  await awaitCondition(() => clock.pendingSleeps >= sleepers);
  clock.advance(duration);
  await Future<void>.delayed(Duration.zero);
}
