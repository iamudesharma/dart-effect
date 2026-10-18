# effect_http_server

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_http_server:
    path: /path/to/effect_dart/packages/effect_http_server

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
  effect_schema:
    path: /path/to/effect_dart/packages/effect_schema
```

## Usage

```dart
import 'dart:io';
import 'package:effect_core/effect_core.dart';
import 'package:effect_http_server/effect_http_server.dart';

Future<void> main() async {
  final router = EffectRouter<Unit>();
  router.add('GET', '/health', (_) => Effect.succeed(ServerResponse.json({'ok': true})));
  final server = await EffectHttpServer.bind(Unit.value, router.call);
  final client = HttpClient();
  try { final request = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/health')); print((await request.close()).statusCode); } finally { client.close(force: true); await server.close(); }
}
```

## Contracts and limits

Native exact method/path routing, typed JSON input validation, bounded request bodies/admission and owned request runtime. close interrupts requests and awaits cleanup. This is an initial materialized-response server, without TLS termination, wildcard routing, multipart, streaming responses or an OpenAPI-derived client. Deployment/proxy trust must be configured by the application.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
