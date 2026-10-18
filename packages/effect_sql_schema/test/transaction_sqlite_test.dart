import 'package:effect_core/effect_core.dart';
import 'package:effect_sqlite/effect_sqlite.dart';
import 'package:effect_sql_schema/effect_sql_schema.dart';
import 'package:test/test.dart';

void main() {
  test('typed domain failure rolls back actual SQLite mutation', () async {
    final rt = Runtime(Unit.value), client = SqliteClient.create(':memory:');
    addTearDown(client.shutdown);
    addTearDown(rt.shutdown);
    await rt.runFuture(
      client.execute<Unit>(
        SqlStatement('CREATE TABLE accounts (id INTEGER PRIMARY KEY)'),
      ),
    );
    final result = await rt.runExit(
      client.transactionWithDomain<int, String, Unit>(
        (session) => session
            .execute<Unit>(SqlStatement('INSERT INTO accounts VALUES (?)', [1]))
            .flatMap(
              (_) => Effect.fail(const DomainFailure('insufficient balance')),
            ),
      ),
    );
    final error =
        (result as Failure<int, SqlTransactionError<String>>).cause
            as Expected<SqlTransactionError<String>>;
    expect(
      (error.error as DomainFailure<String>).error,
      'insufficient balance',
    );
    expect(
      (await rt.runFuture(
        client.execute<Unit>(SqlStatement('SELECT id FROM accounts')),
      )).rows,
      isEmpty,
    );
  });
  test(
    'migrations are ordered, idempotent and reject ledger checksum drift',
    () async {
      final rt = Runtime(Unit.value), client = SqliteClient.create(':memory:');
      addTearDown(client.shutdown);
      addTearDown(rt.shutdown);
      final migrator = SqlMigrator([
        SqlMigration(1, 'table', 'v1', [
          SqlStatement('CREATE TABLE widgets (id INTEGER PRIMARY KEY)'),
        ]),
        SqlMigration(2, 'data', 'v2', [
          SqlStatement('INSERT INTO widgets VALUES (?)', [7]),
        ]),
      ], dialect: MigrationDialect.sqlite);
      expect(await rt.runFuture(migrator.run<Unit>(client)), [1, 2]);
      expect(await rt.runFuture(migrator.run<Unit>(client)), isEmpty);
      final changed = SqlMigrator([
        SqlMigration(1, 'table', 'wrong', []),
      ], dialect: MigrationDialect.sqlite);
      expect(
        await rt.runExit(changed.run<Unit>(client)),
        isA<Failure<List<int>, SqlFailure>>(),
      );
    },
  );
}
