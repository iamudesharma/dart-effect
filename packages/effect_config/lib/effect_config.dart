/// Typed portable configuration with absence-aware defaults and redaction.
library;

import 'package:effect_core/effect_core.dart';

final class Redacted<T> {
  const Redacted(this._value);
  final T _value;
  T reveal() => _value;
  @override
  String toString() => '<redacted>';
}

enum ConfigErrorKind { missing, invalid }

final class ConfigError implements Exception {
  ConfigError(this.path, this.kind, this.message);
  final String path, message;
  final ConfigErrorKind kind;
  @override
  String toString() => 'ConfigError($path, ${kind.name}: $message)';
}

/// Null means absence; invalid supplied text is preserved for validation.
final class ConfigProvider {
  factory ConfigProvider(Map<String, String> values, {String separator = '.'}) {
    final snapshot = Map<String, String>.unmodifiable(values);
    return ConfigProvider._((key) => snapshot[key], separator);
  }
  ConfigProvider._(this._read, this.separator);
  final String? Function(String) _read;
  final String separator;
  String? read(List<String> path) => _read(path.join(separator));
  ConfigProvider fallback(ConfigProvider other) => ConfigProvider._(
    (key) => _read(key) ?? other.read(key.split(separator)),
    separator,
  );
  ConfigProvider nested(String prefix) =>
      ConfigProvider._((key) => _read('$prefix$separator$key'), separator);
}

final class Config<T> {
  Config._(this._load);
  final T Function(ConfigProvider) _load;
  T load(ConfigProvider provider) => _load(provider);
  Effect<T, ConfigError, ConfigProvider> effect() => Effect.asyncExit((ctx) {
    try {
      return Success(load(ctx.environment));
    } on ConfigError catch (error) {
      return Failure(Expected(error));
    }
  });
  Config<U> map<U>(U Function(T) f) => Config._((p) => f(load(p)));
  Config<T?> optional() => Config._((p) {
    try {
      return load(p);
    } on ConfigError catch (e) {
      if (e.kind == ConfigErrorKind.missing) return null;
      rethrow;
    }
  });
  Config<T> withDefault(T value) => Config._((p) {
    try {
      return load(p);
    } on ConfigError catch (e) {
      if (e.kind == ConfigErrorKind.missing) return value;
      rethrow;
    }
  });
  Config<T> nested(String prefix) => Config._((p) {
    try {
      return load(p.nested(prefix));
    } on ConfigError catch (error) {
      throw ConfigError('$prefix.${error.path}', error.kind, error.message);
    }
  });
  static Config<T> parse<T>(
    String path,
    T Function(String) parse, {
    String message = 'Invalid supplied value',
  }) => Config._((provider) {
    final text = provider.read(path.split('.'));
    if (text == null) {
      throw ConfigError(
        path,
        ConfigErrorKind.missing,
        'Required value is absent',
      );
    }
    try {
      return parse(text);
    } catch (_) {
      throw ConfigError(path, ConfigErrorKind.invalid, message);
    }
  });
  static Config<String> string(String path) => parse(path, (s) => s);
  static Config<int> integer(String path) =>
      parse(path, int.parse, message: 'Expected integer');
  static Config<bool> boolean(String path) => parse(
    path,
    (s) => switch (s.toLowerCase()) {
      'true' => true,
      'false' => false,
      _ => throw const FormatException(),
    },
    message: 'Expected true or false',
  );
  static Config<int> port(String path) => parse(path, (s) {
    final p = int.parse(s);
    if (p < 1 || p > 65535) throw const FormatException();
    return p;
  }, message: 'Expected port from 1 to 65535');
  static Config<Uri> uri(String path) => parse(path, (s) {
    final uri = Uri.parse(s);
    if (!uri.hasScheme) throw const FormatException();
    return uri;
  }, message: 'Expected absolute URI');
  static Config<Duration> duration(String path) => parse(path, (s) {
    final match = RegExp(r'^(\d+)(ms|s|m|h)$').firstMatch(s);
    if (match == null) throw const FormatException();
    final n = int.parse(match[1]!);
    final unit = switch (match[2]) {
      'ms' => 1000,
      's' => 1000000,
      'm' => 60000000,
      _ => 3600000000,
    };
    if (n > 9007199254740991 ~/ unit) throw const FormatException();
    return Duration(microseconds: n * unit);
  }, message: 'Expected nonnegative duration with ms/s/m/h suffix');
  static Config<Redacted<String>> secret(String path) =>
      string(path).map(Redacted.new);
  static Config<(A, B)> tuple<A, B>(Config<A> a, Config<B> b) =>
      Config._((p) => (a.load(p), b.load(p)));
}
