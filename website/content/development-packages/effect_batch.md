# effect_batch

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_batch:
    path: /path/to/effect_dart/packages/effect_batch

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
```

## Usage

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_batch/effect_batch.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final resolver = RequestResolver<int, int, String, Unit>(runtime: runtime, onOverload: (_) => 'busy', resolve: (group, ids) => Effect.succeed({for (final id in ids) id: Success(id * 2)}));
  try { print(await runtime.runFuture(resolver.request(3, group: 'tenant-a'))); } finally { await resolver.close(); await runtime.shutdown(); }
}
```

## Contracts and limits

Deduplication identity is (group,key); include tenant and authorization identity in group. One worker bounds backend concurrency to one batch. maxPending bounds accepted unique work; maxBatchSize bounds each backend call. Cancellation withdraws a waiter, not the shared batch. close interrupts and awaits the worker. Missing response keys are protocol defects. No automatic retry, mutation replay or persistent cache.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
