# effect_cache

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_cache:
    path: /path/to/effect_dart/packages/effect_cache

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
```

## Usage

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_cache/effect_cache.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final cache = EffectCache<String, int, String, Unit>(runtime: runtime, capacity: 32, ttl: Duration(seconds: 10), lookup: (key) => Effect.succeed(key.length));
  try { print(await runtime.runFuture(cache.get('hello'))); } finally { await cache.close(); await runtime.shutdown(); }
}
```

## Contracts and limits

EffectCache is bounded LRU. Independent waiters share a root load owned by the borrowed runtime; cancelling one waiter leaves the shared load running. Invalidation and eviction interrupt loads. Close precedes runtime shutdown. ScopedCache retires generations, retains borrowed resources until users finish, and returns cleanup diagnostics on close. Capacity bounds resident generations; simultaneously borrowed retired generations depend on application concurrency. Acquire resources with acquireScoped. Never close a scoped cache from inside its own borrowed operation.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.

Underlying I/O stops only when the lookup supplies a cancellation hook. Ordinary
Futures can continue after fiber interruption. Include tenant/auth identity in keys
when values differ by caller.
