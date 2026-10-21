# effect_cache

Typed value caching and shared resource lifetimes for Dart services. Concurrent
reads of one key share a lookup; scoped resources stay alive until borrowers
finish. The library is portable and adds no platform or network dependency.

**Version: `0.0.1`.** Requires `effect_core ^0.0.3` and Dart 3.13 or later.

## Install

```sh
dart pub add effect_core effect_cache
```

For Flutter applications, use `flutter pub add effect_core effect_cache`.

```yaml
dependencies:
  effect_core: ^0.0.3
  effect_cache: ^0.0.1
```

## Share backend lookups

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_cache/effect_cache.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final cache = EffectCache<(String, int), String, String, Unit>(
    runtime: runtime,
    capacity: 256,
    ttl: const Duration(minutes: 1),
    failureTtl: const Duration(seconds: 2), // Optional negative caching.
    lookup: (key) => Effect.succeed('${key.$1}:user-${key.$2}'),
  );
  try {
    final users = await Future.wait(List.generate(
      30,
      (_) => runtime.runFuture(cache.get(('tenant-a', 42))),
    ));
    print(users.first);
    print(cache.stats.loads); // 1
  } finally {
    final cleanup = await cache.close();
    await runtime.shutdown();
    if (cleanup != null) throw EffectException(cleanup);
  }
}
```

Replace `lookup` with an Effect around the real service. Use `fromFuture`'s
`onError` to classify expected errors and `onCancel` to abort underlying I/O.
Include tenant **and authorization identity** in keys whenever results differ.
Keys need stable `==` and `hashCode`; immutable Dart records work well.
A cache instance borrows one runtime/environment; do not share it across security
contexts unless the key and lookup explicitly enforce that boundary.

## Value cache operations

| API | Behavior |
| --- | --- |
| `get(key)` | Lazy; single-flight per resident generation; successful values use LRU ordering |
| `peek(key)` | Nonloading `Future<Exit<V,E>?>`; null for missing/pending/expired; `Success(null)` remains a value |
| `containsKey(key)`, `keys` | Nonloading metadata, including pending but excluding expired entries; do not change LRU |
| `size` | Resident slots, including pending and lazily expired entries until touched/purged |
| `stats` | Immutable snapshot of hits, misses, loads, evictions, expirations, size, owners and dropped diagnostic records |
| `invalidate(key)`, `invalidateAll()` | Detach immediately, interrupt removed loads, await cleanup; return any retirement diagnostic |
| `refresh(key)` | Strictly invalidate, await cleanup, then reload; propagates cleanup failure instead of discarding it |
| `purgeExpired()` | Remove idle expired entries and await their retirement |
| `startMaintenance(interval: ..., refresh: false)` | Explicit periodic expiry worker; no implicit timers |
| `startMaintenance(interval: ..., refresh: true)` | Sequential strict refresh of each resident key, including expired residents |
| `takeDiagnostics()` | Drain at most 32 retirement records and reset dropped count |
| `close()` | Reject new work immediately, stop maintenance, retire residents, await outstanding cleanup; return retained diagnostics |

TTL uses the borrowed runtime's monotonic clock where available, beginning after
lookup completion and cleanup. Legacy clocks fall back to their injected wall
time. Zero success/failure TTL disables retention for that outcome. Only a single
`Expected<E>` failure is eligible for optional `failureTtl`: defects, interruption
and sequential cleanup causes never cache. Pending loads have no TTL deadline;
apply a timeout to the lookup when needed.

Refresh intentionally does **not** serve stale values during replacement.
Concurrent explicit refreshes may interrupt one another; use `get` for shared
reads. A refresh waiter cancelling leaves its admitted shared load running.
Invalidation prevents a late old completion from replacing a newer generation.
Metadata inspection never starts loads or silently acquires resources.

## Borrow resources safely

```dart
final clients = ScopedCache<String, TenantClient, ApiError, Services>(
  runtime: runtime,
  capacity: 16,
  ttl: const Duration(minutes: 5),
  acquire: (tenant) => openClient(tenant).acquireScoped(
    (client) => closeClient(client),
  ),
);

final profile = await runtime.runFuture(
  clients.use('tenant-and-auth-key', (client) => client.fetchProfile()),
);
// Existing borrowers retain the retired generation until their cleanup ends.
clients.invalidate('tenant-and-auth-key');
final newProfile = await runtime.runFuture(
  clients.refresh('tenant-and-auth-key', (client) => client.fetchProfile()),
);
final cleanup = await clients.close();
// Inspect cleanup before completing application shutdown.
```

`TenantClient`, `ApiError`, `Services`, `openClient` and `closeClient` above are
application types/functions. A complete executable example using counted
resources is in [example/main.dart](example/main.dart).

ScopedCache exposes `use`, callback-based `refresh`, `invalidate`, `invalidateAll`,
`purgeExpired`, `containsKey`, immutable `keys`/`stats`, `size`, `isClosed`,
`startMaintenance`, `takeDiagnostics` and awaited `close`. It deliberately has no
raw-resource `peek`: returning or retaining a live resource outside `use` escapes
the lifetime contract. TTL starts on successful acquisition; failed acquisitions
are not cached. Pending acquisition is interrupted on retirement. Cancel-safe
protected acquisition may still have to finish before its release can run.

Invalidation/expiry/eviction retire a generation immediately, while release waits
for its last borrower **and that borrower's scoped cleanup**. Scoped invalidation
methods schedule retirement rather than awaiting active borrowers. `close` waits
for all owners and releases exactly once. Expected acquisition failures reach
callers; only appended owner cleanup failures enter retirement diagnostics.

## Ownership, cancellation and bounds

- Close caches before shutting down their borrowed runtime. Never call scoped
  `close` inside a borrow it must await. Synchronous Flutter `dispose` cannot
  prove asynchronous cleanup has finished; arrange an awaited owner boundary.
- Cancelling one or even every waiter does not cancel a shared load. Eviction,
  invalidation or cache closure stop removed generations. Actual I/O requires an
  abort hook; an ordinary Future may continue outside the runtime.
- LRU capacity bounds resident entries, including pending loads. `maxOwners` separately bounds active and retired generations, including
  protected cleanup. Neither limit bounds value bytes or borrower counts; limit
  application concurrency and choose value sizes accordingly.
- TTL expiration is lazy unless `purgeExpired` or optional maintenance runs.
  Maintenance admits no overlapping ticks and stops on its first error. Inspect
  the returned `Fiber`'s Exit; there is no automatic retry or hidden supervisor.
  Its interval must be positive. Close interrupts and awaits the worker.
- Cleanup can wait indefinitely when user acquisition/finalization never ends.
  Diagnostic history retains 32 records; inspect `stats.droppedDiagnostics` and
  drain regularly. This bounds record count, not the size of user errors.
- Pools, `ScopedRef`, persistence, distributed caching and stale-while-revalidate
  are separate designs. This package does not claim full npm API parity.

## Testing and measurements

From this package directory:

```sh
dart pub get --offline
dart analyze
dart test
dart test -p chrome
dart run example/main.dart
dart compile js example/main.dart -o /tmp/effect-cache-example.js
```

[Cache validation](https://github.com/iamudesharma/dart-effect/blob/codex/package-memory-release/docs/effect-port/cache-validation.md) describes the
independent test matrix, real HTTP fixture, model-based LRU checks, benchmarks,
post-GC reachability checks and package dry-run boundaries. Chrome excludes the
native loopback HTTP fixture. No API keys or database are needed. Browser tests
are behavioral checks; they do not establish Flutter-device acceptance.

## owner admission limits

`maxOwners` now bounds all active lookup/resource generations, including those
waiting for protected cleanup, independently of resident `capacity`. It defaults
to twice capacity. Set `onCapacity: () => YourError(...)` to map saturation into
the declared E family; otherwise it is a StateError defect. A new generation is
rejected immediately at the bound, so a nested scoped refresh cannot deadlock
waiting for its own final owner permit. Existing shared entries still work.

Completed value entries keep only their Exit rather than a finished Fiber.
Use `startMaintenance(interval: ...)` or `purgeExpired()` when idle expiration
must release values without a subsequent read. Drain diagnostics and close the
cache before runtime shutdown. Value/error bytes and borrower counts still need
application budgets. See the [follow-up evidence](https://github.com/iamudesharma/dart-effect/blob/codex/package-memory-release/docs/effect-port/memory-fixes.md).
