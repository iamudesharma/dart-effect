# Feature matrix

Repository note: upstream/npm snapshots, Node comparison tooling and generated
npm inventories are deliberately ignored by Git. Links to `references/` and
ignored inventories describe optional local evidence and will not resolve in a
fresh clone. Dart and database tests do not require those files.

Implemented means executable and tested, not complete Effect ecosystem parity.
Pinned evidence is indexed in `references/effect/INDEX.md`. Effect is independent.

| Feature | Status | Validation/evidence |
| --- | --- | --- |
| succeed/fail/sync/defer/fromFuture/asyncExit | Implemented | runtime/review tests: laziness, re-execution, errors and adapters |
| map/flatMap | Implemented | laws, 100,000 binds, event-queue fairness |
| catchAll/mapError/Cause/Exit | Implemented; Cause representation intentionally different | recovery boundaries, retained cleanup defects/traces, nullable errors; cross-language scenarios |
| R/service composition | Intentionally different, weaker static guarantees | explicit error families/aggregate environments; five analyzer fixtures; widened provision defect test |
| Runtime/runExit/runFuture/shutdown | Implemented | root rejection after shutdown, waiting children, finalizer-created children |
| Fiber/fork/join/interrupt-and-await | Implemented, cooperative | pre-start, async wait, abort hook and parent cleanup tests |
| forkScoped | Implemented, intentionally different | bounded by both parent and scope; resource child cleanup ordering |
| Scope/ensuring/acquireUseRelease | Implemented; late finalizers rejected | LIFO, exactly once, failure/defect/interruption, protected acquisition/release, partial acquisition |
| race | Implemented | first success, loser interruption/await, cancellation of both branches; matching upstream traces |
| bounded traverse | Implemented | bounds/order, sibling cancellation, shutdown restoration, callback defects |
| sleep/timeout | Implemented | injected test clock, pending-sleeper removal, clock defects preserved, explicit timeout E |
| Context/service keys/provide | Implemented; Context presence runtime checked | identity/immutability, missing service defects, runtime key checks after widening |
| Layer dependency graphs/scoped memo | Implemented basic subset; scope-wide failure transaction | diamond and concurrent sharing, cycle/wait graph detection, partial/concurrent acquisition cleanup |
| retry/repeat/Schedule | Implemented finite subset | limits, seeded bounded jitter/exponential delay, deterministic clock, interrupted retry, excludes defects/composites |
| logging | Implemented minimal subset | injected sink, immutable fields/timestamp; no metrics/tracing |
| TestClock | Implemented | manual advancement/cancellation; caller waits for sleeper registration |
| Flutter application integration | Unsupported in this repository | workspace had no application; standalone core only |
| Ref/Deferred/Semaphore/SynchronizedRef/bounded Queue/PubSub | Implemented foundational subset | 34 concurrency tests; seeded model, FIFO, rendezvous, withdrawal, permit restoration, atomic fan-out |
| EffectStream/Sink | Implemented foundational subset | 26 stream tests; lazy pull, native pause/cancel, resource release, bounded read-ahead, early exit |
| Configuration/cache/schema/metrics/tracing | Unimplemented next foundation milestone | no stubs advertised as working features |
| Flutter/platform/isolate adapters | Unimplemented platform milestone | same-isolate core only |
| PostgreSQL/MySQL SQL adapters | Implemented initial query/transaction subset | optional native packages using postgres/mysql_client_plus; real isolated database tests |
| RPC/workflow/cluster/CLI/AI and other SQL drivers | Outside current user scope | historical inventory retained; no package-for-package port planned |

The VM and Chrome suites both exercise portable core behavior. JavaScript smoke
compilation passes. Native Flutter/device/isolate behavior has not been tested.
The normalization harness compares fourteen runtime observables and six
foundation records with pinned
Effect 4.0.1, not the entire API. Current concurrency omits scheduler priority,
fiber-local service inheritance, detached fibers and supervision instrumentation.
Schedule omits upstream input/output combinators and infinite policies.

`asyncExit` is an advanced extension boundary: custom waits must cooperate.
Without an adapter abort hook, I/O may continue after the fiber exits. Cleanup
and acquisition that never complete can indefinitely postpone interruption.
Stack safety is proved for map/flatMap/defer chains, not arbitrary nesting of
region wrappers or arbitrary user recursion. Dart R covariance and Context
presence are explicitly weaker than TypeScript requirements tracking.

Layer scopes are memo/transaction boundaries. On a build failure, that domain is
invalidated and all acquired services close after protected in-flight work.
Previously built Context values must not be retained across that failure.
The first environment to construct a shared node wins; no global caches.
Use a complete graph with Layer.use. Parallel layer dependencies are not an
advertised performance feature; only concurrent callers share in-flight builds.

## Roadmap

The initial phase 4 contracts now execute. Remaining breadth includes queue
strategies/batches/graceful end, partitioned permits, replay PubSub, stream
parallelism/merging/grouping/time operators and Sink leftovers.
Phase 5 adds structured schema issues and encode/decode round trips, configuration,
cache lifetime, and optional observability adapters. Phase 6 isolates sendability
and platform concerns outside the core dependency graph.

Full ecosystem expansion was superseded by the user's focused Dart core and
PostgreSQL/MySQL scope: [SQL adapter contracts](sql-adapters.md). Historical
[all-package inventory/status](ecosystem-status.md),
[expanded contracts](expansion-contracts.md), [detailed test cases](testing.md).
