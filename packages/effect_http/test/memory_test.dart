import 'dart:async';
import 'dart:typed_data';

import 'package:effect_core/effect_core.dart';
import 'package:effect_http/effect_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('response uses immutable packed defensive bytes', () {
    final input = Uint8List(1024 * 1024)..[0] = 42;
    final result = HttpResult(200, {}, input);
    expect(result.body, isA<Uint8List>());
    input[0] = 7;
    expect(result.body[0], 42);
    expect(() => result.body[0] = 8, throwsUnsupportedError);
  });
  test(
    'concurrent request limit rejects before transport and releases on failure',
    () async {
      final started = Completer<void>(),
          response = Completer<http.StreamedResponse>();
      var calls = 0;
      final transport = MockClient.streaming((_, _) {
        calls++;
        started.complete();
        return response.future;
      });
      final api = EffectHttp(transport, maxConcurrentRequests: 1),
          rt = Runtime(Unit.value);
      final first = rt.fork(
        api.request<Unit>('GET', Uri.parse('https://fixture.test')),
      );
      await started.future;
      expect(
        await rt.runExit(
          api.request<Unit>('GET', Uri.parse('https://fixture.test')),
        ),
        isA<Failure<HttpResult, HttpFailure>>(),
      );
      expect(calls, 1);
      expect(api.activeRequests, 1);
      response.complete(http.StreamedResponse(Stream.value([1, 2]), 500));
      await first.awaitExit();
      expect(api.activeRequests, 0);
      expect(api.bufferedBytes, 0);
      await rt.shutdown();
      transport.close();
    },
  );
  test('aggregate bytes bound overlapping accumulators and recover after rejection', () async {
    final firstChunk = Completer<void>(), release = Completer<void>();
    Stream<List<int>> body() async* {
      yield [1, 2, 3];
      firstChunk.complete();
      await release.future;
    }

    var calls = 0;
    final transport = MockClient.streaming(
      (_, _) async => http.StreamedResponse(
        ++calls == 1 ? body() : Stream.value([4, 5, 6]),
        200,
      ),
    );
    final api = EffectHttp(transport, maxBufferedBytes: 5),
        rt = Runtime(Unit.value);
    final first = rt.fork(
      api.request<Unit>('GET', Uri.parse('https://fixture.test')),
    );
    await firstChunk.future;
    expect(api.bufferedBytes, 3);
    final second = await rt.runExit(
      api.request<Unit>('GET', Uri.parse('https://fixture.test')),
    );
    expect(second, isA<Failure<HttpResult, HttpFailure>>());
    expect(api.bufferedBytes, 3);
    release.complete();
    expect(
      (await first.awaitExit() as Success<HttpResult, HttpFailure>).value.body,
      [1, 2, 3],
    );
    expect(api.bufferedBytes, 0);
    expect(api.activeRequests, 0);
    expect(
      (await rt.runFuture(
        api.request<Unit>('GET', Uri.parse('https://fixture.test')),
      )).body,
      [4, 5, 6],
    );
    await rt.shutdown();
    transport.close();
  });
}
