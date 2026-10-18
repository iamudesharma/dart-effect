import 'package:effect_schema/effect_schema.dart';
import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

void main() {
  final user = Schema.object({
    'id': Field(Schema.integer),
    'name': Field(
      Schema.string.refine((s) => s.isNotEmpty, 'Name required'),
      wireName: 'display_name',
    ),
    'enabled': Field(Schema.boolean, defaultValue: () => true),
    'note': Field(Schema.string.nullable(), optional: true),
  });
  test('objects decode renamed fields/defaults and encode round trips', () {
    final value = user.decode({'id': 1, 'display_name': 'A'}).orThrow;
    expect(value, {'id': 1, 'name': 'A', 'enabled': true});
    expect(user.decode(user.encode(value).orThrow).orThrow, value);
    expect(user.toJsonSchema()['required'], ['id', 'display_name']);
    expect(() => value['id'] = 2, throwsUnsupportedError);
  });
  test('nested paths accumulate and first mode stops', () {
    final schema = Schema.object({
      'orders': Field(Schema.object({'price': Field(Schema.number)}).list()),
    });
    final input = {
      'orders': [
        {'price': 'bad'},
        {'price': false},
      ],
    };
    final error = (schema.decode(input) as Invalid).error;
    expect(error.issues.map((e) => e.location), [
      r'$.orders[0].price',
      r'$.orders[1].price',
    ]);
    expect(
      (schema.decode(
        input,
        mode: ValidationMode.first,
      ) as Invalid).error.issues.length,
      1,
    );
  });
  test('unknown field strategies and explicit null differ from absence', () {
    expect(
      user.decode({'id': 1, 'display_name': 'A', 'enabled': null}),
      isA<Invalid>(),
    );
    expect(
      user.decode({'id': 1, 'display_name': 'A', 'secret': 2}),
      isA<Invalid>(),
    );
    expect(
      Schema.object({}, unknown: UnknownFields.strip).decode({'x': 1}).orThrow,
      {},
    );
    expect(
      Schema.object(
        {},
        unknown: UnknownFields.preserve,
      ).decode({'x': 1}).orThrow,
      {'x': 1},
    );
  });
  test('codec transformations, JSON and union support typed round trips', () {
    final date = Schema.string.transform<DateTime>(
      DateTime.parse,
      (d) => d.toIso8601String(),
    );
    final now = DateTime.utc(2026, 10, 18);
    expect(date.decode(date.encode(now).orThrow).orThrow, now);
    expect(date.encode(3), isA<Invalid>());
    expect(date.decode('invalid'), isA<Invalid>());
    final json = Schema.integer.list().json();
    expect(json.decode(json.encode([1, 2, 3]).orThrow).orThrow, [1, 2, 3]);
    final union = Schema.union<Object?>([Schema.literal('ok'), Schema.integer]);
    expect(union.decode(5).orThrow, 5);
  });
  test('recursive schemas decode without code generation and effect errors stay typed', () async {
    late Schema<Map<String, Object?>> node;
    node = Schema.lazy(
      () => Schema.object({
        'n': Field(Schema.integer),
        'children': Field(node.list(), defaultValue: () => []),
      }),
    );
    expect(
      node.decode({
        'n': 1,
        'children': [
          {'n': 2},
        ],
      }),
      isA<Valid>(),
    );
    final rt = Runtime(Unit.value);
    addTearDown(rt.shutdown);
    final exit = await rt.runExit(Schema.integer.decodeEffect<Unit>('wrong'));
    expect(
      (exit as Failure<int, SchemaError>).cause,
      isA<Expected<SchemaError>>(),
    );
  });
  test('seeded round trips preserve collections', () {
    for (var n = 0; n < 100; n++) {
      final values = List.generate(n, (i) => i - n);
      final codec = Schema.integer.list().json();
      expect(codec.decode(codec.encode(values).orThrow).orThrow, values);
    }
  });
}
