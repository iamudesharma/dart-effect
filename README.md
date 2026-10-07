# Blot Effect

An independent, Effect-inspired Dart package for lazy computations, typed expected
failures, dependency provision and structured asynchronous concurrency. Version
`0.1.0-dev.1` implements core runtime/services and an initial concurrency and
stream foundation. Current scope is the reusable core plus PostgreSQL/MySQL
adapters using established Dart drivers.
Dart >=3.13.0; no runtime dependencies or unconditional `dart:io` imports.
Not officially affiliated with Effect-TS and no full compatibility/parity claim.

```dart
import 'package:blot_effect/blot_effect.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final program = Effect.sync<int, String, Unit>(() => 21)
      .flatMap((n) => Effect.succeed(n * 2));
  print(await runtime.runFuture(program)); // 42
  await runtime.shutdown();
}
```

Effects run lazily and evaluate again on each run. Use `runExit` to inspect
`Success` or `Failure`; causes distinguish `Expected`, `Defect` (with stack trace),
`Interrupted`, and sequential cleanup failures. `catchAll` and `retry` recover
only a standalone expected failure. A shared sealed error family and explicit
aggregate environment compose differing errors and services.

`R` has a typed selector through `Effect.environment`, but Dart covariance allows
widening R. It is requirement documentation with runtime checks, not a complete
static proof of provision. `Context` uses typed identity keys; missing services
are defects. Prefer `key.bind(value)` for direct compile-time value checking;
`Context.add` also checks the key's actual runtime type after generic widening.

`fromFuture` takes a factory, not an already running Future. Without an abort hook,
interruption ends the fiber's wait while underlying I/O can continue. Hooks are
awaited. Allocate per-run cancellation state with `defer`. Acquisition and
finalization are protected: timeout/interrupt/shutdown await cleanup, so their
elapsed time can exceed a requested timeout. Custom `asyncExit` callbacks must
cooperate with cancellation or evaluate interruptible effects. Fibers run in the
same isolate and do not accelerate CPU work.

Use `acquireUseRelease`, `scoped` and `forkScoped` for resource lifetimes.
`fork` ends with its parent; `forkScoped` is additionally bounded by its scope.
`race` selects first success, waits after an initial failure, and awaits loser
cleanup. `traverse` limits active fibers and preserves input result order.

Layers memoize by identity within a construction scope, sharing in-flight
acquisition and detecting cycles. `Layer.use` owns the service lifetime. Failed
construction invalidates the scope's memo domain and releases resources after
protected acquisitions finish; do not retain earlier Context values across that
failure. Build a complete graph before using its services. The first environment
supplied to a shared node determines its construction inputs.

Runnable examples:

```sh
dart pub get
dart run example/retry.dart       # fresh cancellable adapter and retry policy
dart run example/resources.dart   # scoped service acquire/release
dart run example/bounded.dart     # bounded ordered processing
dart run example/services.dart    # dependency graph and typed service composition
dart run example/stream.dart      # reusable bounded stream and early-exit sink
```

Development verification (SDK/pub dependencies installed first):

```sh
dart format --output=none --set-exit-if-changed lib test example tool
dart analyze
dart test
dart test -p chrome
dart run tool/check_fixtures.dart
dart compile js example/web.dart -o build/web-smoke.js
```

The GitHub repository contains Dart packages, tests, examples and development
support. Upstream/npm snapshots, Node source/tooling, node_modules and generated
npm inventories are excluded by `.gitignore`. A checkout needs no Node installation
to analyze or test the Dart packages. Optional historical cross-language evidence
and its reference-verification tooling apply only when the separately retained
local reference pack and ignored conformance directory are present. They are not
required for normal builds; no references are automatically downloaded.

[Architecture](docs/effect-port/architecture.md),
[feature matrix and roadmap](docs/effect-port/feature-matrix.md),
[validation/progress](docs/effect-port/progress.md), and
[benchmarks](docs/effect-port/benchmarks.md) record supported behavior and limits.
Ref, Deferred, weighted Semaphore, SynchronizedRef, bounded Queue/PubSub and
pull-based EffectStream/Sink now have executable tests. Stream adapters support
native pause/cancel and bounded buffering. Schemas/configuration/caches,
metrics/tracing and broader ecosystem integrations remain outside the current
focused scope; see [SQL adapters and detailed contracts](docs/effect-port/sql-adapters.md) and
[detailed upstream-style test cases](docs/effect-port/testing.md). Only map/flatMap/defer chain depth is proved stack
safe; deeply nesting region wrappers is not advertised as stack safe.


Optional server database packages:

| Package | Driver | Location |
| --- | --- | --- |
| blot_sql | Shared scoped query/transaction contracts; core dependency only | packages/blot_sql |
| blot_postgres | postgres 3.5.19 | packages/blot_postgres |
| blot_mysql | mysql_client_plus 0.1.3 | packages/blot_mysql |

PG and PostgreSQL use the same adapter. Bound parameters, exclusive transactions,
nested savepoints and cleanup integrate with Effect/Runtime/Layer. Native database
imports remain outside core. MySQL interruption drains pending work before
rollback; PostgreSQL discards the interrupted connection. Read the
[adapter guide](docs/effect-port/sql-adapters.md) for TLS, API usage, local package
consumption and test cases. `python3 tool/sql_integration.py` runs real isolated
database suites and removes its test containers. These packages are not published.
