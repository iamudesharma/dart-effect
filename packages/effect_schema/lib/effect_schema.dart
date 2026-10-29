/// Pure portable validation and bidirectional codecs. No code generator needed.
library;

import 'dart:convert';

import 'package:effect_core/effect_core.dart';

enum ValidationMode { first, all }

enum UnknownFields { reject, strip, preserve }

/// Per-operation bounds. Depth counts codec calls, including wrappers.
/// Input and successful output sizes are not bounded by these limits.
final class ValidationLimits {
  const ValidationLimits({this.maxDepth = 64, this.maxIssues = 100});
  final int maxDepth;
  final int maxIssues;
}

final class _Context {
  _Context(this.mode, this.limits) {
    if (limits.maxDepth < 1 || limits.maxIssues < 1) {
      throw ArgumentError('Validation limits must be positive');
    }
  }
  final ValidationMode mode;
  final ValidationLimits limits;
  int depth = 0;
  int get issueLimit => mode == ValidationMode.first ? 1 : limits.maxIssues;
}

final class SchemaIssue {
  SchemaIssue(Iterable<Object> path, this.message)
    : path = List.unmodifiable(path);
  final List<Object> path;
  final String message;
  String get location => path.fold(
    r'$',
    (out, part) => part is int
        ? '$out[$part]'
        : RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(part.toString())
        ? '$out.$part'
        : '$out[${jsonEncode(part.toString())}]',
  );
  SchemaIssue at(Object key) => SchemaIssue([key, ...path], message);
  @override
  String toString() => '$location: $message';
}

final class SchemaError implements Exception {
  SchemaError(Iterable<SchemaIssue> issues)
    : issues = List.unmodifiable(issues);
  final List<SchemaIssue> issues;
  @override
  String toString() => issues.join('; ');
}

sealed class Validation<T> {
  const Validation();
  T get orThrow => switch (this) {
    Valid(:final value) => value,
    Invalid(:final error) => throw error,
  };
}

final class Valid<T> extends Validation<T> {
  const Valid(this.value);
  final T value;
}

final class Invalid<T> extends Validation<T> {
  const Invalid(this.error);
  final SchemaError error;
}

Validation<T> _bad<T>(String message) =>
    Invalid(SchemaError([SchemaIssue([], message)]));

/// A decoder and encoder with structured failures. Thrown conversion errors
/// become validation issues; they are never silently accepted as typed values.
final class Schema<T> {
  Schema._(this._decode, this._encode, this._json);
  final Validation<T> Function(Object?, _Context) _decode;
  final Validation<Object?> Function(T, _Context) _encode;
  final Map<String, Object?> Function() _json;

  /// Validates synchronously. Each invocation owns its traversal state.
  Validation<T> decode(
    Object? value, {
    ValidationMode mode = ValidationMode.all,
    ValidationLimits limits = const ValidationLimits(),
  }) => _read(value, _Context(mode, limits));

  Validation<Object?> encode(
    Object? value, {
    ValidationMode mode = ValidationMode.all,
    ValidationLimits limits = const ValidationLimits(),
  }) => _write(value, _Context(mode, limits));

  Validation<T> _read(Object? value, _Context context) {
    if (context.depth >= context.limits.maxDepth) {
      return _bad('Maximum validation depth exceeded');
    }
    context.depth++;
    try {
      return _decode(value, context);
    } finally {
      context.depth--;
    }
  }

  Validation<Object?> _write(Object? value, _Context context) {
    if (value is! T) return _bad('Invalid domain value');
    if (context.depth >= context.limits.maxDepth) {
      return _bad('Maximum validation depth exceeded');
    }
    context.depth++;
    try {
      return _encode(value, context);
    } finally {
      context.depth--;
    }
  }

  Map<String, Object?> toJsonSchema() => Map.unmodifiable(_json());
  Effect<T, SchemaError, R> decodeEffect<R>(
    Object? input, {
    ValidationMode mode = ValidationMode.all,
    ValidationLimits limits = const ValidationLimits(),
  }) => Effect.defer(
    () => switch (decode(input, mode: mode, limits: limits)) {
      Valid(:final value) => Effect.succeed(value),
      Invalid(:final error) => Effect.fail(error),
    },
  );
  Schema<T> refine(bool Function(T) predicate, String message) => Schema._(
    (input, mode) {
      final decoded = _read(input, mode);
      if (decoded is Invalid<T>) return decoded;
      try {
        return predicate((decoded as Valid<T>).value) ? decoded : _bad(message);
      } catch (_) {
        return _bad(message);
      }
    },
    (value, mode) {
      try {
        return predicate(value) ? _write(value, mode) : _bad(message);
      } catch (_) {
        return _bad(message);
      }
    },
    _json,
  );
  Schema<U> transform<U>(
    U Function(T) decodeValue,
    T Function(U) encodeValue,
  ) => Schema._(
    (input, mode) {
      final result = _read(input, mode);
      if (result is Invalid<T>) return Invalid(result.error);
      try {
        return Valid(decodeValue((result as Valid<T>).value));
      } catch (_) {
        return _bad('Conversion failed');
      }
    },
    (value, mode) {
      try {
        return _write(encodeValue(value), mode);
      } catch (_) {
        return _bad('Reverse conversion failed');
      }
    },
    _json,
  );
  Schema<T?> nullable() => Schema<T?>._(
    (v, m) => v == null ? const Valid(null) : _read(v, m),
    (v, m) => v == null ? const Valid(null) : _write(v, m),
    () => {
      'anyOf': [
        toJsonSchema(),
        {'type': 'null'},
      ],
    },
  );
  Schema<List<T>> list() => Schema<List<T>>._(
    (input, mode) {
      if (input is! List) return _bad('Expected list');
      final values = <T>[], issues = <SchemaIssue>[];
      for (var i = 0; i < input.length; i++) {
        final item = _read(input[i], mode);
        if (item is Valid<T>) {
          values.add(item.value);
        } else {
          issues.addAll((item as Invalid<T>).error.issues.map((e) => e.at(i)));
        }
        if (issues.length >= mode.issueLimit) break;
      }
      return issues.isEmpty
          ? Valid(List.unmodifiable(values))
          : Invalid(SchemaError(issues.take(mode.issueLimit)));
    },
    (values, mode) {
      final out = <Object?>[], issues = <SchemaIssue>[];
      for (var i = 0; i < values.length; i++) {
        final item = _write(values[i], mode);
        if (item is Valid<Object?>) {
          out.add(item.value);
        } else {
          issues.addAll(
            (item as Invalid<Object?>).error.issues.map((e) => e.at(i)),
          );
        }
        if (issues.length >= mode.issueLimit) break;
      }
      return issues.isEmpty
          ? Valid(List.unmodifiable(out))
          : Invalid(SchemaError(issues.take(mode.issueLimit)));
    },
    () => {'type': 'array', 'items': toJsonSchema()},
  );
  Schema<T> json() => Schema._(
    (input, mode) {
      if (input is! String) return _bad('Expected JSON text');
      try {
        return _read(jsonDecode(input), mode);
      } catch (_) {
        return _bad('Invalid JSON');
      }
    },
    (value, mode) {
      final result = _write(value, mode);
      if (result is Invalid<Object?>) return result;
      try {
        return Valid(jsonEncode((result as Valid<Object?>).value));
      } catch (_) {
        return _bad('Not JSON encodable');
      }
    },
    () => {
      'type': 'string',
      'contentMediaType': 'application/json',
      'contentSchema': toJsonSchema(),
    },
  );

  static Schema<T> value<T>(String type) => Schema<T>._(
    (v, _) => v is T ? Valid(v) : _bad('Expected $type'),
    (v, _) => Valid(v),
    () => {'type': type},
  );
  static final string = value<String>('string');
  static final integer = value<int>('integer');
  static final number = value<num>('number')
      .refine((v) => v.isFinite, 'Expected finite number');
  static final boolean = value<bool>('boolean');
  static Schema<T> literal<T>(T expected) => Schema<T>._(
    (v, _) => v == expected && v is T ? Valid(v) : _bad('Unexpected literal'),
    (v, _) => v == expected ? Valid(v) : _bad('Unexpected literal'),
    () => {'const': expected},
  );
  static Schema<T> lazy<T>(Schema<T> Function() build) => Schema<T>._(
    (v, m) => build()._read(v, m),
    (v, m) => build()._write(v, m),
    () => throw UnsupportedError(
      'Recursive JSON Schema requires explicit references',
    ),
  );
  static Schema<T> union<T>(List<Schema<T>> choices) {
    final schemas = List<Schema<T>>.unmodifiable(choices);
    if (schemas.isEmpty) throw ArgumentError('Empty union');
    return Schema<T>._(
      (v, m) {
        final issues = <SchemaIssue>[];
        for (final schema in schemas) {
          final result = schema._read(v, m);
          if (result is Valid<T>) return result;
          issues.addAll(
            (result as Invalid<T>).error.issues.take(
              m.issueLimit - issues.length,
            ),
          );
        }
        return Invalid(SchemaError(issues.take(m.issueLimit)));
      },
      (v, m) {
        final issues = <SchemaIssue>[];
        for (final schema in schemas) {
          final result = schema._write(v, m);
          if (result is Valid<Object?>) return result;
          issues.addAll(
            (result as Invalid<Object?>).error.issues.take(
              m.issueLimit - issues.length,
            ),
          );
        }
        return Invalid(SchemaError(issues));
      },
      () => {'anyOf': schemas.map((s) => s.toJsonSchema()).toList()},
    );
  }

  static Schema<Map<String, Object?>> object(
    Map<String, Field> inputFields, {
    UnknownFields unknown = UnknownFields.reject,
  }) {
    final fields = Map<String, Field>.unmodifiable(inputFields);
    final names = fields.entries.map((e) => e.value.wireName ?? e.key).toSet();
    final domainNames = fields.keys.toSet();
    if (names.length != fields.length) {
      throw ArgumentError('Duplicate wire field');
    }
    Validation<Map<String, Object?>> process(
      Object? input,
      _Context mode,
      bool encoding,
    ) {
      if (input is! Map || input.keys.any((k) => k is! String)) {
        return _bad('Expected string-keyed object');
      }
      final values = <String, Object?>{}, issues = <SchemaIssue>[];
      final known = encoding ? domainNames : names;
      for (final key in input.keys) {
        if (!known.contains(key)) {
          if (unknown == UnknownFields.reject) {
            issues.add(SchemaIssue([key as String], 'Unknown field'));
          }
          if (unknown == UnknownFields.preserve) {
            final outputNames = encoding ? names : domainNames;
            if (outputNames.contains(key)) {
              issues.add(
                SchemaIssue([key as String], 'Renamed field collision'),
              );
            } else {
              values[key as String] = input[key];
            }
          }
          if (issues.length >= mode.issueLimit) {
            return Invalid(SchemaError(issues.take(mode.issueLimit)));
          }
        }
      }
      for (final entry in fields.entries) {
        final field = entry.value, wire = field.wireName ?? entry.key;
        final from = encoding ? entry.key : wire,
            to = encoding ? wire : entry.key;
        if (!input.containsKey(from)) {
          if (field.defaultValue != null) {
            Validation<Object?> result;
            try {
              result = field.schema._read(field.defaultValue!(), mode);
            } catch (_) {
              result = _bad('Default factory failed');
            }
            if (result is Valid<Object?>) {
              final encoded = encoding
                  ? field.schema._write(result.value, mode)
                  : result;
              if (encoded is Valid<Object?>) {
                values[to] = encoded.value;
              } else {
                issues.addAll(
                  (encoded as Invalid<Object?>).error.issues.map(
                    (e) => e.at(from),
                  ),
                );
              }
            } else {
              issues.addAll(
                (result as Invalid<Object?>).error.issues.map(
                  (e) => e.at(from),
                ),
              );
            }
          } else if (!field.optional) {
            issues.add(SchemaIssue([from], 'Missing field'));
          }
        } else {
          final result = encoding
              ? field.schema._write(input[from], mode)
              : field.schema._read(input[from], mode);
          if (result is Valid<Object?>) {
            values[to] = result.value;
          } else {
            issues.addAll(
              (result as Invalid<Object?>).error.issues.map((e) => e.at(from)),
            );
          }
        }
        if (issues.length >= mode.issueLimit) break;
      }
      return issues.isEmpty
          ? Valid(Map.unmodifiable(values))
          : Invalid(SchemaError(issues.take(mode.issueLimit)));
    }

    return Schema._(
      (v, m) => process(v, m, false),
      (v, m) => process(v, m, true),
      () => {
        'type': 'object',
        'properties': {
          for (final e in fields.entries)
            e.value.wireName ?? e.key: e.value.schema.toJsonSchema(),
        },
        'required': [
          for (final e in fields.entries)
            if (!e.value.optional && e.value.defaultValue == null)
              e.value.wireName ?? e.key,
        ],
        'additionalProperties': unknown != UnknownFields.reject,
      },
    );
  }
}

final class Field {
  const Field(
    this.schema, {
    this.optional = false,
    this.defaultValue,
    this.wireName,
  });
  final Schema<Object?> schema;
  final bool optional;

  /// A fresh wire-format default, validated just like supplied input.
  final Object? Function()? defaultValue;
  final String? wireName;
}
