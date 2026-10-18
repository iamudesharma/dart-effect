import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_http_server/effect_http_server.dart';

Future<void> main() async {
  final router = EffectRouter<Unit>();
  router.add(
    'GET',
    '/health',
    (_) => Effect.succeed(ServerResponse.json({'ok': true})),
  );
  final server = await EffectHttpServer.bind(Unit.value, router.call);
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/health'),
    );
    print((await request.close()).statusCode);
  } finally {
    client.close(force: true);
    await server.close();
  }
}
