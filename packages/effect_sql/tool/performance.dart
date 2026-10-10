import 'dart:async';

import 'package:effect_sql/effect_sql.dart';

import 'performance_support.dart';

// Explicit synthetic baseline isolates portable pool/runtime overhead from sockets.
final class FixtureDriver implements SqlDriver {
  @override
  Future<SqlConnection> open() async => FixtureConnection();
  @override
  SqlFailure? classify(Object e, String op) => e is SqlFailure ? e : null;
}

final class FixtureConnection implements SqlConnection {
  bool opened = true;
  @override
  bool get isOpen => opened;
  @override
  Future<SqlResult> execute(SqlStatement s) async {
    if (s.text.contains('SLEEP')) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    } else {
      await Future<void>.delayed(Duration.zero);
    }
    if (s.text.startsWith('INSERT') && s.text.contains('(0,')) {
      throw const SqlFailure(SqlFailureKind.constraint, 'execute');
    }
    return SqlResult(
      columns: ['value'],
      rows: [
        [s.parameters.isEmpty ? 1 : s.parameters.first],
      ],
      affectedRows: 1,
    );
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {
    opened = false;
  }
}

Future<void> main(List<String> args) =>
    runPerformance(args, (_) => FixtureDriver(), 'synthetic');
