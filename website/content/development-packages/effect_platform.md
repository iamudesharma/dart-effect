# effect_platform

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_platform:
    path: /path/to/effect_dart/packages/effect_platform

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
  effect_config:
    path: /path/to/effect_dart/packages/effect_config
```

## Usage

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_platform/effect_platform.dart';
int compute() => 6 * 7;

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  try { print(await runtime.runFuture(isolateTask<int, String, Unit>(compute, onError: (error, stack) => error.toString()))); } finally { await runtime.shutdown(); }
}
```

## Contracts and limits

Native environment and JSON-file configuration, plus one-shot isolate computation. Closure and output must be isolate-sendable. Cancellation kills the isolate; worker finally blocks are not guaranteed. Do not acquire external resources inside a killable computation. No browser worker or isolate pool implementation is claimed.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
