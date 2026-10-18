import 'package:effect_schema/effect_schema.dart';

Future<void> main() async {
  final schema = Schema.object({'id': Field(Schema.integer)});
  print(schema.decode({'id': 42}).orThrow);
}
