import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';
import 'package:test/test.dart';

SchemaError error(Validation<Object?> result) => (result as Invalid).error;

void main() {
  test('special keys retain unambiguous diagnostic locations', () {
    final schema = Schema.object({
      'a.b': Field(Schema.integer),
      '': Field(Schema.integer),
    });
    expect(error(schema.decode({})).issues.map((i) => i.location), [
      r'$["a.b"]',
      r'$[""]',
    ]);
  });
  test('first mode does not execute subsequent field callbacks', () {
    var calls = 0;
    final schema = Schema.object({
      'x': Field(Schema.integer),
      'y': Field(Schema.integer, defaultValue: () => ++calls),
    });
    expect(
      error(schema.decode({}, mode: ValidationMode.first)).issues,
      hasLength(1),
    );
    expect(calls, 0);
    expect(
      error(schema.encode(<String, Object?>{}, mode: ValidationMode.first))
          .issues,
      hasLength(1),
    );
    expect(calls, 0);
  });
  test('union encoding retains nested diagnostic paths', () {
    final schema = Schema.union<Map<String, Object?>>([
      Schema.object({'x': Field(Schema.integer)}),
      Schema.object({'y': Field(Schema.string)}),
    ]);
    expect(
      error(schema.encode(<String, Object?>{})).issues.map((i) => i.location),
      [r'$.x', r'$.y'],
    );
  });
  test('callbacks can reenter another decoder without sharing budgets', () {
    final schema = Schema.integer.refine((v) {
      return Schema.integer.list().decode([1, 2, 3]).orThrow.length == 3;
    }, 'nested');
    expect(
      schema.decode(1, limits: const ValidationLimits(maxDepth: 2)).orThrow,
      1,
    );
  });

  test(
    'cyclic data and recursive schemas fail with bounded paths both ways',
    () {
      late Schema<Map<String, Object?>> node;
      node = Schema.lazy(() => Schema.object({'next': Field(node)}));
      final input = <String, Object?>{};
      input['next'] = input;
      for (final result in [node.decode(input), node.encode(input)]) {
        expect(error(result).issues.single.message, contains('depth'));
        expect(error(result).issues.single.path.length, lessThan(64));
      }
      late Schema<Object?> self;
      self = Schema.lazy(() => self);
      expect(self.decode(1), isA<Invalid>());
      expect(self.encode(1), isA<Invalid>());
    },
  );

  test('depth is per branch and per invocation, with explicit boundary', () {
    final schema = Schema.integer.list();
    const shallow = ValidationLimits(maxDepth: 1);
    expect(schema.decode([1], limits: shallow), isA<Invalid>());
    expect(schema.encode([1], limits: shallow), isA<Invalid>());
    expect(schema.decode(List.filled(1000, 1)).orThrow, hasLength(1000));
    expect(schema.encode([1]).orThrow, [1]);
  });

  test('issue cap stops traversal rather than just truncating the output', () {
    var calls = 0;
    final schema = Schema.integer.refine((v) {
      calls++;
      return false;
    }, 'bad').list();
    const limits = ValidationLimits(maxIssues: 7);
    for (final encoding in [false, true]) {
      calls = 0;
      final input = List.filled(100000, 1);
      final result = encoding
          ? schema.encode(input, limits: limits)
          : schema.decode(input, limits: limits);
      expect(error(result).issues, hasLength(7));
      expect(calls, 7);
    }
  });

  test('nested errors and unknown fields obey the issue cap', () {
    final nested = Schema.integer.list().list();
    expect(
      error(
        nested.decode([
          List.filled(200, 'bad'),
          ['bad'],
        ]),
      ).issues,
      hasLength(100),
    );
    final object = Schema.object({});
    expect(
      error(
        object.decode({
          for (var i = 0; i < 1000; i++) '$i': i,
        }, limits: const ValidationLimits(maxIssues: 3)),
      ).issues,
      hasLength(3),
    );
  });

  test(
    'union searches later successful branches after diagnostic budget fills',
    () {
      final schema = Schema.union<Object?>([
        Schema.string,
        Schema.boolean,
        Schema.integer,
      ]);
      const limits = ValidationLimits(maxIssues: 1);
      expect(schema.decode(42, limits: limits).orThrow, 42);
      expect(schema.encode(42, limits: limits).orThrow, 42);
      expect(error(schema.decode([], limits: limits)).issues, hasLength(1));
      expect(error(schema.encode([], limits: limits)).issues, hasLength(1));
    },
  );

  test('preserved unknown fields cannot overwrite renamed values', () {
    final schema = Schema.object({
      'name': Field(Schema.string, wireName: 'display_name'),
    }, unknown: UnknownFields.preserve);
    expect(
      error(schema.decode({'name': 'shadow', 'display_name': 'real'}))
          .issues
          .single
          .location,
      r'$.name',
    );
    expect(
      error(schema.encode({'name': 'real', 'display_name': 'shadow'}))
          .issues
          .single
          .location,
      r'$.display_name',
    );
    final decoded = schema.decode({'display_name': 'real', 'extra': 1}).orThrow;
    expect(schema.encode(decoded).orThrow, {
      'display_name': 'real',
      'extra': 1,
    });
  });

  test('defaults are fresh, validated, and failures carry field paths', () {
    var calls = 0;
    final schema = Schema.object({
      'x': Field(Schema.integer, defaultValue: () => ++calls),
    });
    expect(schema.decode({}).orThrow['x'], 1);
    expect(schema.decode({}).orThrow['x'], 2);
    expect(schema.decode({'x': null}), isA<Invalid>());
    expect(calls, 2);
    final broken = Schema.object({
      'x': Field(
        Schema.integer,
        defaultValue: () => throw StateError('secret'),
      ),
    });
    for (final result in [
      broken.decode({}),
      broken.encode(<String, Object?>{}),
    ]) {
      expect(error(result).issues.single.location, r'$.x');
      expect(error(result).toString(), isNot(contains('secret')));
    }
    expect(
      Schema.object({'x': Field(Schema.integer, defaultValue: () => 'bad')})
          .decode({}),
      isA<Invalid>(),
    );
  });

  test('missing, optional and nullable fields have distinct semantics', () {
    final schema = Schema.object({
      'required': Field(Schema.string.nullable()),
      'optional': Field(Schema.integer, optional: true),
    });
    expect(schema.decode({}), isA<Invalid>());
    expect(schema.decode({'required': null}).orThrow, {'required': null});
    expect(schema.decode({'required': null, 'optional': null}), isA<Invalid>());
    expect(schema.encode(<String, Object?>{'required': null}).orThrow, {
      'required': null,
    });
  });

  test('invalid configuration is rejected before traversal', () {
    expect(
      () =>
          Schema.integer.decode(1, limits: const ValidationLimits(maxDepth: 0)),
      throwsArgumentError,
    );
    expect(
      () => Schema.integer.encode(
        1,
        limits: const ValidationLimits(maxIssues: 0),
      ),
      throwsArgumentError,
    );
    expect(() => Schema.union<Object?>([]), throwsArgumentError);
    expect(
      () => Schema.object({
        'a': Field(Schema.integer, wireName: 'b'),
        'b': Field(Schema.integer),
      }),
      throwsArgumentError,
    );
  });

  test('schemas snapshot definitions and collections are immutable', () {
    final fields = {'x': Field(Schema.integer)};
    final schema = Schema.object(fields);
    fields.clear();
    expect(schema.decode({}), isA<Invalid>());
    final values = Schema.integer.list().decode([1, 2]).orThrow;
    expect(() => values.add(3), throwsUnsupportedError);
    final issues = error(schema.decode({})).issues;
    expect(() => issues.clear(), throwsUnsupportedError);
    expect(() => issues.single.path.clear(), throwsUnsupportedError);
  });

  test(
    'finite numbers, malformed JSON, and conversion failures are rejected',
    () {
      for (final v in [double.nan, double.infinity, double.negativeInfinity]) {
        expect(Schema.number.decode(v), isA<Invalid>());
        expect(Schema.number.encode(v), isA<Invalid>());
      }
      expect(Schema.integer.json().decode('{'), isA<Invalid>());
      final codec = Schema.string.transform<int>(
        int.parse,
        (v) => throw StateError('private'),
      );
      expect(codec.decode('bad'), isA<Invalid>());
      expect(codec.encode(1), isA<Invalid>());
    },
  );

  test(
    'Effect validation stays lazy and re-executes with fresh traversal state',
    () async {
      var calls = 0;
      final schema = Schema.object({
        'x': Field(Schema.integer, defaultValue: () => ++calls),
      });
      final effect = schema.decodeEffect<Unit>({});
      expect(calls, 0);
      final runtime = Runtime(Unit.value);
      addTearDown(runtime.shutdown);
      expect((await runtime.runFuture(effect))['x'], 1);
      expect((await runtime.runFuture(effect))['x'], 2);
      final failure = await runtime.runExit(
        Schema.integer.list().decodeEffect<Unit>([
          'a',
          'b',
        ], limits: const ValidationLimits(maxIssues: 1)),
      );
      expect((failure as Failure).cause, isA<Expected<SchemaError>>());
    },
  );
}
