# Core and memory audit — 19 October 2026

Audited the merged `dart-effect` development source at `465e0aa49da4530be247160aaae36cefa0865f16`, after PR #14.
Core is `0.0.3-dev.1`, cache `0.1.0-dev.1`; these additions remain unpublished.
The broader toolkit PR #13 was not substituted for merged code. **No production
runtime, cache, driver, dependency version or scheduler behavior was changed.**

The central finding: cleanup works in the tested scenarios, but **resident item
capacity is not a bound on total live memory**, and the runtime adds scheduling
and allocation costs that can be reduced. A post-shutdown GC check alone is not
adequate production memory acceptance. There are also two reproduced correctness
issues: wall-clock duration policies and recursive error-cause conversion.

## Executed evidence and its boundary

[Machine-readable results](core-memory-audit.json) contain SDK/host details,
source/tool fingerprints, commands, raw summaries and requested-GC timestamps.
Reproduction: `python3 tool/run_core_memory_audit.py`. SDK/pub/Chrome prerequisites
must already be installed; normal resolution uses the local pub cache.

- Core: 127 VM and 127 Chrome tests. Cache: 35 VM and 34 Chrome tests. HTTP:
  10 VM and 4 Chrome tests. All passed without skips/failures, plus five analyzer
  fixtures and fatal-info analysis of the audit tools.
- Scheduling counted with Dart Zones, separately from uninstrumented native AOT
  latency. JIT/AOT probes both reproduced clock and deep-cause outcomes.
- Three fresh VM processes tested live retention and release, with requested GC.
  All 408 tracked payloads across the three scenarios/processes became unreachable
  after the matching purge, cleanup release or queue shutdown. This is bounded
  reachability evidence; it does not prove universal leak freedom.
- SQL/OpenAI adapter lifecycle and allocation sites were inspected statically.
  No new live DB/provider, physical-device, Flutter frame or production soak
  acceptance was run. Existing older reports remain separately dated.

## Priority findings

| ID | Priority | Finding and evidence | Recommended change |
| --- | --- | --- | --- |
| A1 | High | Cache capacity 1 allowed 64 unfinished owners and 64 retained 128 KiB payloads under blocked cleanup. Scoped capacity also excludes borrowed retired generations. | Bound total active/retiring owners and queued admissions, not only residents. Apply backpressure or an explicit caller-mapped overload failure before allocating more work. Never discard cleanup to conceal the backlog. |
| A2 | High | Queue capacity 1 retained 64 blocked producer payloads in addition to its buffered item. Semaphore and PubSub also have unbounded waiter/publication queues. | Bound pending work at service admission; acquire capacity before creating large payloads. Use `tryOffer` when dropping is an explicit application policy, or add a finite pending bound. |
| A3 | High | HTTP's immutable `List<int>` copy retained about eight times the logical byte count on this VM, excluding its growable request accumulator. | Use SDK packed bytes: BytesBuilder plus owned Uint8List storage/read-only views. Preserve defensive copying for caller-owned mutable inputs. Add total concurrent-response/byte budgets. |
| A4 | High | After wall time moved backwards one day, the limiter requested a 24-hour-plus-10-ms sleep despite 10 ms monotonic progress. Runtime metrics reported negative one day. Retry budgets and breakers also use wall time. | Use the existing elapsedTime/MonotonicClock capability for duration policies; retain UTC wall time only for timestamps and HTTP date interpretation. Define shared-policy clock domains. |
| A5 | Medium | Every ordinary root and cached read scheduled one zero-duration timer; misses scheduled two. No positive-duration sleep was added by these simple paths. | Review root startup and cache-close event hops. Preserve registration-before-execution, laziness and cooperative fairness rather than replacing every timer with microtasks. |
| A6 | Medium | Cache hits retain and join a completed Fiber, including its token and future, instead of just a completed immutable outcome. | Give entries pending/completed states, release completed fiber/token references, and return the validated cached Exit directly. Retest cancellation, TTL and invalidation races. |
| A7 | Medium | Empty scopes, token completers/sets, context cloning, map leaves and typed Exit/Cause reconstruction allocate on common paths. A 1,000-map run scheduled about 1,004 microtasks per operation in the Zone probe. | Profile allocations; lazily allocate ownership containers/cancellation futures, add a safe empty-scope fast path, and consider pure/map instructions and already-typed Exit reuse. Keep runtime type checks. |
| A8 | Medium | Eight expired 1 MiB values were invisible to keys/peek but remained resident after a day of manual time. All collected after purge. | Treat idle expiry as an explicit memory policy: run owned maintenance/purge when required, and consider weighted capacity for large values. Lazy TTL alone does not release idle memory. |
| A9 | Medium | Traverse generated all 10,000 inputs and allocated its full result structure before the first work call, even with concurrency 1 and immediate failure. runCollect accumulates all output. SQL adapters materialize full result rows. | Distinguish concurrency bounds from data bounds. Prefer streaming/folds, pagination and bounded batches; add item/byte limits where materialization is intended. |
| A10 | Medium | At 50,000 sequential cause nodes, typed conversion produced StackOverflowError and retained zero original expected errors, in JIT and AOT. Depth 10,000 passed. | Make Cause conversion/restoration and cleanup filtering iterative; do not rely only on the already-iterative public inspection extensions. Preserve expected/defect/interruption order. |
| A11 | Medium | Timeout intentionally waits for protected cleanup; MySQL cancel is a no-op followed by driver drain. Slow cleanup/query completion can extend the user's observed deadline. | Keep ownership safe; expose deadline-versus-cleanup latency, cap admissions, and investigate driver-supported abort/query deadlines with actual dialect acceptance. Do not promise a hard return deadline from a cooperative timeout. |
| A12 | Lower | Diagnostic history bounds records at 32, not their bytes. Closed-but-still-reachable cache/runtime owners still hold final environment/lookup/error references. | Drain diagnostics and release owner references at application boundaries. Consider compact diagnostic metadata and lightweight closed-state snapshots; do not silently drop typed failures. |

### Source locations

- Root scheduling/fairness/scope closure: [lib/src/core.dart:447](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/core.dart#L447), [lib/src/core.dart:583](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/core.dart#L583), [lib/src/core.dart:204](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/core.dart#L204).
- Common allocations and retyping: [lib/src/core.dart:59](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/core.dart#L59), [lib/src/core.dart:598](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/core.dart#L598), [lib/src/core.dart:556](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/core.dart#L556).
- Duration policies: [lib/src/core.dart:487](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/core.dart#L487), [lib/src/reliability.dart:73](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/reliability.dart#L73), [lib/src/services.dart:300](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/services.dart#L300).
- Cache ownership/retention: [packages/effect_cache/lib/effect_cache.dart:172](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/packages/effect_cache/lib/effect_cache.dart#L172), [packages/effect_cache/lib/effect_cache.dart:362](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/packages/effect_cache/lib/effect_cache.dart#L362), [packages/effect_cache/lib/effect_cache.dart:252](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/packages/effect_cache/lib/effect_cache.dart#L252), [packages/effect_cache/lib/effect_cache.dart:256](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/packages/effect_cache/lib/effect_cache.dart#L256), [packages/effect_cache/lib/effect_cache.dart:49](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/packages/effect_cache/lib/effect_cache.dart#L49).
- Pending work: [lib/src/concurrency.dart:191](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/concurrency.dart#L191), [lib/src/concurrency.dart:99](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/concurrency.dart#L99), [lib/src/concurrency.dart:315](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/concurrency.dart#L315).
- Data materialization: [lib/src/core.dart:863](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/core.dart#L863), [lib/src/stream.dart:305](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/lib/src/stream.dart#L305), [packages/effect_postgres/lib/effect_postgres.dart:105](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/packages/effect_postgres/lib/effect_postgres.dart#L105).
- HTTP copies: [packages/effect_http/lib/effect_http.dart:72](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/packages/effect_http/lib/effect_http.dart#L72), [packages/effect_http/lib/effect_http.dart:128](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/packages/effect_http/lib/effect_http.dart#L128). MySQL drain: [packages/effect_mysql/lib/effect_mysql.dart:153](https://github.com/iamudesharma/dart-effect/blob/465e0aa49da4530be247160aaae36cefa0865f16/packages/effect_mysql/lib/effect_mysql.dart#L153).

## What “delay” means here

Zone counts for 50 operations:

| Operation | Zero-duration timers | Microtask schedules |
| --- | --- | --- |
| Future.value baseline | 0 | 50 |
| Root success | 50 | 200 |
| Root fromFuture | 50 | 200 |
| Warm cache hit | 50 | 150 |
| Cache miss | 100 | 484 |

Ten 1,000-map operations scheduled 30 timers and 10,040 microtasks. The extra two
timers per mapped root are cooperative yields after interpreter work budgets.
The counts include instrumentation effects and callback lifecycle activity;
they are not CPU timings. There were **zero positive-duration timers** in these
simple scheduling probes. The cost is event-queue/continuation overhead, not a
hard-coded 100 ms sleep.

In a separate 2,000-sample native AOT run, root success had p50/p95/p99 of
5/5/7 µs; a warm cache hit had 6/6/8 µs. Future.value mostly rounded below the
microsecond timer resolution; it is not free. These synthetic host measurements
are not Flutter frame-time or mobile latency guarantees.

Dart's [Future constructor](https://api.dart.dev/dart-async/Future/Future.html)
uses Timer.run. However, replacing event work with unlimited microtasks can
starve input/rendering: in the 10,000-iteration primitive control, a pending timer
heartbeat ran during event-queue work but never during the microtask-only loop.
This matches Dart's [microtask starvation guidance](https://api.dart.dev/dart-async/scheduleMicrotask.html).
That primitive comparison is not a benchmark of an optimized Effect runtime.

A sensible optimization must balance short-operation overhead with fairness
across repeated small roots and nested evaluation, not only within one long map
chain. Startup order, cancellation before first execution and root registration
must remain observable in the same documented way.

## HTTP packed-byte prototype

Retained Dart heap added after requested GC, while the typed input stayed live:

| Logical body | Current HttpResult | Typed defensive-copy prototype |
| --- | --- | --- |
| 1 MiB | 8,392,176 bytes | 1,049,296 bytes |
| 4 MiB | 33,558,096 bytes | 4,195,024 bytes |

The prototype verified both read-only access and isolation from later input
mutation. It only constructs packed bytes; it has **not** changed HttpResult or
been accepted as the transport implementation. The current streaming request's
additional growable integer list, transient chunks and text decoding are outside
these constructor-only deltas. Consequently maxBodyBytes is a logical payload
limit, not a process-memory ceiling. There is small profiler noise, and the exact
representation varies by runtime/platform.

The SDK already provides [BytesBuilder](https://api.dart.dev/dart-typed_data/BytesBuilder-class.html)
and [Uint8List.asUnmodifiableView](https://api.dart.dev/dart-typed_data/Uint8List/asUnmodifiableView.html).
No Flutter or third-party runtime dependency is needed to use packed byte
storage. Returning a view of caller-owned mutable input would be incorrect;
keep a defensive copy or a private, explicitly transferred ownership path.

## Memory safety and Flutter ownership

The good evidence is that the tested payloads released after their owners were
closed: expiry purge, cache retirement completion and queue shutdown all returned
tracked live-payload counts to zero. Cancellation listeners, pending sleepers,
scoped finalizers and optional cache workers have explicit lifecycle paths. Core
remains SDK-only; native database/OpenAI integrations stay on backend surfaces.

Dart GC manages unreachable Dart objects. It does not bound reachable data or
replace deterministic socket/subscription/client cleanup. Finalizer callbacks are
[not guaranteed to run](https://api.dart.dev/dart-core/Finalizer-class.html), so
GC finalizers cannot replace awaited protected release. Conversely, “clear all
memory” or forced production GC is not an idiomatic fix for retained owners,
unbounded pending work or oversized buffers.

For a Flutter consumer, use an application/screen owner for its runtime and
services; stop subscriptions/owned work at the correct lifecycle boundary and
arrange awaited asynchronous shutdown where synchronous dispose cannot do so.
Release stale closures that capture UI/service state. Avoid creating a runtime
per widget build or wrapping every small field transform in a separate root.
Reuse safely owned pools/clients within their lifetime rather than repeatedly
opening and closing them. Pool capacity and idle duration are explicit budgets.

Use [DevTools Memory](https://docs.flutter.dev/tools/devtools/memory) for retaining
paths, instance/allocation traces and diff snapshots; use Flutter
[profile-mode performance captures](https://docs.flutter.dev/tools/devtools/performance)
for frame/input behavior. Browser behavior, native VM heap reachability, external
memory and RSS are distinct measurements. Falling live heap with high RSS does
not by itself prove a leak: VM arenas/JIT/profiler/native allocations also count.

No real Flutter consumer was profiled in this audit, and no universal leak-free,
production-safe, native-driver or frame-rate guarantee is claimed.

## Recommended work before another package

1. Fix packed HTTP storage and add aggregate request/payload memory budgets.
2. Replace wall-clock duration calculations and make deep cause conversion iterative.
3. Bound cache total owners/retirements and service pending queues, with explicit
   overload behavior; avoid deadlocking a borrower that tries to acquire another
   generation while holding the last permit.
4. Optimize completed cache hits and common root allocations, then investigate
   startup/empty-close hops with fairness, shutdown and type-safety regressions.
5. Run the resulting implementation through the core/cache/HTTP matrix, live
   under-pressure retention tests, a longer soak and a native Flutter profile
   journey on the target device. Choose acceptance budgets from that application
   and hardware rather than claiming one universal threshold.

Preserve typed error families, lazy re-execution, masked acquisition until release
registration, exactly-once cleanup, child ownership, stale-generation protection
and diagnostic ordering throughout. Do not achieve lower latency by abandoning
cleanup or removing fairness.
