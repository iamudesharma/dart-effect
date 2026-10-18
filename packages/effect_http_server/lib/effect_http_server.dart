/// Native scoped Effect request handlers with bounded bodies and admission.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';

final class ServerFailure {
  const ServerFailure(this.status, this.message);
  final int status;
  final String message;
}

final class ServerRequest {
  ServerRequest(
    this.method,
    this.uri,
    Iterable<int> body,
    Map<String, String> headers,
  ) : body = List.unmodifiable(body),
      headers = Map.unmodifiable(headers);
  final String method;
  final Uri uri;
  final List<int> body;
  final Map<String, String> headers;
  Effect<T, ServerFailure, R> json<T, R>(Schema<T> schema) => Effect.defer(() {
    Object? value;
    try {
      value = jsonDecode(utf8.decode(body));
    } catch (_) {
      return Effect.fail(const ServerFailure(400, 'Invalid JSON'));
    }
    return schema
        .decodeEffect<R>(value)
        .mapError(
          (_) => const ServerFailure(400, 'Request schema rejected input'),
        );
  });
}

final class ServerResponse {
  ServerResponse(
    this.status,
    Iterable<int> body, {
    Map<String, String> headers = const {},
  }) : body = List.unmodifiable(body),
       headers = Map.unmodifiable(headers);
  factory ServerResponse.json(Object? value, {int status = 200}) =>
      ServerResponse(
        status,
        utf8.encode(jsonEncode(value)),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
  final int status;
  final List<int> body;
  final Map<String, String> headers;
}

typedef EffectHandler<R> = Effect<ServerResponse, ServerFailure, R> Function(
  ServerRequest request,
);

final class EffectRouter<R> {
  final _routes = <(String, String), EffectHandler<R>>{};
  void add(String method, String path, EffectHandler<R> handler) {
    final key = (method.toUpperCase(), path);
    if (_routes.containsKey(key)) throw ArgumentError('Duplicate route');
    _routes[key] = handler;
  }

  Effect<ServerResponse, ServerFailure, R> call(ServerRequest request) =>
      Effect.defer(
        () =>
            _routes[(request.method, request.uri.path)]?.call(request) ??
            Effect.fail(const ServerFailure(404, 'Not found')),
      );
}

/// Owns its runtime. Close stops admission, interrupts requests, awaits their
/// protected cleanup and closes sockets. No TLS termination or proxy trust policy.
final class EffectHttpServer<R> {
  EffectHttpServer._(
    this._server,
    this._runtime,
    this._permits,
    this.maxPending,
    this.maxBodyBytes,
    this.handler,
  ) {
    _subscription = _server.listen(_accept);
  }
  final HttpServer _server;
  final Runtime<R> _runtime;
  final Semaphore _permits;
  final int maxPending, maxBodyBytes;
  final EffectHandler<R> handler;
  late final StreamSubscription<HttpRequest> _subscription;
  int _pending = 0;
  Future<void>? _closing;
  int get port => _server.port;
  static Future<EffectHttpServer<R>> bind<R>(
    R environment,
    EffectHandler<R> handler, {
    InternetAddress? address,
    int port = 0,
    int concurrency = 32,
    int maxPending = 1024,
    int maxBodyBytes = 1024 * 1024,
  }) async {
    if (concurrency < 1 || maxPending < 1 || maxBodyBytes < 1) {
      throw ArgumentError('Invalid server bounds');
    }
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    return EffectHttpServer._(
      server,
      Runtime(environment),
      Semaphore(concurrency),
      maxPending,
      maxBodyBytes,
      handler,
    );
  }

  void _accept(HttpRequest request) {
    if (_closing != null || _pending >= maxPending) {
      request.response.statusCode = 503;
      request.response.close();
      return;
    }
    _pending++;
    final effect = _permits.withPermits<ServerResponse, ServerFailure, R>(
      1,
      Effect.asyncExit((ctx) async {
        final iterator = StreamIterator(request);
        final bytes = <int>[];
        try {
          while (true) {
            final moved = await ctx.evaluate(
              Effect.fromFuture<bool, ServerFailure, R>(
                iterator.moveNext,
                onCancel: iterator.cancel,
                onError: (_, _) =>
                    const ServerFailure(400, 'Body transfer failed'),
              ),
            );
            if (moved is Failure<bool, ServerFailure>) {
              return Failure(moved.cause);
            }
            if (!(moved as Success<bool, ServerFailure>).value) break;
            if (bytes.length + iterator.current.length > maxBodyBytes) {
              return const Failure(
                Expected(ServerFailure(413, 'Body limit exceeded')),
              );
            }
            bytes.addAll(iterator.current);
          }
          final headers = <String, String>{};
          request.headers.forEach((k, v) => headers[k] = v.join(','));
          return await ctx.evaluate(
            Effect.defer(
              () => handler(
                ServerRequest(request.method, request.uri, bytes, headers),
              ),
            ),
          );
        } finally {
          await iterator.cancel();
        }
      }),
    );
    final fiber = _runtime.fork(effect);
    unawaited(() async {
      try {
        final exit = await fiber.awaitExit();
        final response = switch (exit) {
          Success(:final value) => value,
          Failure(:final cause) =>
            cause is Expected<ServerFailure>
                ? ServerResponse.json({
                    'error': cause.error.message,
                  }, status: cause.error.status)
                : ServerResponse.json({
                    'error': 'Internal server error',
                  }, status: 500),
        };
        request.response.statusCode = response.status;
        response.headers.forEach((k, v) => request.response.headers.set(k, v));
        request.response.add(response.body);
        await request.response.close();
      } catch (_) {
        try {
          await request.response.close();
        } catch (_) {
          /* Peer disconnected. */
        }
      } finally {
        _pending--;
      }
    }());
  }

  Future<void> close() => _closing ??= Future(() async {
    await _runtime.shutdown();
    await _server.close(force: true);
    await _subscription.cancel();
  });
}
