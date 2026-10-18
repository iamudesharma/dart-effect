import 'package:effect_core/effect_core.dart';
import 'package:effect_sql/effect_sql.dart';
import 'package:effect_schema/effect_schema.dart';
import 'package:effect_sql_schema/effect_sql_schema.dart';
import 'package:test/test.dart';

void main() {
  test(
    'row decoding and cardinality preserve explicit SQL/schema error families',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      final schema = Schema.object({'id': Field(Schema.integer)});
      final good = Effect.succeed<SqlResult, SqlFailure, Unit>(
        SqlResult(
          columns: ['id'],
          rows: [
            [1],
          ],
        ),
      );
      expect(await rt.runFuture(good.exactlyOne(schema)), {'id': 1});
      final bad = Effect.succeed<SqlResult, SqlFailure, Unit>(
        SqlResult(
          columns: ['id'],
          rows: [
            ['bad'],
          ],
        ),
      );
      expect(
        ((await rt.runExit(
                      bad.decodeRows(schema),
                    ) as Failure<List<Map<String, Object?>>, SqlDecodeFailure>)
                    .cause
                as Expected<SqlDecodeFailure>)
            .error,
        isA<SqlRowFailure>(),
      );
      final empty = Effect.succeed<SqlResult, SqlFailure, Unit>(
        SqlResult(columns: ['id']),
      );
      expect(
        await rt.runExit(empty.exactlyOne(schema)),
        isA<Failure<Map<String, Object?>, SqlDecodeFailure>>(),
      );
    },
  );
}
