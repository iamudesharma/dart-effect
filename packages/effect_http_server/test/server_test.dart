import 'dart:convert';
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';
import 'package:effect_http_server/effect_http_server.dart';
import 'package:test/test.dart';

void main() {
  test('real loopback routing, schema errors and bounded body', () async {
    final router = EffectRouter<Unit>();
    router.add(
      'POST',
      '/double',
      (request) => request
          .json<int, Unit>(Schema.integer)
          .map((n) => ServerResponse.json(n * 2)),
    );
    final server = await EffectHttpServer.bind(
      Unit.value,
      router.call,
      maxBodyBytes: 16,
    );
    addTearDown(server.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<(int, String)> post(String input) async {
      final r = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/double'),
      );
      r.write(input);
      final out = await r.close();
      return (out.statusCode, await utf8.decoder.bind(out).join());
    }

    expect(await post('3'), (200, '6'));
    expect((await post('"bad"')).$1, 400);
    expect((await post('x' * 17)).$1, 413);
  });
}
