import 'package:effect_core/effect_core.dart';
import 'package:effect_sqlite/effect_sqlite.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real SQLite binding, commit, rollback and constraint classification',
    () async {
      final rt = Runtime(Unit.value), client = SqliteClient.create(':memory:');
      addTearDown(client.shutdown);
      addTearDown(rt.shutdown);
      await rt.runFuture(
        client.execute<Unit>(
          SqlStatement(
            'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
          ),
        ),
      );
      await rt.runFuture(
        client.transaction<int, Unit>(
          (s) => s
              .execute<Unit>(
                SqlStatement('INSERT INTO users VALUES (?,?)', [1, "λ ' ?"]),
              )
              .map((_) => 1),
        ),
      );
      final failed = await rt.runExit(
        client.transaction<int, Unit>(
          (s) => s
              .execute<Unit>(
                SqlStatement('INSERT INTO users VALUES (?,?)', [2, 'rollback']),
              )
              .flatMap(
                (_) =>
                    Effect.fail(const SqlFailure(SqlFailureKind.other, 'body')),
              ),
        ),
      );
      expect(failed, isA<Failure<int, SqlFailure>>());
      final rows = await rt.runFuture(
        client.execute<Unit>(SqlStatement('SELECT id,name FROM users')),
      );
      expect(rows.rows, [
        [1, "λ ' ?"],
      ]);
      final duplicate = await rt.runExit(
        client.execute<Unit>(
          SqlStatement('INSERT INTO users VALUES (?,?)', [1, 'duplicate']),
        ),
      );
      expect(
        ((duplicate as Failure<SqlResult, SqlFailure>).cause
                as Expected<SqlFailure>)
            .error
            .kind,
        SqlFailureKind.constraint,
      );
    },
  );
  test(
    'DDL does not report stale mutation counts or insert identifiers',
    () async {
      final rt = Runtime(Unit.value), client = SqliteClient.create(':memory:');
      addTearDown(client.shutdown);
      addTearDown(rt.shutdown);
      await rt.runFuture(
        client.execute<Unit>(
          SqlStatement('CREATE TABLE a (id INTEGER PRIMARY KEY)'),
        ),
      );
      final insert = await rt.runFuture(
        client.execute<Unit>(SqlStatement('INSERT INTO a VALUES (1)')),
      );
      expect(insert.affectedRows, 1);
      expect(insert.insertId, null);
      final ddl = await rt.runFuture(
        client.execute<Unit>(SqlStatement('CREATE TABLE b (id INTEGER)')),
      );
      expect(ddl.affectedRows, 0);
      expect(ddl.insertId, null);
      final returning = await rt.runFuture(
        client.execute<Unit>(
          SqlStatement('INSERT INTO a VALUES (2) RETURNING id'),
        ),
      );
      expect(returning.rows, [
        [2],
      ]);
    },
  );
}
