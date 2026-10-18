# Cache lifecycle, acceptance and performance

The `effect_cache 0.1.0-dev.1` cache scope is implemented and locally validated.
It remains **unpublished**, dependent on development core `0.0.3-dev.1`. This is
completion of the documented value/resource cache contracts, not full Effect
API parity or production acceptance of every backend. Pools, ScopedRef,
persistence, distributed caching and stale-while-revalidate are separate work.

## What changed

- Retirement diagnostics now survive plain-cache invalidation, eviction and
  shutdown. Refresh propagates failed retirement instead of discarding it.
- Scoped acquisition errors reach callers without becoming false shutdown
  errors. Appended root cleanup diagnostics remain available. The runtime
  recreates typed Cause nodes, so comparison preserves cause shape and leaf
  identity instead of relying on Cause-node identity.
- Retirement interrupts pending scoped acquisition, while protected acquisition
  still finishes and releases safely. Existing borrowers retain their generation
  until their own scoped cleanup ends.
- Both caches expose immutable metadata/counters, explicit idle-expiry purging
  and one optional periodic expiry/refresh worker. Scoped refresh is callback
  based; invalidate-all retires every resident generation.
- Diagnostic history is bounded to 32 records with a dropped-record counter and
  an explicit drain. Repeated close calls share one awaited completion.

## Contract tests

**35 VM tests and 34 Chrome tests passed with zero failures or skips.** The VM
count includes the native HTTP fixture; Chrome runs the portable cache contracts.
Core regression: **131 VM tests**, root/package analysis with fatal infos, five
analyzer fixtures, executable example and example web compilation also passed.

| Boundary | Observable checks |
| --- | --- |
| Lazy single-flight | Constructing get starts nothing; thirty waiters share one root; independent waiter cancellation leaves the owner alive |
| Expiry | TTL starts after completion; exact boundary expires; zero TTL does not retain; success/failure lifetimes differ |
| Error classification | Expected-only negative caching; defects/composites are never retained; nullable success differs from absence |
| LRU/capacity | Pending entries count; eviction interrupts a pending owner; metadata inspection does not touch LRU; immutable snapshots |
| Generation races | Invalidation prevents stale reinsertion; strict refresh shares the replacement with reads; scoped old/new borrowers overlap safely |
| Cleanup | Cancellation hooks run; invalidate/close await protected cleanup; retirement errors survive; borrower cleanup precedes resource release |
| Scoped failure | Expected acquisition failure does not poison close; appended acquisition cleanup survives; throwing borrower callbacks release their lease |
| Maintenance | Idle release without another read; deterministic ticks; expired keys refresh; positive interval/one worker; typed worker failure; close removes sleepers |
| Shutdown | Repeated close is idempotent; new loads fail after close; protected acquisition finishes before release; runtime misuse leaves cache closable |
| Bounded history | Forty retirement failures retain 32 records and count eight dropped; drain resets history |
| State model | 500 seeded mixed get/invalidate/purge/clock operations agree with an independent LRU/TTL model |
| API consumer | Real loopback HTTP: thirty concurrent reads cause one request, tenant keys isolate, HTTP 503 stays typed and a subsequent lookup recovers |

Tests use controlled completers, manual clocks and bounded event-turn waits,
not arbitrary wall-clock sleeps. The end-to-end example asserts deduplication,
TTL reload and exactly-once scoped generation release. It is not a Flutter app
or an external provider test.

## Frozen reference and deliberate differences

Offline snapshot verification passed for 7,054 files: Effect 4.0.1, source
`460272d30457f4697d8b8c52cad41caccbcace08`. Cache/ScopedCache source and tests
were inspected, including single-flight, refresh, invalidation and capacity cases.
The attached review links 4.0.5; that is not the local source revision and was not
silently fetched. Upstream material remains ignored and is not distributed.

The Dart contract deliberately differs: the explicitly borrowed runtime owns a
load even after its last waiter cancels; only completion/retirement stops it.
Refresh strictly replaces a generation rather than serving stale data. Scoped
borrowers retain retired resources until use and cleanup finish. The public API
uses Dart callbacks and immutable snapshots rather than reproducing the npm
inventory. Detailed ownership limits appear in the package README.

## Measured overhead

Recorded on macOS arm64, Dart 3.13.0, eight logical processors. Each timing uses
seven alternating-order samples of 2,000 operations after warmup. These are
local microbenchmarks; the baseline is a map plus Future without Effect's typed
failure, root lifetime or interruption semantics.

| Workload | JIT cache / direct median | AOT cache / direct median |
| --- | --- | --- |
| Cached read | 13.456 / 0.356 µs | 8.234 / 0.286 µs |
| Miss with bounded churn | 20.729 / 0.464 µs | 16.713 / 0.4225 µs |

There is real overhead: around 29× the tiny direct baseline for AOT hits in this
run. The cache's benefit is avoiding backend work and controlling ownership;
its wrapper does not make a single map lookup or network request faster. The
HTTP test demonstrates thirty reads reduced to one backend lookup. Results
vary with JIT warmup and host load; previous exploratory timings were higher.
No latency SLO or browser/mobile performance guarantee follows from these data.

## Post-GC memory evidence

Three independent VM processes each ran three measured churn cycles after warmup.
Each cycle loaded 1,000 values of 64 KiB with capacity 32 and acquired/released
200 scoped generations. Every owned scoped generation released exactly once.

All **117/117 tracked weak references** to closed caches, runtimes and sampled
payloads were collected after requested and observed GC. Each checkpoint had
zero retained runtime Fiber/FiberContext/Scope instances. Live positive controls
remained reachable. Each process's final-minus-first heap use grew 130,288 bytes;
external heap growth was zero. RSS includes VM/JIT/profiler allocations and is
recorded in the JSON, not treated as a leak verdict. This is bounded reachability
evidence, not universal leak freedom or a multi-hour production soak.

## Reproduce and package readiness

From the repository root, with SDK/pub/Chrome prerequisites installed:

```sh
python3 tool/cache_validation.py
```

The runner checks source fingerprints remain stable, runs the contracts and core
regression, examples, JIT/AOT comparisons, three fresh memory processes and a
standalone archive dry-run. Logs live under ignored `build/cache-validation/`.
The public record is [cache-validation.json](cache-validation.json); it does not
rewrite older toolkit, release or benchmark evidence. CI runs the same command.
Remote CI status is separate from this recorded local success.

The isolated `dart pub publish --dry-run` passed with **zero warnings and one
hint**, for the required development core override. Isolation matters: the core
repository's ancestor `.pubignore` excludes `packages/` from the core archive,
so running publication directly from a nested folder can incorrectly select an
empty archive. The runner stages the standalone package outside that tree and
verifies its manifest, license, README, examples and tests; overrides/lockfile are
excluded from its archive. No package was published. A compatible core release,
fresh hosted-only consumer check and explicit publication are still release gates.

Underlying I/O cancellation depends on the lookup's abort hook. Capacity bounds
resident slots, not bytes or in-flight retired generations. Application concurrency
limits, real backend policy, production soak and physical-device acceptance remain
application-specific work.
