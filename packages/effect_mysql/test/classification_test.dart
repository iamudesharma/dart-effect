import 'package:effect_mysql/effect_mysql.dart';
import 'package:mysql_client_plus/exception.dart';
import 'package:test/test.dart';

void main() {
  final driver = MySqlDriver(
    const MySqlSettings(
      host: 'localhost',
      user: 'user',
      password: 'secret',
      database: 'app',
    ),
  );
  for (final entry in <int, SqlFailureKind>{
    1062: SqlFailureKind.constraint,
    1213: SqlFailureKind.serialization,
    1045: SqlFailureKind.authentication,
    1064: SqlFailureKind.syntax,
    2013: SqlFailureKind.connection,
  }.entries) {
    test(
      '[MYSQL/classification/${entry.key}] server error remains a typed failure',
      () {
        final failure = driver.classify(
          MySQLServerException('private data', entry.key),
          'execute',
        )!;
        expect(failure.kind, entry.value);
        expect(failure.code, '${entry.key}');
        expect(failure.toString(), isNot(contains('private data')));
      },
    );
  }
  test('[MYSQL/programmer] arbitrary programming errors remain defects', () {
    expect(driver.classify(StateError('bug'), 'execute'), null);
  });
  test('[MYSQL/config] invalid connect timeout rejects immediately', () {
    expect(
      () => MySqlDriver(
        const MySqlSettings(
          host: 'localhost',
          user: 'user',
          password: '',
          database: 'app',
          connectTimeout: Duration.zero,
        ),
      ),
      throwsArgumentError,
    );
  });
}
