import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_http/effect_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('Retry-After parses delta, HTTP date, past date and invalid input', () {
    final now = DateTime.utc(2026, 10, 11, 12);
    expect(parseRetryAfter('3', now), const Duration(seconds: 3));
    expect(
      parseRetryAfter('Sun, 11 Oct 2026 12:00:05 GMT', now),
      const Duration(seconds: 5),
    );
    expect(
      parseRetryAfter('Sun, 11 Oct 2026 11:00:05 GMT', now),
      Duration.zero,
    );
    expect(parseRetryAfter('invalid', now), null);
    expect(parseRetryAfter('-1', now), null);
    expect(parseRetryAfter('Sun, 32 Oct 2026 11:00:05 GMT', now), null);
  });
  test(
    'lazy re-execution, typed status, no write replay, bounded body',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response(
          'hello',
          requests == 2 ? 429 : 200,
          headers: {'retry-after': '3'},
        );
      });
      final adapter = EffectHttp(client, maxBodyBytes: 4),
          rt = Runtime(Unit.value);
      final effect = adapter.request<Unit>(
        'POST',
        Uri.parse('https://fixture.test'),
      );
      expect(requests, 0);
      expect(await rt.runExit(effect), isA<Failure<HttpResult, HttpFailure>>());
      final failure =
          (await rt.runExit(effect) as Failure<HttpResult, HttpFailure>).cause
              as Expected<HttpFailure>;
      expect(failure.error.status, 429);
      expect(
        failure.error.retryDelay(DateTime.utc(2026)),
        const Duration(seconds: 3),
      );
      expect(requests, 2);
      client.close();
      await rt.shutdown();
    },
  );
  test('actual HTTP request and body cancellation before headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>();
    server.listen((request) {
      started.complete();
    });
    final client = http.Client(), rt = Runtime(Unit.value);
    try {
      final fiber = rt.fork(
        EffectHttp(
          client,
        ).request<Unit>('GET', Uri.parse('http://127.0.0.1:${server.port}/')),
      );
      await started.future;
      expect(
        await fiber.interruptAndAwait().timeout(const Duration(seconds: 2)),
        isA<Failure<HttpResult, HttpFailure>>(),
      );
    } finally {
      client.close();
      await server.close(force: true);
      await rt.shutdown();
    }
  });
  test(
    'SSE handles split UTF8, CRLF, comments, multiline data, id and retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.set(
          'content-type',
          'text/event-stream; charset=utf-8',
        );
        final bytes = utf8.encode(
          '\ufeff: comment\r\nid: 7\r\nretry: 12\r\nevent: token\r\ndata: café\r\ndata: two\r\n\r\ndata: done\n\n',
        );
        for (final byte in bytes) {
          request.response.add([byte]);
          await request.response.flush();
        }
        await request.response.close();
      });
      final client = http.Client(), rt = Runtime(Unit.value);
      try {
        final events = await rt.runFuture(
          EffectHttp(client)
              .sse<Unit>(Uri.parse('http://127.0.0.1:${server.port}'))
              .runCollect(),
        );
        expect(events.length, 2);
        expect(events[0].data, 'café\ntwo');
        expect(events[0].event, 'token');
        expect(events[0].id, '7');
        expect(events[0].retry, const Duration(milliseconds: 12));
        expect(events[1].id, '7');
      } finally {
        client.close();
        await server.close(force: true);
        await rt.shutdown();
      }
    },
  );
  test(
    'SSE cancellation while waiting for headers aborts without hanging',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      server.listen((request) {
        started.complete();
      });
      final client = http.Client(), rt = Runtime(Unit.value);
      try {
        final fiber = rt.fork(
          EffectHttp(client)
              .sse<Unit>(Uri.parse('http://127.0.0.1:${server.port}'))
              .runCollect(),
        );
        await started.future;
        expect(
          await fiber.interruptAndAwait().timeout(const Duration(seconds: 2)),
          isA<Failure<List<SseEvent>, HttpFailure>>(),
        );
      } finally {
        client.close();
        await server.close(force: true);
        await rt.shutdown();
      }
    },
  );
  test(
    'SSE early stop aborts transport and bounded malformed events fail',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.set('content-type', 'text/event-stream');
        request.response.bufferOutput = false;
        request.response.write('data: first\n\n');
        await request.response.flush();
        if (request.uri.path == '/limit') {
          request.response.write('data: ${'x' * 100}\n\n');
          await request.response.close();
        }
      });
      final client = http.Client(), rt = Runtime(Unit.value);
      try {
        final url = Uri.parse('http://127.0.0.1:${server.port}');
        final first = await rt
            .runFuture(
              EffectHttp(client)
                  .sse<Unit>(url)
                  .run(Sink.first<SseEvent, HttpFailure, Unit>()),
            )
            .timeout(const Duration(seconds: 2));
        expect(first!.$1.data, 'first');
        final exit = await rt.runExit(
          EffectHttp(
            client,
            maxEventCharacters: 16,
          ).sse<Unit>(url.resolve('/limit')).runCollect(),
        );
        expect(
          (exit as Failure<List<SseEvent>, HttpFailure>).cause,
          isA<Expected<HttpFailure>>(),
        );
      } finally {
        client.close();
        await server.close(force: true);
        await rt.shutdown();
      }
    },
  );
}
