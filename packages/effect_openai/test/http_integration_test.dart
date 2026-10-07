@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late HttpServer server;
  late Runtime<Unit> runtime;
  late EffectOpenAIClient ai;
  late Future<void> Function(HttpRequest) handler;
  final sockets = <Socket>[];
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    runtime = Runtime(Unit.value);
    ai = EffectOpenAIClient.create(
      OpenAIConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        authProvider: const ApiKeyProvider('local-fixture-key'),
        timeout: const Duration(seconds: 5),
        retryPolicy: const RetryPolicy(maxRetries: 0),
      ),
    );
    server.listen((request) async {
      await handler(request);
    });
  });
  tearDown(() async {
    await runtime.shutdown();
    await ai.shutdown();
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    await server.close(force: true);
  });
  CreateResponseRequest request() => CreateResponseRequest(
    model: 'fixture-model',
    input: ResponseInput.text('local test'),
  );

  Future<Socket> detach(
    HttpRequest request,
    Completer<void> closed, {
    bool headers = false,
  }) async {
    await request.drain<void>();
    request.response.headers.contentType = ContentType('text', 'event-stream');
    request.response.headers.chunkedTransferEncoding = false;
    final socket = await request.response.detachSocket(writeHeaders: headers);
    sockets.add(socket);
    socket.listen(
      (_) {},
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
    );
    return socket;
  }

  test('[HTTP01] real socket JSON request and typed SDK response', () async {
    handler = (r) async {
      expect(r.uri.path, '/v1/responses');
      expect(r.headers.value('authorization'), 'Bearer local-fixture-key');
      final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
      expect(body['input'], 'local test');
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode(responseJson()));
      await r.response.close();
    };
    expect(
      (await runtime.runFuture(ai.createResponse<Unit>(request()))).outputText,
      'Hello Effect',
    );
  });

  test('[HTTP02] request interruption closes socket before headers, sibling remains usable', () async {
    final started = Completer<void>();
    final closed = Completer<void>();
    var calls = 0;
    handler = (r) async {
      if (++calls == 1) {
        await detach(r, closed);
        started.complete();
      } else {
        await r.drain<void>();
        r.response.write(jsonEncode(responseJson()));
        await r.response.close();
      }
    };
    final fiber = runtime.fork(ai.createResponse<Unit>(request()));
    await started.future;
    expect(
      (await fiber.interruptAndAwait() as Failure).cause,
      isA<Interrupted>(),
    );
    await closed.future.timeout(const Duration(seconds: 3));
    expect(
      (await runtime.runFuture(ai.createResponse<Unit>(request()))).id,
      'resp_fixture',
    );
  });

  test('[HTTP03] actual SSE parser handles fragmented UTF8 and ordered typed events', () async {
    handler = (r) async {
      await r.drain<void>();
      r.response.headers.contentType = ContentType('text', 'event-stream');
      final bytes = utf8.encode(
        'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 0, 'content_index': 0, 'delta': 'नमस्ते 🌏', 'sequence_number': 1})}\n\ndata: [DONE]\n\n',
      );
      // Fragment the event and multi-byte characters over many socket writes.
      for (var i = 0; i < bytes.length; i += 3) {
        r.response.add(
          bytes.sublist(i, i + 3 < bytes.length ? i + 3 : bytes.length),
        );
        await r.response.flush();
      }
      await r.response.close();
    };
    final events = await runtime.runFuture(
      ai.streamResponse<Unit>(request()).run(Sink.collect()),
    );
    expect(events, hasLength(1));
    expect((events.single as OutputTextDeltaEvent).delta, 'नमस्ते 🌏');
    expect((events.single as OutputTextDeltaEvent).sequenceNumber, 1);
  });

  test('[HTTP04] early stream exit terminates real SSE connection', () async {
    final closed = Completer<void>();
    handler = (r) async {
      final socket = await detach(r, closed, headers: true);
      socket.add(
        utf8.encode(
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 0, 'content_index': 0, 'delta': 'first'})}\n\n',
        ),
      );
      await socket.flush();
    };
    final events = await runtime.runFuture(
      ai.streamResponse<Unit>(request()).take(1).run(Sink.collect()),
    );
    expect(events, hasLength(1));
    await closed.future.timeout(const Duration(seconds: 3));
  });

  test(
    '[HTTP05] stream interruption closes real socket before first headers',
    () async {
      final started = Completer<void>();
      final closed = Completer<void>();
      handler = (r) async {
        await detach(r, closed);
        started.complete();
      };
      final fiber = runtime.fork(
        ai.streamResponse<Unit>(request()).run(Sink.collect()),
      );
      await started.future;
      final cause = (await fiber.interruptAndAwait() as Failure).cause;
      expect(cause, isA<Interrupted>(), reason: describeCause(cause));
      await closed.future.timeout(const Duration(seconds: 3));
    },
  );

  test('[HTTP06] chat SSE retains delta and finish events', () async {
    handler = (r) async {
      expect(r.uri.path, '/v1/chat/completions');
      await r.drain<void>();
      r.response.headers.contentType = ContentType('text', 'event-stream');
      for (final (delta, reason) in [('hello', null), (null, 'stop')]) {
        r.response.write(
          'data: ${jsonEncode({
            'id': 'chat_fixture',
            'object': 'chat.completion.chunk',
            'created': 1,
            'model': 'fixture-model',
            'choices': [
              {
                'index': 0,
                'delta': {'content': delta},
                'finish_reason': reason,
              },
            ],
          })}\n\n',
        );
      }
      r.response.write('data: [DONE]\n\n');
      await r.response.close();
    };
    final events = await runtime.runFuture(
      ai
          .streamChatCompletion<Unit>(
            ChatCompletionCreateRequest(
              model: 'fixture-model',
              messages: [ChatMessage.user('Hi')],
            ),
          )
          .run(Sink.collect()),
    );
    expect(events, hasLength(2));
    expect(events.first.textDelta, 'hello');
  });

  test('[HTTP07] stream HTTP authentication failure is typed and reusable client survives', () async {
    var calls = 0;
    handler = (r) async {
      await r.drain<void>();
      if (++calls == 1) {
        r.response.statusCode = 401;
        r.response.write(
          jsonEncode({
            'error': {'message': 'secret key'},
          }),
        );
      } else {
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write('data: [DONE]\n\n');
      }
      await r.response.close();
    };
    final first = await runtime.runExit(
      ai.streamResponse<Unit>(request()).run(Sink.collect()),
    );
    final error = ((first as Failure).cause as Expected).error as OpenAIFailure;
    expect(error.kind, OpenAIFailureKind.authentication);
    expect(
      await runtime.runFuture(
        ai.streamResponse<Unit>(request()).run(Sink.collect()),
      ),
      isEmpty,
    );
  });

  test(
    '[HTTP08] runtime shutdown aborts actual active HTTP and awaits cleanup',
    () async {
      final started = Completer<void>();
      final closed = Completer<void>();
      handler = (r) async {
        await detach(r, closed);
        started.complete();
      };
      final result = runtime.runExit(ai.createResponse<Unit>(request()));
      await started.future;
      await runtime.shutdown();
      expect((await result as Failure).cause, isA<Interrupted>());
      await closed.future.timeout(const Duration(seconds: 3));
    },
  );
}

String describeCause(Cause<Object?> cause) => switch (cause) {
  Defect(:final error, :final stackTrace) => '$error\n$stackTrace',
  Sequential(:final first, :final second) =>
    '${describeCause(first)}\n${describeCause(second)}',
  _ => '$cause',
};
