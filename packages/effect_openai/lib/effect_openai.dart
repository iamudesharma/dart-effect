/// Lazy Effect integration for the typed openai_dart SDK.
library;

import 'dart:async';

import 'package:effect_core/effect_core.dart';
import 'package:openai_dart/openai_dart.dart' as sdk;

export 'package:openai_dart/openai_dart.dart';

enum OpenAIFailureKind {
  authentication,
  permission,
  notFound,
  invalidRequest,
  conflict,
  rateLimit,
  server,
  timeout,
  connection,
  decoding,
  api,
  closed,
}

/// Safe summary; [cause] may contain credentials, prompt text or response bodies.
final class OpenAIFailure implements Exception {
  const OpenAIFailure({
    required this.kind,
    required this.operation,
    this.statusCode,
    this.requestId,
    this.code,
    this.retryAfter,
    this.cause,
  });
  final OpenAIFailureKind kind;
  final String operation;
  final int? statusCode;
  final String? requestId;
  final String? code;
  final Duration? retryAfter;
  final Object? cause;

  @override
  String toString() => 'OpenAIFailure(${kind.name}, status: $statusCode)';
}

Cause<OpenAIFailure> _cause(Object error, StackTrace stack, String operation) {
  if (error is sdk.AbortedException) return const Interrupted();
  if (error is! sdk.OpenAIException) return Defect(error, stack);
  final api = error is sdk.ApiException ? error : null;
  final kind = switch (error) {
    sdk.RequestTimeoutException() => OpenAIFailureKind.timeout,
    sdk.ConnectionException() => OpenAIFailureKind.connection,
    sdk.ParseException() => OpenAIFailureKind.decoding,
    sdk.ApiException(:final statusCode) => switch (statusCode) {
      401 => OpenAIFailureKind.authentication,
      403 => OpenAIFailureKind.permission,
      404 => OpenAIFailureKind.notFound,
      400 || 422 => OpenAIFailureKind.invalidRequest,
      409 => OpenAIFailureKind.conflict,
      429 => OpenAIFailureKind.rateLimit,
      >= 500 && < 600 => OpenAIFailureKind.server,
      _ => OpenAIFailureKind.api,
    },
    _ => OpenAIFailureKind.api,
  };
  return Expected(
    OpenAIFailure(
      kind: kind,
      operation: operation,
      statusCode: api?.statusCode,
      requestId: api?.requestId,
      code: api?.code,
      retryAfter: error is sdk.RateLimitException ? error.retryAfter : null,
      cause: error,
    ),
  );
}

final class _Operation {
  final abort = Completer<void>();
  final done = Completer<void>();
  Future<void> Function()? cancelStream;
  Future<void>? _stopping;
  void signal() {
    if (!abort.isCompleted) abort.complete();
  }

  Future<void> stop() => _stopping ??= Future<void>.sync(() async {
    signal();
    final cancel = cancelStream;
    if (cancel != null) await cancel();
    await done.future;
  });
  void finish() {
    if (!done.isCompleted) done.complete();
  }
}

/// One application-scoped SDK client. Every run gets its own abort trigger.
///
/// The direct constructor borrows [client] unless [closeClient] is true.
/// Interruption signals abort and awaits completion/cancellation. Custom callbacks
/// must forward the abort trigger, or cancellation waits for their work to finish.
final class EffectOpenAIClient {
  EffectOpenAIClient(this._client, {this.closeClient = false});

  factory EffectOpenAIClient.create(sdk.OpenAIConfig config) =>
      EffectOpenAIClient(sdk.OpenAIClient(config: config), closeClient: true);

  final sdk.OpenAIClient _client;
  final bool closeClient;
  final Set<_Operation> _active = {};
  bool _closed = false;
  Future<void>? _shutdown;

  /// Fresh owned client per construction scope. The SDK's injected HTTP clients
  /// retain their SDK-defined ownership; close those separately if necessary.
  static Layer<OpenAIFailure> layer(
    ServiceKey<EffectOpenAIClient> key,
    sdk.OpenAIClient Function() create, {
    bool closeClient = true,
  }) => Layer.resource(
    key,
    Effect.sync<EffectOpenAIClient, OpenAIFailure, Context>(
      () => EffectOpenAIClient(create(), closeClient: closeClient),
    ),
    (client) => Effect.fromFuture<Object?, OpenAIFailure, Context>(() async {
      await client.shutdown();
      return null;
    }),
  );

  /// Wrap any SDK Future endpoint, retaining its original typed result.
  /// SDK failures are expected; callback/programming errors remain defects.
  Effect<A, OpenAIFailure, R> request<A, R>(
    Future<A> Function(sdk.OpenAIClient client, Future<void> abort) run, {
    String operation = 'request',
  }) => Effect.asyncExit((ctx) async {
    if (_closed) return _closedExit<A>(operation);
    final active = _Operation();
    _active.add(active);
    final future = Future<A>.sync(() => run(_client, active.abort.future))
        .then<Exit<A, OpenAIFailure>>(
          (value) => Success(value),
          onError: (Object e, StackTrace s) =>
              Failure<A, OpenAIFailure>(_cause(e, s, operation)),
        )
        .whenComplete(active.finish);
    try {
      final waited = await ctx.evaluate(
        Effect.fromFuture<Exit<A, OpenAIFailure>, OpenAIFailure, R>(
          () => future,
          onCancel: active.stop,
        ),
      );
      return waited is Success<Exit<A, OpenAIFailure>, OpenAIFailure>
          ? waited.value
          : Failure(
              (waited as Failure<Exit<A, OpenAIFailure>, OpenAIFailure>).cause,
            );
    } finally {
      _active.remove(active);
    }
  });

  /// Lazy, reusable stream with pause/resume and abort-before-cancel cleanup.
  /// No automatic retry or replay is performed after emitted events.
  EffectStream<A, OpenAIFailure, R> stream<A, R>(
    Stream<A> Function(sdk.OpenAIClient client, Future<void> abort) run, {
    String operation = 'stream',
  }) => EffectStream.acquireRelease<_Operation, A, OpenAIFailure, R>(
    Effect.asyncExit((_) {
      if (_closed) return _closedExit<_Operation>(operation);
      final active = _Operation();
      active.cancelStream = () async {
        active.finish();
      };
      _active.add(active);
      return Success(active);
    }),
    (active) => Effect.fromFuture<Object?, OpenAIFailure, R>(() async {
      try {
        await active.stop();
      } finally {
        _active.remove(active);
      }
      return null;
    }),
    (active) =>
        EffectStream.fromNative<Exit<A, OpenAIFailure>, OpenAIFailure, R>(
          () => _native(active, run, operation),
        ).mapEffect((exit) => Effect.asyncExit((_) => exit)),
  );

  Stream<Exit<A, OpenAIFailure>> _native<A>(
    _Operation active,
    Stream<A> Function(sdk.OpenAIClient, Future<void>) run,
    String operation,
  ) {
    StreamSubscription<A>? subscription;
    late StreamController<Exit<A, OpenAIFailure>> controller;
    Future<void>? cancelling;
    Future<void> cancel() => cancelling ??= Future<void>.sync(() async {
      active.signal();
      try {
        await subscription?.cancel();
      } on sdk.AbortedException {
        // SDK cancellation before headers can reject cancel() with this abort.
        // The abort was requested above; it is not a cleanup defect.
      } finally {
        // Manual adapter shutdown must not report a truncated stream as success.
        if (!controller.isClosed && controller.hasListener) {
          controller.add(const Failure(Interrupted()));
        }
        // Do not await close: a paused consumer may never demand another event.
        unawaited(controller.close());
        active.finish();
      }
    });
    active.cancelStream = cancel;
    controller = StreamController<Exit<A, OpenAIFailure>>(
      sync: true,
      onListen: () {
        try {
          if (active.abort.isCompleted) {
            controller.add(const Failure(Interrupted()));
            active.finish();
            unawaited(controller.close());
            return;
          }
          subscription = run(_client, active.abort.future).listen(
            (value) => controller.add(Success(value)),
            onError: (Object e, StackTrace s) {
              controller.add(Failure(_cause(e, s, operation)));
            },
            onDone: () {
              active.finish();
              unawaited(controller.close());
            },
          );
        } catch (e, s) {
          controller.add(Failure(_cause(e, s, operation)));
          active.finish();
          unawaited(controller.close());
        }
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: cancel,
    );
    return controller.stream;
  }

  Failure<A, OpenAIFailure> _closedExit<A>(String operation) => Failure(
    Expected(
      OpenAIFailure(kind: OpenAIFailureKind.closed, operation: operation),
    ),
  );

  /// Reject new work, abort/drain active work, then close an owned SDK client.
  /// Await runtime.shutdown first when requests belong to that runtime.
  Future<void> shutdown() {
    _closed = true;
    return _shutdown ??= Future<void>.sync(() async {
      final active = _active.toList();
      for (final operation in active) {
        operation.signal();
      }
      try {
        await Future.wait(active.map((operation) => operation.stop()));
      } finally {
        if (closeClient) _client.close();
      }
    });
  }

  Effect<sdk.Response, OpenAIFailure, R> createResponse<R>(
    sdk.CreateResponseRequest request,
  ) => this.request(
    (client, abort) => client.responses.create(request, abortTrigger: abort),
    operation: 'responses.create',
  );

  Effect<sdk.Response, OpenAIFailure, R> retrieveResponse<R>(String id) =>
      request(
        (client, abort) => client.responses.retrieve(id, abortTrigger: abort),
        operation: 'responses.retrieve',
      );

  /// Explicit server cancellation for background responses, separate from
  /// cancelling the local transport/fiber.
  Effect<sdk.Response, OpenAIFailure, R> cancelResponse<R>(String id) =>
      request(
        (client, abort) => client.responses.cancel(id, abortTrigger: abort),
        operation: 'responses.cancel',
      );

  EffectStream<sdk.ResponseStreamEvent, OpenAIFailure, R> streamResponse<R>(
    sdk.CreateResponseRequest request,
  ) => stream(
    (client, abort) =>
        client.responses.createStream(request, abortTrigger: abort),
    operation: 'responses.stream',
  );

  Effect<sdk.ChatCompletion, OpenAIFailure, R> createChatCompletion<R>(
    sdk.ChatCompletionCreateRequest request,
  ) => this.request(
    (client, abort) =>
        client.chat.completions.create(request, abortTrigger: abort),
    operation: 'chat.create',
  );

  EffectStream<sdk.ChatStreamEvent, OpenAIFailure, R> streamChatCompletion<R>(
    sdk.ChatCompletionCreateRequest request,
  ) => stream(
    (client, abort) =>
        client.chat.completions.createStream(request, abortTrigger: abort),
    operation: 'chat.stream',
  );

  Effect<sdk.EmbeddingResponse, OpenAIFailure, R> createEmbedding<R>(
    sdk.EmbeddingRequest request,
  ) => this.request(
    (client, abort) => client.embeddings.create(request, abortTrigger: abort),
    operation: 'embeddings.create',
  );

  Effect<sdk.ModerationResponse, OpenAIFailure, R> createModeration<R>(
    sdk.ModerationRequest request,
  ) => this.request(
    (client, abort) => client.moderations.create(request, abortTrigger: abort),
    operation: 'moderations.create',
  );
}
