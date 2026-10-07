# Start with one effect

Effect Dart is an independent, Effect-inspired toolkit for Dart API services and applications. Start with a lazy computation, then add the services your application needs.

## Get the development source

The packages are development candidates at 0.1.0-dev.1. They are **not published on pub.dev**. The source repository is currently private; repository access is required.

```sh
git clone --branch dart-effect https://github.com/iamudesharma/dart-effect.git
cd dart-effect
dart pub get
dart run example/resources.dart
```

Use the core package directly in this checkout. To use it from another local app, point a dependency at your checkout:

```yaml
dependencies:
  effect_core:
    path: ../dart-effect
```

Dart 3.13 or later is required. Core has no runtime dependencies and works on the VM and web.

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

Local adapters use version dependencies and development overrides. Another application must override their unpublished core dependencies too:

```yaml
dependencies:
  effect_postgres:
    path: ../dart-effect/packages/effect_postgres
dependency_overrides:
  effect_core:
    path: ../dart-effect
  effect_sql:
    path: ../dart-effect/packages/effect_sql
```

For MySQL, use `effect_mysql`. For OpenAI, use `effect_openai` and override `effect_core`; it does not depend on SQL. Follow the package guides for connection settings, ownership and cancellation contracts.

## Keep lifetimes explicit

Use scoped resources and Layer/Context provision for an application's services. Ordinary child fibers finish with their parent. Shutdown interrupts and awaits runtime work; release client or pool ownership afterwards.

Future cancellation is cooperative. A cancellation hook can stop underlying I/O; without one it may continue. Finalization can take longer than a timeout because it awaits cleanup.

## Choose the next guide

Read the runtime contract to understand fibers and scope behavior. The SQL and OpenAI guides explain adapter lifetimes and their verified acceptance boundaries. The progress page shows dated test evidence, while the roadmap separates delivered work from the next acceptance milestones.
