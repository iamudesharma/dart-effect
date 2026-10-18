/// Native-only configuration providers and explicit one-shot isolate work.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:effect_core/effect_core.dart';
import 'package:effect_config/effect_config.dart';

ConfigProvider environmentConfig({Map<String, String>? environment}) =>
    ConfigProvider(environment ?? Platform.environment, separator: '_');
Future<ConfigProvider> jsonFileConfig(File file) async {
  final text = await file.readAsString();
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw ConfigError(file.path, ConfigErrorKind.invalid, 'Invalid JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw ConfigError(
      file.path,
      ConfigErrorKind.invalid,
      'Expected JSON object',
    );
  }
  final out = <String, String>{};
  void flatten(Map<String, Object?> value, String prefix) {
    for (final entry in value.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      if (entry.value is Map<String, Object?>) {
        flatten(entry.value as Map<String, Object?>, key);
      } else if (entry.value is String ||
          entry.value is num ||
          entry.value is bool) {
        out[key] = entry.value.toString();
      } else {
        throw ConfigError(
          key,
          ConfigErrorKind.invalid,
          'Expected scalar or nested object',
        );
      }
    }
  }

  flatten(decoded, '');
  return ConfigProvider(out);
}

/// Values/closure must be isolate-sendable. This is hard isolate cancellation,
/// so finally blocks inside the worker are not guaranteed to execute. Do not
/// acquire application resources in a killable worker.
void _worker<A>((SendPort, A Function()) input) {
  try {
    input.$1.send((true, input.$2()));
  } catch (error, stack) {
    input.$1.send((false, error.toString(), stack.toString()));
  }
}

Effect<A, E, R> isolateTask<A, E, R>(
  A Function() compute, {
  required E Function(Object, StackTrace) onError,
}) => Effect.defer(() {
  ReceivePort? messages, errors;
  Isolate? isolate;
  var cancelled = false;
  Future<void> cancel() async {
    cancelled = true;
    isolate?.kill(priority: Isolate.immediate);
    messages?.close();
    errors?.close();
  }

  return Effect.fromFuture<A, E, R>(
    () async {
      final result = Completer<A>();
      messages = ReceivePort();
      errors = ReceivePort();
      errors!.listen((message) {
        if (!result.isCompleted) {
          result.completeError(
            RemoteError('Isolate failed', message.toString()),
            StackTrace.current,
          );
        }
      });
      messages!.listen((value) {
        if (result.isCompleted) return;
        if (value case (true, final Object? output)) {
          if (output is A) {
            result.complete(output);
          } else {
            result.completeError(StateError('Invalid worker result'));
          }
        } else if (value case (false, final String error, final String stack)) {
          result.completeError(
            RemoteError(error, stack),
            StackTrace.fromString(stack),
          );
        } else if (value == null) {
          result.completeError(StateError('Worker exited without a result'));
        }
      });
      try {
        isolate = await Isolate.spawn<(SendPort, A Function())>(
          _worker<A>,
          (messages!.sendPort, compute),
          onError: errors!.sendPort,
          onExit: messages!.sendPort,
          errorsAreFatal: true,
        );
        if (cancelled) isolate!.kill(priority: Isolate.immediate);
        return await result.future;
      } finally {
        await cancel();
      }
    },
    onError: onError,
    onCancel: cancel,
  );
});
