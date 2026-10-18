import 'package:effect_core/effect_core.dart';
import 'package:effect_sql/effect_sql.dart';
import 'package:effect_schema/effect_schema.dart';
import 'package:effect_sql_schema/effect_sql_schema.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final result = Effect.succeed<SqlResult, SqlFailure, Unit>(
    SqlResult(
      columns: ['id'],
      rows: [
        [42],
      ],
    ),
  );
  try {
    print(
      await runtime.runFuture(
        result.exactlyOne(Schema.object({'id': Field(Schema.integer)})),
      ),
    );
  } finally {
    await runtime.shutdown();
  }
}
