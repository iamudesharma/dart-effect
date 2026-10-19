/// MySQL effects backed by the maintained mysql_client_plus driver.
library;

import 'dart:async';
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_sql/effect_sql.dart';
import 'package:mysql_client_plus/mysql_client_plus.dart' as mysql;
import 'package:mysql_client_plus/exception.dart' as mysql_errors;
export 'package:effect_sql/effect_sql.dart';

final class MySqlSettings {
  const MySqlSettings({
    required this.host,
    required this.user,
    required this.password,
    required this.database,
    this.port = 3306,
    this.secure = true,
    this.connectTimeout = const Duration(seconds: 10),
    this.securityContext,
    this.onBadCertificate,
  });
  final String host, user, password, database;
  final int port;
  final bool secure;
  final Duration connectTimeout;
  final SecurityContext? securityContext;
  final bool Function(X509Certificate)? onBadCertificate;
}

final class MySqlDriver implements SqlDriver {
  MySqlDriver(this.settings) {
    if (settings.connectTimeout <= Duration.zero) {
      throw ArgumentError.value(settings.connectTimeout, 'connectTimeout');
    }
  }
  final MySqlSettings settings;
  @override
  Future<SqlConnection> open() async {
    final opening = mysql.MySQLConnection.createConnection(
      host: settings.host,
      port: settings.port,
      userName: settings.user,
      password: settings.password,
      databaseName: settings.database,
      secure: settings.secure,
      securityContext: settings.securityContext,
      onBadCertificate: settings.onBadCertificate ?? _rejectCertificate,
    );
    var abandoned = false;
    // A TCP deadline must also destroy a socket which arrives after timeout.
    // Future.timeout by itself would leak that late connection.
    unawaited(
      opening.then<void>((c) {
        if (abandoned) c.getSocket().destroy();
      }, onError: (Object _, StackTrace _) {}),
    );
    final c = await opening.timeout(
      settings.connectTimeout,
      onTimeout: () {
        abandoned = true;
        throw TimeoutException('MySQL connection acquisition timed out');
      },
    );
    try {
      await c.connect(timeoutMs: settings.connectTimeout.inMilliseconds);
      return _Connection(c);
    } catch (_) {
      c.getSocket().destroy();
      rethrow;
    }
  }

  @override
  SqlFailure? classify(Object error, String operation) {
    if (error is mysql_errors.MySQLServerException) {
      final code = error.errorCode;
      final kind = switch (code) {
        1048 || 1062 || 1451 || 1452 || 3819 => SqlFailureKind.constraint,
        1205 || 1213 => SqlFailureKind.serialization,
        1044 || 1045 => SqlFailureKind.authentication,
        1064 || 1146 => SqlFailureKind.syntax,
        2002 || 2003 || 2006 || 2013 => SqlFailureKind.connection,
        _ => SqlFailureKind.other,
      };
      return SqlFailure(kind, operation, code: '$code', cause: error);
    }
    if (error is mysql_errors.MySQLException ||
        error is IOException ||
        error is TimeoutException) {
      return SqlFailure(SqlFailureKind.connection, operation, cause: error);
    }
    return null;
  }
}

final class MySqlClient {
  static final key = ServiceKey<SqlClient>('MySqlClient');
  static SqlClient create(
    MySqlSettings settings, {
    int maxConnections = 10,
    int maxPending = 1024,
  }) => SqlClient(
    MySqlDriver(settings),
    maxConnections: maxConnections,
    maxPending: maxPending,
  );
  static Layer<SqlFailure> layer(
    MySqlSettings settings, {
    int maxConnections = 10,
    int maxPending = 1024,
  }) => Layer.resource(
    key,
    Effect.sync<SqlClient, SqlFailure, Context>(
      () => create(
        settings,
        maxConnections: maxConnections,
        maxPending: maxPending,
      ),
    ),
    (c) => c.close<Context>(),
  );
}

final class _Connection implements SqlConnection {
  _Connection(this.connection);
  final mysql.MySQLConnection connection;
  @override
  bool get isOpen => connection.connected;
  @override
  Future<SqlResult> execute(SqlStatement statement) async {
    // Values are bound with the driver's binary prepared-statement API. Never
    // substitute parameters into SQL or use execute's text interpolation.
    late mysql.IResultSet r;
    if (statement.parameters.isEmpty) {
      r = await connection.execute(statement.text);
    } else {
      final prepared = await connection.prepare(statement.text);
      Object? primary;
      StackTrace? primaryStack;
      try {
        r = await prepared.execute(statement.parameters);
      } catch (error, stack) {
        primary = error;
        primaryStack = stack;
      }
      try {
        if (connection.connected) await prepared.deallocate();
      } catch (error, stack) {
        throw SqlCommandCleanupException(
          primary: primary,
          primaryStack: primaryStack,
          cleanup: error,
          cleanupStack: stack,
          cleanupOperation: 'prepared.close',
        );
      }
      if (primary != null) Error.throwWithStackTrace(primary, primaryStack!);
    }
    return SqlResult(
      columns: r.cols.map((c) => c.name),
      rows: r.rows.map(
        (row) => List<Object?>.generate(
          row.numOfColumns,
          (i) => row.colAt(i) as Object?,
        ),
      ),
      affectedRows: r.affectedRows.toInt(),
      insertId: r.lastInsertID,
    );
  }

  // The driver has no public command-cancel API. Drain before rollback/reuse;
  // interruption may wait for the query to finish. Never return a busy socket.
  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {
    if (connection.connected) await connection.close();
  }
}

bool _rejectCertificate(X509Certificate _) => false;
