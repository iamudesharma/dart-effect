@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_cache/effect_cache.dart';
import 'package:test/test.dart';

void main() {
  test('API consumer: 30 requests share HTTP load, tenant keys isolate, refresh and failure recover', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    final rt = Runtime(Unit.value);
    var calls = 0, offline = false;
    final arrived = Completer<void>(), allow = Completer<void>();
    server.listen((request) async {
      calls++;
      if (!arrived.isCompleted) arrived.complete();
      await allow.future;
      request.response.statusCode = offline ? 503 : 200;
      request.response.write(request.uri.queryParameters['tenant']);
      await request.response.close();
    });
    final cache = EffectCache<(String, int), String, String, Unit>(
      runtime: rt,
      capacity: 4,
      ttl: const Duration(minutes: 1),
      lookup: (key) => Effect.asyncExit((ctx) async {
        final response = await ctx.evaluate(
          Effect.fromFuture<(int, String), String, Unit>(() async {
            final request = await client.getUrl(
              Uri.parse(
                'http://127.0.0.1:${server.port}/user?tenant=${key.$1}',
              ),
            );
            final response = await request.close();
            final body = await response.transform(utf8.decoder).join();
            return (response.statusCode, body);
          }),
        );
        if (response is Failure<(int, String), String>) {
          return Failure(response.cause);
        }
        final (status, body) =
            (response as Success<(int, String), String>).value;
        return status == 200
            ? Success(body)
            : Failure(Expected('HTTP $status'));
      }),
    );
    try {
      final readers = List.generate(
        30,
        (_) => rt.runFuture(cache.get(('tenant-a', 1))),
      );
      await arrived.future;
      expect(calls, 1);
      allow.complete();
      expect(await Future.wait(readers), everyElement('tenant-a'));
      expect(await rt.runFuture(cache.get(('tenant-b', 1))), 'tenant-b');
      expect(calls, 2);
      offline = true;
      final failure = await rt.runExit(
        cache.refresh(('tenant-a', 1)),
      ) as Failure<String, String>;
      expect(failure.cause.expectedErrors, ['HTTP 503']);
      expect(cache.containsKey(('tenant-b', 1)), isTrue);
      offline = false;
      expect(await rt.runFuture(cache.get(('tenant-a', 1))), 'tenant-a');
      expect(calls, 4);
      expect(await cache.close(), null);
    } finally {
      if (!allow.isCompleted) allow.complete();
      await cache.close();
      await rt.shutdown();
      client.close(force: true);
      await server.close(force: true);
    }
  });
}
