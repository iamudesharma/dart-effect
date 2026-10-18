/// Native SQLite adapter using package:sqlite3. Synchronous work cannot be
/// interrupted mid-statement; use explicit isolate work for heavy SQL.
library;

import 'package:effect_sql/effect_sql.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
export 'package:effect_sql/effect_sql.dart';

final class SqliteDriver implements SqlDriver {
  SqliteDriver(this.path);
  final String path;
  @override
  Future<SqlConnection> open() async => _Connection(
    path == ':memory:'
        ? sqlite.sqlite3.openInMemory()
        : sqlite.sqlite3.open(path),
  );
  @override
  SqlFailure? classify(Object error, String operation) {
    if (error is! sqlite.SqliteException) return null;
    return SqlFailure(
      switch (error.resultCode) {
        19 => SqlFailureKind.constraint,
        5 || 6 => SqlFailureKind.serialization,
        1 => SqlFailureKind.syntax,
        _ => SqlFailureKind.other,
      },
      operation,
      code: error.extendedResultCode.toString(),
      cause: error,
    );
  }
}

final class SqliteClient {
  /// One connection preserves memory-database identity and serializes writes.
  static SqlClient create(String path) =>
      SqlClient(SqliteDriver(path), maxConnections: 1);
}

final class _Connection implements SqlConnection {
  _Connection(this.db);
  final sqlite.Database db;
  bool _open = true;
  @override
  bool get isOpen => _open;
  @override
  Future<SqlResult> execute(SqlStatement statement) async {
    final before =
        db.select('SELECT total_changes()').single.columnAt(0) as int;
    final prepared = db.prepare(statement.text);
    try {
      final result = prepared.select(statement.parameters);
      final after =
          db.select('SELECT total_changes()').single.columnAt(0) as int;
      return SqlResult(
        columns: result.columnNames,
        rows: [
          for (final row in result)
            [
              for (var i = 0; i < result.columnNames.length; i++)
                row.columnAt(i),
            ],
        ],
        affectedRows: prepared.isReadOnly || before == after
            ? 0
            : db.updatedRows,
        // Avoid reporting a stale connection-level lastInsertRowId for DDL/UPDATE.
        // Use an INSERT ... RETURNING clause when an identifier is required.
        insertId: null,
      );
    } finally {
      prepared.dispose();
    }
  }

  @override
  Future<void> cancel() async {} // Execution is synchronous and already settled.
  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    db.dispose();
  }
}
