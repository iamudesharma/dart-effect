import 'dart:async';
import 'dart:convert';

import 'package:effect_core/effect_core.dart';
import 'package:effect_http/effect_http.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

final class FixtureClient extends http.BaseClient {
  FixtureClient(this.response);
  final Future<http.StreamedResponse> Function(http.BaseRequest) response;
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    return response(request);
  }
}

void main() {
  test('HTTP re-executes with immutable results and borrowed client', () async {
    final client = FixtureClient(
      (_) async => http.StreamedResponse(Stream.value(utf8.encode('ok')), 200),
    );
    final rt = Runtime(Unit.value), adapter = EffectHttp(client);
    final request = adapter.request<Unit>(
      'GET',
      Uri.parse('https://fixture.test'),
    );
    expect(client.calls, 0);
    final result = await rt.runFuture(request);
    expect(result.text, 'ok');
    expect(() => result.body.add(3), throwsUnsupportedError);
    await rt.runFuture(request);
    expect(client.calls, 2);
    await rt.shutdown();
    client.close();
  });
  test('SSE wrong MIME, status and UTF8 are typed failures', () async {
    for (final fixture in [
      (200, 'application/json', <int>[1]),
      (503, 'text/event-stream', <int>[]),
      (200, 'text/event-stream', <int>[0xff]),
    ]) {
      final client = FixtureClient(
        (_) async => http.StreamedResponse(
          Stream.value(fixture.$3),
          fixture.$1,
          headers: {'content-type': fixture.$2},
        ),
      );
      final rt = Runtime(Unit.value);
      final exit = await rt.runExit(
        EffectHttp(client)
            .sse<Unit>(Uri.parse('https://fixture.test'))
            .runCollect(),
      );
      expect(
        (exit as Failure<List<SseEvent>, HttpFailure>).cause,
        isA<Expected<HttpFailure>>(),
      );
      await rt.shutdown();
      client.close();
    }
  });
  test(
    'SSE is lazy, re-executable, discards EOF fragment and retains empty data',
    () async {
      final client = FixtureClient(
        (_) async => http.StreamedResponse(
          Stream.value(utf8.encode('data:\n\ndata: incomplete')),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      final rt = Runtime(Unit.value);
      final stream = EffectHttp(client)
          .sse<Unit>(Uri.parse('https://fixture.test'));
      expect(client.calls, 0);
      for (var i = 0; i < 2; i++) {
        final result = await rt.runFuture(stream.runCollect());
        expect(result.single.data, '');
      }
      expect(client.calls, 2);
      await rt.shutdown();
      client.close();
    },
  );
  test('request cancellation completes AbortableRequest trigger', () async {
    final started = Completer<http.AbortableRequest>();
    final client = FixtureClient((request) async {
      started.complete(request as http.AbortableRequest);
      await request.abortTrigger;
      throw http.RequestAbortedException(request.url);
    });
    final rt = Runtime(Unit.value);
    final fiber = rt.fork(
      EffectHttp(client)
          .request<Unit>('POST', Uri.parse('https://fixture.test')),
    );
    final request = await started.future;
    final exit = await fiber.interruptAndAwait();
    await request.abortTrigger;
    expect(
      (exit as Failure<HttpResult, HttpFailure>).cause,
      isA<Interrupted<HttpFailure>>(),
    );
    expect(client.calls, 1);
    await rt.shutdown();
    client.close();
  });
}
