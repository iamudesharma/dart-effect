# effect_core

Lazy, typed asynchronous effects for Dart and Flutter. Describe a computation,
compose it with other effects, and run it with explicit ownership of its resources.

**Initial release: `0.0.1`.** Use the hosted dependencies below, or the local
overrides for source development.

## Features

- Lazy, reusable effects with typed expected failures.
- Fibers, bounded concurrency, cancellation and awaited cleanup.
- Scoped resources, dependency contexts and service layers.
- Retry schedules, clocks, logging and same-isolate state primitives.
- Pull-based streams and sinks with early exit and bounded buffering.
- No runtime dependencies; core works on the Dart VM and web.

## Installation

Requires Dart **3.13 or later**. Run:

```sh
dart pub add effect_core
# In a Flutter project:
flutter pub add effect_core
```

Or add these dependencies to `pubspec.yaml`:

```yaml
dependencies:
  effect_core: ^0.0.1
```

Then run `dart pub get` or `flutter pub get`. Your Flutter installation must
include a compatible Dart SDK.

## Quick start

Save as `bin/main.dart` and run `dart run bin/main.dart`:

```dart
import 'package:effect_core/effect_core.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final program = Effect.sync<int, String, Unit>(() => 21)
      .flatMap((value) => Effect.succeed(value * 2));

  try {
    print(await runtime.runFuture(program)); // 42
  } finally {
    await runtime.shutdown();
  }
}
```

Constructing `program` does not execute it. Each run evaluates it again.
`Effect<A, E, R>` describes the returned value `A`, expected error `E`, and
required environment `R`. `Unit` represents an empty environment.

## Handle expected failures

Use `runExit` when your API or UI needs to handle the result explicitly:

```dart
import 'package:effect_core/effect_core.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final request = Effect.fail<int, String, Unit>('Record not found');

  try {
    final result = await runtime.runExit(request);
    switch (result) {
      case Success(:final value):
        print(value);
      case Failure(:final cause):
        if (cause case Expected<String>(:final error)) {
          print(error); // Record not found
        } else {
          print('Request ended with ${cause.runtimeType}');
        }
    }
  } finally {
    await runtime.shutdown();
  }
}
```

Expected failures, programmer defects and interruption remain distinct.
`catchAll` and retry recover only a standalone expected failure; they do not
silently recover defects, interruption or composite cleanup failures.

## Own a resource with a layer

```dart
import 'package:effect_core/effect_core.dart';

Future<void> main() async {
  final service = ServiceKey<String>('greeting');
  final layer = Layer.resource<String, String>(
    service,
    Effect.sync<String, String, Context>(() => 'Hello from Effect'),
    (_) => Effect.sync<Unit, String, Context>(() {
      print('Resource released');
      return Unit.value;
    }),
  );
  final runtime = Runtime(Context());

  try {
    print(await runtime.runFuture(layer.use(service.effect<String>())));
  } finally {
    await runtime.shutdown();
  }
}
```

`Layer.use` owns the constructed service scope. The runtime waits for owned child
fibers and finalizers before returning. For an application-wide service, keep the
scope alive for the application's lifetime rather than rebuilding it per query.

## Transform a stream

```dart
import 'package:effect_core/effect_core.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final stream = EffectStream.fromIterable<int, String, Unit>([1, 2, 3, 4])
      .map((value) => value * 2)
      .filter((value) => value > 4)
      .buffer(2);

  try {
    print(await runtime.runFuture(stream.runCollect())); // [6, 8]
  } finally {
    await runtime.shutdown();
  }
}
```

`runCollect` retains every output value. Use a streaming sink or early-exit sink
when collecting an entire stream would use too much memory.

## Use with Flutter or an API server

Core has no Flutter dependency. A widget/controller or server service can create
its own `Runtime`, run effects from asynchronous handlers, and await `shutdown`
when that owner closes. Flutter's synchronous `dispose` cannot itself await;
provide an asynchronous close lifecycle in the runtime's owner.

For database and AI services, add only the integration you need:

| Package | Purpose | Platform |
| --- | --- | --- |
| effect_sql | Shared SQL driver/transaction contracts | VM and web with a compatible driver |
| effect_postgres | PostgreSQL/PG through `postgres` | Native VM; intended for server-side use |
| effect_mysql | MySQL through `mysql_client_plus` | Native VM; intended for server-side use |
| effect_openai | Typed SDK HTTP requests and streams | VM and web; keep API secrets server-side |

## Lifecycle and type boundaries

Cancellation is cooperative. Without a cancellation hook, an underlying Future
can continue after the fiber stops waiting. Timeout and shutdown await protected
cleanup, so cleanup can extend the elapsed time. Fibers share an isolate and do
not provide CPU parallelism.

Dart generic covariance means `R` documents requirements but is not a complete
static proof of service provision. Context key presence is checked at runtime.
Use explicit common error families and aggregate environments when composing
services. Only map/flatMap/defer instruction chains have the advertised stack
safety proof; arbitrary deeply nested region wrappers do not.

## Local development

With access to the repository, clone it and add a `pubspec_overrides.yaml` beside
your application's pubspec. Replace `/path/to/effect_dart` with your checkout:

```yaml
dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
```

Keep the version dependencies above in `pubspec.yaml`, then run `dart pub get`.
The repository already contains overrides for its own examples. The source
repository is currently private; repository access is required.

## Examples and testing

In a repository checkout, run:

```sh
dart analyze
dart test
dart test -p chrome
dart run example/retry.dart
dart run example/resources.dart
dart run example/bounded.dart
dart run example/services.dart
dart run example/stream.dart
dart run example/web.dart
```

The release validation recorded 107 VM and 107 Chrome tests for core. Type
accept/reject fixtures are checked with `dart run tool/check_fixtures.dart` from
the repository root. Native database and AI checks are separate from core tests.

## Documentation and license

- [Package guide](https://effect-dart.ginjustice4.chatgpt.site/docs/runtime/)
- [Verification and progress](https://effect-dart.ginjustice4.chatgpt.site/progress/)
- [Source repository](https://github.com/iamudesharma/dart-effect)

MIT; see [LICENSE](LICENSE). Independent and Effect-inspired; not affiliated
with Effect-TS. The advertised scope is documented here, not full upstream parity.
