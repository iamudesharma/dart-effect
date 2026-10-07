# effect_openai

Lazy typed effects for [openai_dart](https://pub.dev/packages/openai_dart), using
version 10.0.1. Works with Dart API services and portable Dart/Flutter applications.
Independent development package; not published or affiliated with OpenAI/Effect-TS.

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';

final client = EffectOpenAIClient.create(OpenAIConfig(
  authProvider: ApiKeyProvider(apiKey),
  retryPolicy: const RetryPolicy(maxRetries: 0),
));
final runtime = Runtime(Unit.value);
try {
  final result = await runtime.runExit(client.createResponse<Unit>(
    CreateResponseRequest(model: model, input: ResponseInput.text('Hello')),
  ));
  // Map Success<Response> or Expected<OpenAIFailure> to your HTTP response.
} finally {
  await runtime.shutdown();
  await client.shutdown();
}
```

Helpers: create/retrieve/cancel Responses, stream Responses, create/stream Chat
Completions, create embeddings and moderation. Results, request options, tool
calls and structured outputs retain the SDK's types. `request<A, R>` wraps other
SDK Future endpoints; `stream<A, R>` wraps SDK streams. The package re-exports the
main SDK entrypoint. Persistent Realtime sessions and paginated iterators require
separate resource ownership; they are not automatically managed by a Future wrapper.

```dart
final models = client.request<ModelList, Unit>(
  (sdk, abort) => sdk.models.list(abortTrigger: abort),
  operation: 'models.list',
);
final text = client.streamResponse<Unit>(request)
    .filter((event) => event is OutputTextDeltaEvent)
    .map((event) => (event as OutputTextDeltaEvent).delta)
    .run(Sink.collect());
```

Each execution/consumption allocates fresh abort state. Forward `abortTrigger` in
custom callbacks. Endpoints without an abort parameter remain lazy and typed but
interruption drains their work, subject to SDK deadlines. `shutdown` aborts/drains
active work and rejects new requests. Cancellation stops local transport; it does
not promise that remote generation or billing stops. `cancelResponse` explicitly
calls the server's background-response cancellation endpoint.

Own clients with `EffectOpenAIClient.layer(key, () => OpenAIClient(...))` and
`Layer.use`. Each construction scope gets a fresh owned SDK. The direct
`EffectOpenAIClient(sdk)` constructor borrows it; `closeClient: true` transfers
SDK ownership. As defined by openai_dart, injected HTTP transports remain owned
by their caller, even when the SDK is closed.

SDK exceptions become typed `OpenAIFailure`; SDK aborts become `Interrupted`.
Other exceptions remain defects. The safe failure summary omits prompts, keys,
server messages and bodies. Diagnostic `cause` and metadata may contain secrets.
Response statuses, failed/incomplete generation objects, refusals, tool calls and
SSE events are preserved as SDK values; the application chooses how to handle them.

No adapter retries are added. The SDK's configured retry policy still applies;
set it to zero if using Effect retry schedules. Retry application operations only
when replay is appropriate. Streams are never automatically restarted after output.
The adapter forwards pause/resume to the SDK stream; SDK/native buffering and
collecting an entire stream are not bounded-memory guarantees.

Development: this repository's pubspec_overrides.yaml resolves effect_core from
../... For another local app, use overrides for effect_core and effect_openai
until publication. Overrides are excluded from package archives.

```sh
dart pub get
dart analyze
dart test                         # lifecycle, SDK wire tests and local HTTP/SSE
dart test -p chrome test/client_test.dart test/sdk_test.dart
dart run example/main.dart        # credential-free real SDK example
# Optional live request; choose a model available to your account:
OPENAI_API_KEY=... OPENAI_MODEL=... dart run example/live.dart
```

See the repository's [adapter and detailed test guide](https://github.com/iamudesharma/dart-effect/blob/dart-effect/docs/effect-port/openai-adapter.md)
for supported operations, scenarios and validation limits. Local socket tests use
synthetic responses, not the live OpenAI service. Two native live Responses streams also passed using user-authorized ChatGPT plan
access, including Unicode output and terminal completion. This is a limited smoke
check; other endpoints and live browser transport remain unverified. See the
adapter guide for the recorded evidence. No API credential is checked into this
repository.
