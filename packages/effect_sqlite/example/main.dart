import 'package:effect_core/effect_core.dart';
import 'package:effect_sqlite/effect_sqlite.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value), client = SqliteClient.create(':memory:');
  try {
    final rows = await runtime.runFuture(
      client.execute<Unit>(SqlStatement('SELECT ? AS value', [42])),
    );
    print(rows.rows);
  } finally {
    await runtime.shutdown();
    await client.shutdown();
  }
}
