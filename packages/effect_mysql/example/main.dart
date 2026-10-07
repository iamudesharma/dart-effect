import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_mysql/effect_mysql.dart';

Future<void> main() async {
  final env = Platform.environment;
  final caPath = env['MYSQL_CA'];
  final security = caPath == null
      ? null
      : (SecurityContext()..setTrustedCertificates(caPath));
  final layer = MySqlClient.layer(
    MySqlSettings(
      host: env['MYSQL_HOST'] ?? 'localhost',
      port: int.parse(env['MYSQL_PORT'] ?? '3306'),
      database: env['MYSQL_DATABASE'] ?? 'mysql',
      user: env['MYSQL_USER'] ?? 'root',
      password: env['MYSQL_PASSWORD'] ?? '',
      securityContext: security,
    ),
  );
  final program = MySqlClient.key
      .effect<SqlFailure>()
      .flatMap(
        (db) => db.execute<Context>(
          SqlStatement('SELECT ? AS greeting', ['Hello from Effect']),
        ),
      )
      .map((result) => result.rows.single.single);
  final runtime = Runtime(Context());
  try {
    print(await runtime.runFuture(layer.use(program)));
  } finally {
    await runtime.shutdown();
  }
}
