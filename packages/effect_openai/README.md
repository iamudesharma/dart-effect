# effect_openai

Typed OpenAI SDK requests and streams as lazy Effect computations. Uses
[`openai_dart`](https://pub.dev/packages/openai_dart) 10.0.1 with scoped clients,
per-run cancellation and explicit error handling.

**Initial release: `0.0.1`.** Use the hosted dependencies below, or the local
overrides for source development.

## Features and platform support

| API | Helpers |
| --- | --- |
| Responses | Create, retrieve, background cancel, typed streaming |
| Chat Completions | Create and typed streaming |
| Embeddings / moderation | Typed request and response helpers |
| Other SDK HTTP endpoints | Generic `request` and `stream` wrappers |

The adapter runs on VM and web with the SDK's supported transports. It has no
Flutter dependency. **Use a backend for production API keys**; do not bundle a
secret in a Flutter application or expose it in browser code. Persistent Realtime
sessions, automatic tool execution and pagination collectors are not managed by
this adapter. The SDK entrypoint is re-exported.

## Installation

Requires Dart **3.13 or later**. Run:

```sh
dart pub add effect_core effect_openai
# In a Flutter project:
flutter pub add effect_core effect_openai
```

Or add these dependencies to `pubspec.yaml`:

```yaml
dependencies:
  effect_core: ^0.0.1
  effect_openai: ^0.0.1
```

Then run `dart pub get` or `flutter pub get`. Your Flutter installation must
include a compatible Dart SDK.

## Quick start on a backend

Set `OPENAI_API_KEY` and `OPENAI_MODEL` in the server process environment. Choose
a model enabled for that account. Save as `bin/main.dart`:

```dart
// Opt-in live example. Requires OPENAI_API_KEY and OPENAI_MODEL.
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';

Future<void> main() async {
  final model = Platform.environment['OPENAI_MODEL'];
  if (model == null || model.isEmpty) {
    throw StateError('Set OPENAI_MODEL to a model enabled for your account.');
  }
  final client = EffectOpenAIClient.create(
    OpenAIConfig.fromEnvironment().copyWith(
      retryPolicy: const RetryPolicy(maxRetries: 0),
    ),
  );
  final runtime = Runtime(Unit.value);
  try {
    final result = await runtime.runExit(
      client.createResponse<Unit>(
        CreateResponseRequest(
          model: model,
          input: ResponseInput.text('Say hello.'),
          maxOutputTokens: 32,
          store: false,
        ),
      ),
    );
    switch (result) {
      case Success(:final value):
        print(value.outputText);
      case Failure(:final cause):
        if (cause case Expected<OpenAIFailure>(:final error)) {
          stderr.writeln(error); // Redacted adapter summary.
        } else {
          stderr.writeln('Request ended with ${cause.runtimeType}.');
        }
        exitCode = 1;
    }
  } finally {
    await runtime.shutdown();
    await client.shutdown();
  }
}
```

Run `dart run bin/main.dart`. This performs a real API request and requires
API access. SDK retries are disabled in the example to make its policy explicit.
`store: false` requests that the response is not stored. No request begins until
the effect is run. See `example/main.dart` for a credential-free SDK example using
a synthetic HTTP transport.

## Stream output as it arrives

This complete server example prints deltas, checks terminal completion, and
awaits shutdown. It does not collect the entire stream:

```dart
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';

Future<void> main() async {
  final model = Platform.environment['OPENAI_MODEL'];
  if (model == null || model.isEmpty) {
    throw StateError('Set OPENAI_MODEL to an enabled model.');
  }
  final client = EffectOpenAIClient.create(
    OpenAIConfig.fromEnvironment().copyWith(
      retryPolicy: const RetryPolicy(maxRetries: 0),
    ),
  );
  final runtime = Runtime(Unit.value);
  var completed = false;
  var failed = false;

  try {
    final program = client
        .streamResponse<Unit>(
          CreateResponseRequest(
            model: model,
            input: ResponseInput.text('Say hello.'),
            maxOutputTokens: 32,
            store: false,
          ),
        )
        .runForEach(
          (event) => Effect.sync<Unit, OpenAIFailure, Unit>(() {
            if (event is OutputTextDeltaEvent) stdout.write(event.delta);
            if (event is ResponseCompletedEvent) completed = true;
            if (event is ResponseFailedEvent ||
                event is ResponseIncompleteEvent) {
              failed = true;
            }
            return Unit.value;
          }),
        );
    await runtime.runFuture(program);
    if (!completed || failed) {
      throw StateError('Generation did not complete successfully.');
    }
    stdout.writeln();
  } finally {
    await runtime.shutdown();
    await client.shutdown();
  }
}
```

Failed/incomplete generation events, refusals, tool calls and structured outputs
remain SDK values. The application must interpret them; a transport-successful
stream is not necessarily a successful generation.

## Wrap another SDK endpoint

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';

Effect<ModelList, OpenAIFailure, Unit> listModels(EffectOpenAIClient client) {
  return client.request<ModelList, Unit>(
    (sdk, abort) => sdk.models.list(abortTrigger: abort),
    operation: 'models.list',
  );
}
```

Forward the per-run abort future in custom callbacks. Each execution and stream
consumption gets independent cancellation state. Non-abortable endpoints are
drained and may delay finalization until completion or the SDK's timeout.

## Client ownership and error policy

`EffectOpenAIClient.create` owns a new SDK. The direct `EffectOpenAIClient(sdk)`
constructor borrows an existing SDK unless `closeClient: true` is supplied.
`EffectOpenAIClient.layer(key, factory)` creates a fresh owned SDK per layer
construction scope; use `Layer.use` for that lifetime. An injected HTTP transport
remains owned by its caller according to the SDK's ownership contract.

Await `Runtime.shutdown` before `client.shutdown`. Shutdown rejects new work,
signals active operations and waits for their cleanup. SDK exceptions become
`OpenAIFailure`; abort is interruption and other exceptions are defects. Safe
summaries omit prompts, keys and server messages; raw causes and metadata can
contain sensitive diagnostics.

The adapter adds no retries. Configure SDK retry policy explicitly before composing
an Effect schedule, and replay only appropriate operations. Streams are not
restarted automatically after output. Local HTTP abort does not prove remote
generation or billing stopped. `cancelResponse` calls the separate server-side
cancellation operation for background responses. SDK buffers and `runCollect`
are not hard memory bounds.

## Local development

With access to the repository, clone it and add a `pubspec_overrides.yaml` beside
your application's pubspec. Replace `/path/to/effect_dart` with your checkout:

```yaml
dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
  effect_openai:
    path: /path/to/effect_dart/packages/effect_openai
```

Keep the version dependencies above in `pubspec.yaml`, then run `dart pub get`.
The repository already contains overrides for its own examples. The source
repository is currently private; repository access is required.

## Examples and testing

From this package's repository directory:

```sh
dart analyze
dart test
dart test -p chrome test/client_test.dart test/sdk_test.dart
dart run example/main.dart
# With OPENAI_API_KEY and OPENAI_MODEL set:
dart run example/live.dart
```

Release checks recorded 50 VM tests and 42 Chrome tests. Eight VM checks use a
real local HTTP/SSE server, not a live provider. Live-provider acceptance is
recorded separately in the repository validation reports. The examples above require OpenAI API access; this package does not
provide ChatGPT account authentication. Broader live endpoints, live browser
transport, failure injection and load/soak remain unverified.

## Documentation and license

- [Package guide](https://effect-dart.ginjustice4.chatgpt.site/docs/openai/)
- [Verification and progress](https://effect-dart.ginjustice4.chatgpt.site/progress/)
- [Source repository](https://github.com/iamudesharma/dart-effect)

MIT; see [LICENSE](LICENSE). Independent and Effect-inspired; not affiliated
with Effect-TS. The advertised scope is documented here, not full upstream parity.

This is an independent adapter for a third-party SDK, not an official OpenAI SDK.

## Performance and memory validation

The adapter adds typed failures and awaited resource ownership; it does not
claim faster HTTP requests. AOT loopback comparisons and post-GC lifecycle
checks are recorded in the [performance guide](https://effect-dart.ginjustice4.chatgpt.site/docs/openai-performance/).
Measured overhead varies by workload, including higher per-event SSE overhead.
Closed owners and closure payloads were collectible in the tested finite runs;
this is not universal leak freedom or live API/mobile acceptance. Keep one
application-scoped client/runtime and await their shutdown at the owner boundary.
