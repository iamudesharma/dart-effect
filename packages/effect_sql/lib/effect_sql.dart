/// Driver-independent scoped SQL effects for Dart API services.
library;

import 'dart:async';
import 'dart:collection';

import 'package:effect_core/effect_core.dart';

enum SqlFailureKind {
  connection,
  authentication,
  constraint,
  serialization,
  syntax,
  closed,
  other,
}

/// Safe summary; SQL text, parameter values and server messages are not logged.
final class SqlFailure implements Exception {
  const SqlFailure(this.kind, this.operation, {this.code, this.cause});
  final SqlFailureKind kind;
  final String operation;
  final String? code;

  /// Original driver exception for explicit diagnostics; it may contain data.
  final Object? cause;
  @override
  String toString() =>
      'SqlFailure(${kind.name}, $operation${code == null ? '' : ', $code'})';
}

/// Placeholders use the driver's dialect: PostgreSQL $1, MySQL ?.
final class SqlStatement {
  SqlStatement(this.text, [List<Object?> parameters = const []])
    : parameters = List.unmodifiable(parameters);
  final String text;
  final List<Object?> parameters;
}

/// Ordered columns preserve duplicate names; values retain driver codec types.
final class SqlResult {
  SqlResult({
    List<String> columns = const [],
    List<List<Object?>> rows = const [],
    this.affectedRows = 0,
    this.insertId,
  }) : columns = List.unmodifiable(columns),
       rows = List.unmodifiable(rows.map((r) => List<Object?>.unmodifiable(r)));
  final List<String> columns;
  final List<List<Object?>> rows;
  final int affectedRows;
  final BigInt? insertId;
}

/// Extension boundary for native drivers, also usable by deterministic tests.
abstract interface class SqlConnection {
  bool get isOpen;
  Future<SqlResult> execute(SqlStatement statement);
  Future<void> close();

  /// Must settle active work before return, or do nothing and let it drain.
  Future<void> cancel();
}

abstract interface class SqlDriver {
  Future<SqlConnection> open();

  /// Null means a programming defect, not an expected driver error.
  SqlFailure? classify(Object error, String operation);
}

Cause<SqlFailure> _cause(SqlDriver driver, Object e, StackTrace s, String op) =>
    switch (driver.classify(e, op)) {
      final SqlFailure failure => Expected(failure),
      null => Defect(e, s),
    };
Exit<A, SqlFailure> _append<A>(
  Exit<A, SqlFailure> exit,
  Cause<SqlFailure> cause,
) => exit is Failure<A, SqlFailure>
    ? Failure(Sequential(exit.cause, cause))
    : Failure(cause);

/// Lazy bounded pool. Each lease owns one connection; queued acquisition is
/// interruptible. A canceled operation settles before its connection is reused.
final class SqlClient {
  SqlClient(this.driver, {this.maxConnections = 10})
    : _permits = Semaphore(maxConnections);
  final SqlDriver driver;
  final int maxConnections;
  final Semaphore _permits;
  final _idle = Queue<SqlConnection>();
  int _active = 0;
  bool _closed = false;
  Future<void>? _closing;
  Completer<void>? _drained;
  bool get isClosed => _closed;
  int get activeConnections => _active;
  int get idleConnections => _idle.length;

  Effect<A, SqlFailure, R> _lease<A, R>(
    Effect<A, SqlFailure, R> Function(SqlSession) use,
  ) => _permits.withPermits(
    1,
    Effect.asyncExit((ctx) async {
      if (_closed) {
        return const Failure(
          Expected(SqlFailure(SqlFailureKind.closed, 'acquire')),
        );
      }
      _active++;
      SqlConnection? connection;
      SqlSession? session;
      late Exit<A, SqlFailure> exit;
      try {
        while (_idle.isNotEmpty && connection == null) {
          final candidate = _idle.removeFirst();
          if (candidate.isOpen) {
            connection = candidate;
          } else {
            await candidate.close();
          }
        }
        // Protected acquisition: cancellation cannot orphan a newly opened socket.
        connection ??= await driver.open();
        session = SqlSession._(connection, driver);
        exit = await ctx.evaluate(Effect.defer(() => use(session!)).scoped());
      } catch (e, s) {
        exit = Failure(_cause(driver, e, s, 'acquire'));
      } finally {
        session?._valid = false;
      }
      if (connection != null) {
        if (_closed || !connection.isOpen || (session?._broken ?? false)) {
          try {
            await connection.close();
          } catch (e, s) {
            exit = _append(exit, _cause(driver, e, s, 'close'));
          }
        } else {
          _idle.add(connection);
        }
      }
      _active--;
      if (_active == 0) {
        _drained?.complete();
        _drained = null;
      }
      return exit;
    }),
  );

  Effect<SqlResult, SqlFailure, R> execute<R>(SqlStatement statement) =>
      _lease((s) => s.execute<R>(statement));
  Effect<A, SqlFailure, R> transaction<A, R>(
    Effect<A, SqlFailure, R> Function(SqlSession) body,
  ) => _lease((s) => s._transaction<A, R>(body, nested: false));

  /// Stop new work, close idle sockets, then await active leases and their cleanup.
  Future<void> shutdown() => _closing ??= _shutdown();
  Future<void> _shutdown() async {
    _closed = true;
    final idle = _idle.toList();
    _idle.clear();
    final failures = <Object>[];
    for (final c in idle) {
      try {
        await c.close();
      } catch (e) {
        failures.add(e);
      }
    }
    if (_active > 0) {
      _drained ??= Completer();
      await _drained!.future;
    }
    if (failures.isNotEmpty) throw failures.first;
  }

  Effect<Unit, SqlFailure, R> close<R>() => Effect.asyncExit((_) async {
    try {
      await shutdown();
      return const Success(Unit.value);
    } catch (e, s) {
      return Failure(_cause(driver, e, s, 'close'));
    }
  });
  Layer<SqlFailure> layer(ServiceKey<SqlClient> key) => Layer.resource(
    key,
    Effect.succeed<SqlClient, SqlFailure, Context>(this),
    (c) => c.close<Context>(),
  );
}

/// Borrowed transaction handle; expires when its callback's effect finishes.
/// Queries serialize. Nested transactions use savepoints on the same lease.
final class SqlSession {
  SqlSession._(this._connection, this._driver, [_Savepoints? savepoints])
    : _savepoints = savepoints ?? _Savepoints();
  final SqlConnection _connection;
  final SqlDriver _driver;
  final _lock = Semaphore(1);
  bool _valid = true, _broken = false;
  final _Savepoints _savepoints;
  Effect<SqlResult, SqlFailure, R> execute<R>(SqlStatement statement) =>
      _lock.withPermits(1, _execute<R>(statement));
  Effect<SqlResult, SqlFailure, R> _execute<R>(
    SqlStatement statement, {
    bool control = false,
  }) => Effect.asyncExit((ctx) async {
    if (!_valid || (_broken && !control) || !_connection.isOpen) {
      return const Failure(
        Expected(SqlFailure(SqlFailureKind.closed, 'execute')),
      );
    }
    final pending = Future<SqlResult>.sync(
      () => _connection.execute(statement),
    );
    // Attach a handler immediately; cancellation never leaves a rejected Future
    // unobserved. The abort hook is awaited before rollback/release can start.
    final settled = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final exit = await ctx.evaluate(
      Effect.fromFuture<SqlResult, SqlFailure, R>(
        () => pending,
        onCancel: () async {
          try {
            await _connection.cancel();
          } finally {
            await settled;
          }
        },
      ),
    );
    if (exit case Failure<SqlResult, SqlFailure>(
      cause: Defect(:final error, :final stackTrace),
    )) {
      return Failure(_cause(_driver, error, stackTrace, 'execute'));
    }
    return exit;
  });
  Effect<A, SqlFailure, R> transaction<A, R>(
    Effect<A, SqlFailure, R> Function(SqlSession) body,
  ) => _lock.withPermits(1, _transaction<A, R>(body, nested: true));
  Effect<A, SqlFailure, R> _transaction<A, R>(
    Effect<A, SqlFailure, R> Function(SqlSession) body, {
    required bool nested,
  }) => Effect.asyncExit((ctx) async {
    final savepoint = nested ? 'effect_sp_${++_savepoints.next}' : '';
    final begin = await ctx.masked().evaluate(
      _execute<R>(
        SqlStatement(nested ? 'SAVEPOINT $savepoint' : 'BEGIN'),
        control: true,
      ),
    );
    if (begin is Failure<SqlResult, SqlFailure>) {
      _broken = true;
      return Failure(begin.cause);
    }
    final child = SqlSession._(_connection, _driver, _savepoints);
    Exit<A, SqlFailure> exit = await ctx.evaluate(
      Effect.defer<A, SqlFailure, R>(() => body(child))
          .forkScoped()
          .flatMap((fiber) => fiber.join())
          .scoped(),
    );
    child._valid = false;
    _broken = _broken || child._broken;
    if (ctx.token.isCancelled && exit is Success<A, SqlFailure>) {
      exit = Failure<A, SqlFailure>(const Interrupted());
    }
    if (!_connection.isOpen) {
      _broken = true;
      return exit;
    }
    final success = exit is Success<A, SqlFailure>;
    final commands = success
        ? [nested ? 'RELEASE SAVEPOINT $savepoint' : 'COMMIT']
        : [
            nested ? 'ROLLBACK TO SAVEPOINT $savepoint' : 'ROLLBACK',
            if (nested) 'RELEASE SAVEPOINT $savepoint',
          ];
    // Once COMMIT starts it is protected: cancellation cannot imply undoing an
    // already committed write. A failed COMMIT has an uncertain durable outcome.
    for (final command in commands) {
      final done = await ctx.masked().evaluate(
        _execute<R>(SqlStatement(command), control: true),
      );
      if (done is Failure<SqlResult, SqlFailure>) {
        _broken = true;
        exit = _append(exit, done.cause);
        break;
      }
    }
    return exit;
  });
}

final class _Savepoints {
  int next = 0;
}
