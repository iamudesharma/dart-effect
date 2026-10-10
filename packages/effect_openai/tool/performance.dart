// Development-only measurements; never contacts OpenAI or reads a real API key.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

final responseBytes = utf8.encode(
  jsonEncode({
    'id': 'resp_benchmark',
    'object': 'response',
    'created_at': 1,
    'status': 'completed',
    'model': 'fixture-model',
    'output': [
      {
        'type': 'message',
        'id': 'msg_fixture',
        'role': 'assistant',
        'status': 'completed',
        'content': [
          {'type': 'output_text', 'text': 'café नमस्ते 😀', 'annotations': []},
        ],
      },
    ],
  }),
);

final class Fixture {
  late HttpServer server;
  final sockets = <Socket>{};
  final ready = <Completer<void>>[];
  final closed = <Completer<void>>[];
  int calls = 0, active = 0, peak = 0;
  String mode = 'request-json';
  Object? error;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      try {
        await handle(r);
      } catch (e) {
        error = e;
        await r.response.close();
      }
    });
  }

  OpenAIConfig config() => OpenAIConfig(
    baseUrl: 'http://127.0.0.1:${server.port}/v1',
    authProvider: const ApiKeyProvider('benchmark-fixture-not-a-key'),
    retryPolicy: const RetryPolicy(maxRetries: 0),
    timeout: const Duration(seconds: 5),
  );

  Future<void> handle(HttpRequest r) async {
    final call = calls++;
    active++;
    peak = max(peak, active);
    await r.drain<void>();
    if (mode == 'request-cancel' || mode == 'stream-early') {
      r.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      r.response.headers.chunkedTransferEncoding = false;
      final socket = await r.response.detachSocket(
        writeHeaders: mode == 'stream-early',
      );
      sockets.add(socket);
      final finished = closed.removeAt(0);
      socket.listen(
        (_) {},
        onDone: () {
          if (sockets.remove(socket)) active--;
          socket.destroy();
          if (!finished.isCompleted) finished.complete();
        },
        onError: (Object e) {
          if (sockets.remove(socket)) active--;
          socket.destroy();
          if (!finished.isCompleted) finished.complete();
        },
      );
      if (mode == 'stream-early') {
        socket.add(utf8.encode(event(0)));
        await socket.flush();
      }
      ready.removeAt(0).complete();
      return;
    }
    if (mode == 'request-delayed') {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (mode == 'failures') {
      r.response.statusCode = [401, 429, 500][call % 3];
      r.response.headers.contentType = ContentType.json;
      r.response.write(
        jsonEncode({
          'error': {'message': 'fixture-sensitive-message'},
        }),
      );
    } else if (mode == 'stream-fold') {
      r.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      for (var i = 0; i < 256; i++) {
        r.response.write(event(i));
      }
      r.response.write('data: [DONE]\n\n');
    } else {
      r.response.headers.contentType = ContentType.json;
      r.response.add(responseBytes);
    }
    await r.response.close();
    active--;
  }

  String event(int i) =>
      'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 0, 'content_index': 0, 'delta': 'café 😀', 'sequence_number': i})}\n\n';

  Future<void> dispose() async {
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    await server.close(force: true);
  }
}

final class Work {
  Work(this.fixture, this.effect)
    : sdk = OpenAIClient(config: fixture.config());
  final Fixture fixture;
  final bool effect;
  final OpenAIClient sdk;
  late final runtime = Runtime(Unit.value);
  late final ai = EffectOpenAIClient(sdk);
  final input = CreateResponseRequest(
    model: 'fixture-model',
    input: ResponseInput.text('fixture input'),
  );

  Future<void> request() async {
    final value = effect
        ? await runtime.runFuture(ai.createResponse<Unit>(input))
        : await sdk.responses.create(input);
    check(value.outputText == 'café नमस्ते 😀', 'JSON result mismatch');
  }

  Future<void> stream({bool early = false}) async {
    final done = Completer<void>();
    fixture.closed.add(done);
    fixture.ready.add(Completer<void>());
    var count = 0;
    if (effect) {
      final source = ai.streamResponse<Unit>(input);
      await runtime.runFuture(
        (early ? source.take(1) : source).runForEach((value) {
          check(
            value is OutputTextDeltaEvent && value.delta == 'café 😀',
            'SSE mismatch',
          );
          count++;
          return Effect.succeed<Unit, OpenAIFailure, Unit>(Unit.value);
        }),
      );
    } else {
      final abort = Completer<void>();
      final source = sdk.responses.createStream(
        input,
        abortTrigger: abort.future,
      );
      final iterator = StreamIterator(source);
      try {
        while (await iterator.moveNext()) {
          check(
            iterator.current is OutputTextDeltaEvent &&
                (iterator.current as OutputTextDeltaEvent).delta == 'café 😀',
            'SSE type/value',
          );
          count++;
          if (early) break;
        }
      } finally {
        if (early) abort.complete();
        try {
          await iterator.cancel();
        } on AbortedException {
          // Direct SDK baseline explicitly owns abort/cancel cleanup too.
        }
      }
    }
    if (early) {
      await done.future.timeout(const Duration(seconds: 3));
    } else {
      fixture.closed.remove(done);
      fixture.ready.removeLast();
    }
    check(count == (early ? 1 : 256), 'SSE count mismatch');
  }

  Future<void> cancel() async {
    final ready = Completer<void>();
    final closed = Completer<void>();
    fixture.ready.add(ready);
    fixture.closed.add(closed);
    if (effect) {
      final fiber = runtime.fork(ai.createResponse<Unit>(input));
      await ready.future;
      final exit = await fiber.interruptAndAwait();
      check(
        exit is Failure<Response, OpenAIFailure> && exit.cause is Interrupted,
        'interruption mismatch',
      );
    } else {
      final abort = Completer<void>();
      final result = sdk.responses
          .create(input, abortTrigger: abort.future)
          .then((_) => false, onError: (Object e) => e is AbortedException);
      await ready.future;
      abort.complete();
      check(await result, 'SDK abort mismatch');
    }
    await closed.future.timeout(const Duration(seconds: 3));
  }

  Future<void> failure() async {
    final expected = [
      OpenAIFailureKind.authentication,
      OpenAIFailureKind.rateLimit,
      OpenAIFailureKind.server,
    ][fixture.calls % 3];
    if (effect) {
      final exit = await runtime.runExit(ai.createResponse<Unit>(input));
      check(
        exit is Failure<Response, OpenAIFailure> &&
            exit.cause is Expected<OpenAIFailure>,
        'typed failure mismatch',
      );
      final e = ((exit as Failure).cause as Expected<OpenAIFailure>).error;
      check(
        e.kind == expected && !e.toString().contains('fixture-sensitive'),
        'failure kind/redaction',
      );
    } else {
      try {
        await sdk.responses.create(input);
        throw StateError('SDK failure missing');
      } on ApiException catch (e) {
        check(
          e.statusCode ==
              switch (expected) {
                OpenAIFailureKind.authentication => 401,
                OpenAIFailureKind.rateLimit => 429,
                _ => 500,
              },
          'SDK failure status',
        );
      }
    }
  }

  Future<void> batch(String mode) async {
    fixture.mode = mode;
    final before = fixture.calls;
    var expectedCalls = 0;
    switch (mode) {
      case 'bounded-8':
        expectedCalls = 200;
        if (effect) {
          await runtime.runFuture(
            Effect.traverse<int, int, OpenAIFailure, Unit>(
              List.generate(200, (i) => i),
              (i) => ai.createResponse<Unit>(input).map((r) {
                check(r.outputText == 'café नमस्ते 😀', 'bounded result');
                return i;
              }),
              concurrency: 8,
            ),
          );
        } else {
          var next = 0;
          await Future.wait(
            List.generate(8, (_) async {
              while (next < 200) {
                next++;
                await request();
              }
            }),
          );
        }
      case 'stream-fold':
        expectedCalls = 5;
        for (var i = 0; i < expectedCalls; i++) {
          await stream();
        }
      case 'stream-early':
        expectedCalls = 30;
        for (var i = 0; i < expectedCalls; i++) {
          await stream(early: true);
        }
      case 'request-cancel':
        expectedCalls = 30;
        for (var i = 0; i < expectedCalls; i++) {
          await cancel();
        }
      case 'failures':
        expectedCalls = 100;
        for (var i = 0; i < expectedCalls; i++) {
          await failure();
        }
      default:
        expectedCalls = mode == 'request-delayed' ? 20 : 100;
        for (var i = 0; i < expectedCalls; i++) {
          await request();
        }
    }
    // Server close can settle one event turn after receipt of a completed body.
    await Future<void>.delayed(Duration.zero);
    check(
      fixture.calls - before == expectedCalls,
      'unexpected replay/request count',
    );
    check(
      fixture.error == null && fixture.active == 0 && fixture.sockets.isEmpty,
      'server cleanup',
    );
    if (mode == 'bounded-8') check(fixture.peak <= 8, 'concurrency bound');
  }

  Future<void> dispose() async {
    if (effect) {
      await runtime.shutdown();
      await ai.shutdown();
    }
    sdk.close();
  }
}

final class Profile {
  Profile(this.socket) {
    socket.listen((message) {
      final value = jsonDecode(message as String) as Map<String, dynamic>;
      final waiter = pending.remove(value['id']);
      if (value.containsKey('error')) {
        waiter?.completeError(StateError('VM profile RPC failed'));
      } else {
        waiter?.complete(value['result'] as Map<String, dynamic>);
      }
    });
  }
  final WebSocket socket;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  int next = 0;
  Future<Map<String, dynamic>> rpc(String method, Map<String, dynamic> params) {
    final id = ++next;
    final waiter = Completer<Map<String, dynamic>>();
    pending[id] = waiter;
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return waiter.future.timeout(const Duration(seconds: 10));
  }

  Future<Map<String, Object?>> snapshot() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    stderr.writeln('heap snapshot');
    final profile = await rpc('getAllocationProfile', {
      'isolateId': developer.Service.getIsolateId(Isolate.current),
      'gc': true,
    });
    final counts = <String, Object?>{};
    for (final entry in profile['members'] as List) {
      final name = (entry['class'] as Map)['name'] as String;
      if ([
        '_Operation',
        'Fiber',
        'FiberContext',
        'Scope',
        'EffectOpenAIClient',
        'OpenAIClient',
        'StreamController',
        'Response',
      ].contains(name)) {
        counts[name] = {
          'instances': entry['instancesCurrent'],
          'bytes': entry['bytesCurrent'],
        };
      }
    }
    return {
      'heap': profile['memoryUsage'],
      'classes': counts,
      'gcTimestamp': profile['dateLastServiceGC'],
      'rssBytes': ProcessInfo.currentRss,
    };
  }
}

@pragma('vm:never-inline')
Future<List<WeakReference<Object>>> churn(Fixture fixture) async {
  final refs = <WeakReference<Object>>[];
  for (var i = 0; i < 30; i++) {
    final work = Work(fixture, true);
    refs.add(WeakReference(work.ai));
    refs.add(WeakReference(work.runtime));
    final payload = Uint8List(256 * 1024);
    refs.add(WeakReference(payload));
    final value = await work.runtime.runFuture(
      work.ai.request<int, Unit>((_, _) async => payload.length),
    );
    check(value == 256 * 1024, 'payload result');
    await work.dispose();
  }
  return refs;
}

Future<void> main(List<String> args) async {
  final mode = args[0];
  final effect = args[1] == 'effect';
  final fixture = Fixture();
  await fixture.start();
  final work = Work(fixture, effect);
  try {
    if (mode == 'memory') {
      final info = await developer.Service.getInfo();
      check(info.serverUri != null, 'Start with --enable-vm-service=0');
      final uri = info.serverUri!.replace(
        scheme: 'ws',
        path: '${info.serverUri!.path}ws',
      );
      final profile = Profile(await WebSocket.connect(uri.toString()));
      try {
        for (final scenario in [
          'request-json',
          'stream-fold',
          'request-cancel',
          'stream-early',
          'failures',
        ]) {
          stderr.writeln("memory batch: $scenario");
          await work.batch(scenario);
        }
        final snapshots = <Map<String, Object?>>[await profile.snapshot()];
        var dead = 0;
        for (var i = 0; i < 6; i++) {
          for (final scenario in [
            'request-json',
            'stream-fold',
            'request-cancel',
            'stream-early',
            'failures',
          ]) {
            stderr.writeln("memory batch: $scenario");
            await work.batch(scenario);
          }
          final refs = effect
              ? await churn(fixture)
              : <WeakReference<Object>>[];
          snapshots.add(await profile.snapshot());
          check(
            refs.every((ref) => ref.target == null),
            'closed owner/payload retained after requested GC',
          );
          dead += refs.length;
        }
        final positive = Uint8List(256 * 1024);
        final control = WeakReference<Object>(positive);
        await profile.snapshot();
        check(
          control.target != null && positive.length == 256 * 1024,
          'positive weak-reference control',
        );
        print(
          jsonEncode({
            'mode': 'JIT-heap-diagnostic',
            'implementation': effect ? 'effect' : 'sdk',
            'snapshots': snapshots,
            'collectedWeakReferences': dead,
            'positiveControlRetained': true,
            'requests': fixture.calls,
            'openFixtureSockets': fixture.sockets.length,
            'note': 'Requested GC is diagnostic and not timed. Heap is main-isolate used/capacity/external; RSS includes VM/compiler/service/server. Fixed finite run is not universal leak freedom.',
          }),
        );
      } finally {
        await profile.socket.close();
      }
    } else {
      for (var i = 0; i < 3; i++) {
        await work.batch(mode);
      }
      final samples = <int>[];
      for (var i = 0; i < 9; i++) {
        final timer = Stopwatch()..start();
        await work.batch(mode);
        samples.add(timer.elapsedMicroseconds);
      }
      print(
        jsonEncode({
          'mode': const bool.fromEnvironment('benchmark.aot') ? 'AOT' : 'JIT',
          'implementation': effect ? 'effect' : 'sdk',
          'workload': mode,
          'samplesMicros': samples,
          'warmups': 3,
          'requests': fixture.calls,
          'peakServerRequests': fixture.peak,
          'rssBytes': ProcessInfo.currentRss,
          'maxRssBytes': ProcessInfo.maxRss,
          'openFixtureSockets': fixture.sockets.length,
        }),
      );
    }
  } finally {
    await work.dispose();
    await fixture.dispose();
  }
}
