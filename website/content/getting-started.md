# Start with one effect

Effect Dart is an independent, Effect-inspired toolkit for Dart API services and applications. Start with a lazy computation, then add the services your application needs.

## Install from pub.dev

All five packages are published. Start with `effect_core` 0.0.1; add only the integrations your application uses. PostgreSQL's current documentation patch is 0.0.2, and the other packages are 0.0.1.

```sh
dart pub add effect_core
```

In a Flutter project, use `flutter pub add effect_core`. Your Flutter installation must include Dart 3.13 or later. Core has no runtime dependencies and works on the VM and web.

Or add the hosted dependency to your application's `pubspec.yaml`:

```yaml
dependencies:
  effect_core: ^0.0.1
```

Run `dart pub get` or `flutter pub get`. No repository checkout or local overrides are needed for the published packages.

## Write a lazy computation

```dart
import 'package:effect_core/effect_core.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  try {
    final program = Effect.sync<int, String, Unit>(() => 21)
        .flatMap((n) => Effect.succeed(n * 2));
    print(await runtime.runFuture(program)); // 42
  } finally {
    await runtime.shutdown();
  }
}
```

Constructing an Effect does not start the work. Each run evaluates it again. The three type parameters describe its successful value, expected failure family, and environment.

## Inspect failures

`runExit` returns Success or Failure after the fiber's cleanup finishes. A Cause distinguishes an expected failure, a programmer defect, interruption, or sequential failures from cleanup.

```dart
final effect = Effect.fail<int, String, Unit>('unavailable');
final exit = await runtime.runExit(effect);
if (exit case Failure<int, String>(cause: Expected(:final error))) {
  print(error);
}
```

`catchAll` and retry recover a standalone expected failure. Defects and interruption stay visible. Use `mapError` to translate adapter failures into your application's error family.

## Add database or AI services

Choose the service you need:

```sh
dart pub add effect_postgres postgres
# Or add MySQL / OpenAI:
dart pub add effect_mysql
dart pub add effect_openai
```

The full set of current version constraints is shown below; most applications need only a subset:

```yaml
dependencies:
  effect_core: ^0.0.1
  effect_sql: ^0.0.1
  effect_postgres: ^0.0.2
  postgres: ^3.5.19
  effect_mysql: ^0.0.1
  effect_openai: ^0.0.1
```

PostgreSQL and MySQL are native adapters intended for backend/API services. Keep database credentials and production OpenAI API keys on the backend; Flutter and browser clients should call that API. Follow the package guides for connection settings, ownership, errors and cancellation.

## Work on the source locally

The source repository is currently private; repository access is required for contribution. Published dependencies can be used without that access.

```sh
git clone --branch dart-effect https://github.com/iamudesharma/dart-effect.git
cd dart-effect
dart pub get
dart run example/resources.dart
```

For local changes, keep version dependencies and add `pubspec_overrides.yaml` beside your application's pubspec. Replace `/path/to/effect_dart` with your checkout:

```yaml
dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
  effect_sql:
    path: /path/to/effect_dart/packages/effect_sql
  effect_postgres:
    path: /path/to/effect_dart/packages/effect_postgres
```

Override only the packages you are developing and their local dependencies. The repository's own package directories include development overrides.

## Keep lifetimes explicit

Use scoped resources and Layer/Context provision for an application's services. Ordinary child fibers finish with their parent. Shutdown interrupts and awaits runtime work; release client or pool ownership afterwards.

Future cancellation is cooperative. A cancellation hook can stop underlying I/O; without one it may continue. Finalization can take longer than a timeout because it awaits cleanup.

## Choose the next guide

Read the runtime contract to understand fibers and scope behavior. The SQL and OpenAI guides explain adapter lifetimes and their verified acceptance boundaries. The progress page shows dated test evidence, while the roadmap separates delivered work from the next acceptance milestones.
