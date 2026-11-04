import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';

Future<void> main() async {
  final user = Schema.object({
    'id': Field(Schema.integer),
    'name': Field(
      Schema.string.refine((s) => s.isNotEmpty, 'Name required'),
      wireName: 'display_name',
    ),
    'active': Field(Schema.boolean, defaultValue: () => true),
    'note': Field(Schema.string.nullable(), optional: true),
  });
  final decoded = user.decode({'id': 42, 'display_name': 'Ada'}).orThrow;
  print(decoded);
  print(user.encode(decoded).orThrow);
  final invalid = user.decode({'id': 'bad', 'display_name': ''});
  if (invalid case Invalid(:final error)) {
    for (final issue in error.issues) {
      print(issue);
    }
  }
  final json = Schema.integer.list().json();
  print(json.encode(json.decode('[1,2,3]').orThrow).orThrow);
  final runtime = Runtime(Unit.value);
  try {
    final value = await runtime.runFuture(
      user.decodeEffect<Unit>({'id': 1, 'display_name': 'Effect'}),
    );
    print(value);
  } finally {
    await runtime.shutdown();
  }
}
