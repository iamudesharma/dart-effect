# Core and SQL performance, retention and bounded load

Measured on 10 October 2026. These development tools benchmark the current
`effect_core` 0.0.1, `effect_sql` 0.0.1, `effect_postgres` 0.0.2 and
`effect_mysql` 0.0.1 runtime sources. Runtime source hashes identify the measured
code. Versions are not changed and packages are not republished.

Effect provides typed outcomes, cancellation, scoped cleanup and bounded
ownership with measurable cost. These results are not a claim that wrapping a
Future or database request makes it faster. Use plain Futures where their simpler
lifecycle meets the application contract. Use Effect at service boundaries when
its ownership and error contracts are useful; measure the application's actual
workload before selecting a connection bound or frame budget.

## Dart-native method and prerequisites

The method follows [Dart native compilation](https://dart.dev/tools/dart-compile)
and [Dart/Flutter memory guidance](https://docs.flutter.dev/tools/devtools/memory).
Warmup is inspired by the Dart team's
[benchmark harness](https://github.com/dart-lang/tools/tree/main/pkgs/benchmark_harness).
The asynchronous socket and lifecycle probes use explicit awaited batches rather
than a synchronous harness that could time unawaited work. No benchmark dependency
is added to the published runtime.

Run from the repository root after installing each package's development
prerequisites. Normal runs remain offline: database images must already be
installed; missing images fail instead of being downloaded. Certificates are
fresh temporary root/intermediate/server fixtures. Both native comparison paths
verify the same CA and hostname without a certificate bypass.

```sh
python3 tool/remaining_performance.py
python3 tool/remaining_performance_validation.py
```

The first command writes [raw benchmark evidence](remaining-performance.json).
The second records [functional validation](remaining-performance-validation.json)
separately. An initial MySQL bootstrap-readiness failure was corrected before its
measurements were accepted. The recorded `resumed_from` provenance retains
completed core/portable-SQL/PostgreSQL runs only after checking that every measured
Dart source and lockfile hash is unchanged. A normal invocation reruns all scopes. Raw local validation logs and compiled binaries are under ignored
`build/remaining-performance/`. Upstream/npm and Node sources remain ignored;
the tooling consists of Dart and Python. Tools are excluded from package archives.

Core has both JIT and native AOT runs; SQL comparisons use native AOT. For every
workload and implementation, three fresh processes each execute three warmup
and nine measured batches. Implementation order alternates by repetition.
Reported medians pool 27 batch samples, with per-process medians and all samples
retained. Ratios are descriptive; there is no cross-machine performance gate.
Construction and execution are both included in core composition probes.

The direct SQL baseline calls the established Dart driver's connection and
prepared APIs, with a small development-only worker pool of eight connections.
It is not a comparison of the driver's production pool implementation. Both
paths use eight prewarmed connections, identical parameters, TLS, materialized
immutable rows and the same prepare/execute/deallocate behavior for MySQL.
Setup, connection prewarming and shutdown are outside timed batches. Profiler-requested GC runs separately; automatic GC remains part of measured execution.
Cancellation is checked separately with its own awaited-cleanup timing. Command counters count calls to `SqlConnection.execute`; driver-internal prepare/deallocate protocol messages are not separate workload operations.

Portable `effect_sql` is also measured against an explicit synthetic driver to
isolate lease/runtime overhead from socket and server latency. Synthetic results
are not real database performance evidence. Native adapters are server-side
packages; SQL performance belongs in an API process, not in a Flutter widget.
Native core results do not establish Flutter frame performance or mobile heap
behavior; the separate [OpenAI profile guide](openai-performance.md) records a
small macOS Flutter probe that also exercises core.

## Core workloads and results

Current host: **Apple M1, macOS arm64, Dart 3.13.0**. Drivers: `postgres` 3.5.19 and `mysql_client_plus` 0.1.3. Database image digests are pinned in the raw evidence.

| Core workload | Future AOT median batch µs | Effect AOT median batch µs | Effect/Future |
| --- | ---: | ---: | ---: |
| chain-10000 | 690 | 2,950 | 4.28× |
| chain-100000 | 9,078 | 39,503 | 4.35× |
| bounded-8 | 2,839 | 7,123 | 2.51× |
| stream-fold | 72 | 1,305 | 18.12× |
| resources | 19 | 603 | 31.74× |
| failures | 42 | 388 | 9.24× |
| cancel | 64 | 482 | 7.53× |

These are whole batches. For example, folding 1,000 items costs 1,305 µs versus 72 µs; 100 resource lifetimes cost 603 µs versus 19 µs. The absolute cost matters alongside the ratio. Effect has additional ownership, interruption and typed-outcome work; the baselines do not reproduce every lifecycle guarantee.

| Core workload | Future JIT median batch µs | Effect JIT median batch µs | Effect/Future |
| --- | ---: | ---: | ---: |
| chain-10000 | 866 | 3,719 | 4.29× |
| chain-100000 | 9,091 | 36,529 | 4.02× |
| bounded-8 | 3,806 | 10,590 | 2.78× |
| stream-fold | 378 | 1,797 | 4.75× |
| resources | 154 | 2,595 | 16.85× |
| failures | 123 | 1,709 | 13.89× |
| cancel | 784 | 2,753 | 3.51× |

## Native SQL and portable SQL results

| Driver / workload | Direct AOT median batch µs | Effect AOT median batch µs | Effect/direct |
| --- | ---: | ---: | ---: |
| postgres / serial | 23,681 | 25,509 | 1.08× |
| postgres / delayed | 118,078 | 112,439 | 0.95× |
| postgres / bounded-8 | 10,858 | 11,952 | 1.10× |
| postgres / transactions | 271,947 | 320,112 | 1.18× |
| postgres / failures | 13,362 | 15,547 | 1.16× |
| mysql / serial | 44,514 | 47,757 | 1.07× |
| mysql / delayed | 83,658 | 100,505 | 1.20× |
| mysql / bounded-8 | 18,073 | 21,088 | 1.17× |
| mysql / transactions | 583,579 | 666,705 | 1.14× |
| mysql / failures | 16,632 | 19,578 | 1.18× |
| synthetic / serial | 370 | 1,344 | 3.63× |
| synthetic / bounded-8 | 422 | 1,630 | 3.86× |
| synthetic / transactions | 406 | 1,198 | 2.95× |
| synthetic / failures | 253 | 639 | 2.53× |

The serial native query batches show about **8% PostgreSQL and 7% MySQL overhead** here. PostgreSQL delayed queries show a small faster median; this is not evidence that Effect speeds up database execution. All native workloads retain per-process medians and raw samples. Synthetic results isolate a different cost boundary and should not be compared with native database throughput.

## Bounded load results

| Database / implementation | Completed operations across three runs | Operations/s range | Per-run p95 latency upper bound | Failed operations |
| --- | ---: | ---: | --- | ---: |
| postgres / direct | 454,319 | 4,478–6,044 | 8 ms, 8 ms, 9 ms | 0 |
| postgres / effect | 482,674 | 4,977–5,647 | 8 ms, 8 ms, 9 ms | 0 |
| mysql / direct | 282,559 | 3,116–3,179 | 18 ms, 19 ms, 19 ms | 0 |
| mysql / effect | 261,726 | 2,841–2,996 | 19 ms, 19 ms, 20 ms | 0 |

Each run requested 30 seconds and awaited outstanding work at the deadline. All runs observed a peak of eight executing commands, and every pool closed with zero active/idle leases and matching opened/closed connection counts. Actual committed writes and read/write fractions are included per run. Throughput varies with the local Docker/server/cache environment; overlapping ranges are not a portable speedup claim.

| Cancellation recovery | Awaited cleanup range | Queued SQL executed | Fresh queries after cleanup |
| --- | ---: | ---: | ---: |
| postgres | 0.42–0.58 ms | 0 | 100 per repetition |
| mysql | 152.87–155.16 ms | 0 | 100 per repetition |

PostgreSQL force-closes affected connections. MySQL drains its 150 ms server-side commands before returning; an interruption request is not an immediate protocol abort.

## Bounded retention results

| Scope | Collected tracked targets across three Effect runs | Direct heap-used growth range | Effect heap-used growth range |
| --- | ---: | ---: | ---: |
| core | 1,620 | 0.60–0.60 MiB | 0.62–0.63 MiB |
| portable SQL | 720 | 0.55–0.55 MiB | 0.72–0.72 MiB |
| PostgreSQL | 720 | 1.03–1.03 MiB | 1.42–1.43 MiB |
| MySQL | 720 | 0.85–0.85 MiB | 1.09–1.10 MiB |

**All 3,780 tracked closed owners/effects/buffers were collected.** All idle checkpoints had zero live fibers, fiber contexts, scopes and SQL sessions. These checks passed with real observed GC; heap-used still grew, and Effect churn did additional work. External memory deltas and RSS series remain in the raw report.


## Functional validation result

The independent validation run passed **157 VM tests** (107 core, 18 portable SQL, 13 PostgreSQL, 19 MySQL) and **125 Chrome tests** (107 core and 18 portable SQL), all with zero skips/failures. Four package analyzers and formatting checks passed, five type fixtures passed, all six core examples and both native SQL examples ran, and the portable example compiled to JavaScript. TLS rejection/chain acceptance retains its separately dated six-test record; it is not added to these fresh totals.

Executed database versions: `postgres (PostgreSQL) 17.11`; `/usr/sbin/mysqld  Ver 8.4.11 for Linux on aarch64 (MySQL Community Server - GPL)`. PostgreSQL’s example used `PGSSLMODE=disable` only against its isolated loopback fixture; verified TLS was used throughout the native timing/load probes. Both validation-owned containers were removed. No live AI access, package publication or runtime changes were involved.

## Detailed scenarios and failure gates

| Scenario | Work per measured batch | Observable checks |
| --- | --- | --- |
| CORE01 / CORE02 | Construct and execute 10,000 / 100,000 flatMap steps | Exact final value, no recursive stack overflow; Future composition uses the same number of increments. |
| CORE03 | 1,000 event-loop operations, eight workers | Stable result order, no active operation at return, peak at most eight. |
| CORE04 | Fold 1,000 integers | Exact sum 499,500; Effect Sink and native Stream both consume every item without collecting the stream. |
| CORE05 | 100 acquire/use/release lifetimes | Acquired and released counts both exactly 100. Future baseline uses awaited work in try/finally. |
| CORE06 | 100 expected failures | Every Effect outcome is Expected; direct Future catches the same deliberate error. Defect distinction has separate functional tests. |
| CORE07 | 100 pending Future interruptions | Start handshake, Interrupted outcome, awaited cleanup, late Future settlement. The direct token/Future.any baseline has fewer ownership guarantees. |
| SQL01 | 100 bound serial queries | Exact Unicode/injection-looking parameter round trip; no command replay. |
| SQL02 | 20 queries with 2 ms server delay | Actual server-side delay, drained leases and exact command count. |
| SQL03 | 128 bound queries, eight workers | Exact row values, peak executing commands at most eight, zero busy commands at batch completion. |
| SQL04 | 40 transactions alternating commit and deliberate failure | Actual inserts: row count increases by exactly 20. BEGIN, INSERT, COMMIT/ROLLBACK count is exact; failures are retained, writes are not replayed. Synthetic variant verifies only commands, not database durability. |
| SQL05 | 40 duplicate-key failures then successful read | Real constraint codes become expected SqlFailureKind.constraint; connection remains usable and exactly 41 commands are executed. |
| SQL06 | Cancel a ninth acquisition while eight driver commands run, then interrupt those commands | Canceled acquisition executes zero SQL; all eight exits are Interrupted; cleanup is awaited, leases return to zero, and 100 fresh bound queries succeed. PostgreSQL replaces force-closed sockets; MySQL drains commands and reuses them. |
| MEM01 | Warm workload plus six mixed-work checkpoints | Observed VM-service GC at each snapshot; zero live Fiber, FiberContext, Scope and SqlSession at idle checkpoints. |
| MEM02 | Create, run and close captured-payload owners between checkpoints | WeakReference targets for owners, effects and 256 KiB buffers all become unreachable. Strong positive control remains reachable. |
| LOAD01 | Three fresh 30-second mixed-load processes per native driver and implementation, eight workers | Completed/failed operations, committed rows, millisecond latency histogram, sampled RSS, connection/command bounds and fully awaited owner shutdown. |

All invariants fail the process on mismatch. The report stays unsuccessful if
any process, class-retention check, GC observation, transaction invariant or
owned-container cleanup fails. Recorded source hashes are verified by the
website build. Failed, skipped or partial evidence cannot close a roadmap gate.
Functional VM/Chrome tests and real database lifecycle contracts are recorded
separately from measured operation totals.

## Memory interpretation

Heap diagnostics run in separate JIT processes with the Dart VM service, not
inside AOT timing. Each has a warmed baseline and six checkpoints. A requested
GC is accepted only when `dateLastServiceGC` changes; duplicate private class
names are tracked independently by class ID. Both heap-used and external memory
are recorded. RSS includes the VM, JIT compiler, profiler and socket machinery,
and is not an allocation attribution or a Dart heap leak test.

One warmed runtime and, for SQL, one reusable eight-connection pool intentionally
remain alive while snapshots are taken. Closed-owner churn is additional Effect
work, so total heap growth is not an equal-work allocation comparison with the
direct baseline. WeakReference collection and zero live lifecycle objects prove
these bounded owner checks passed; they do not prove universal leak freedom.
There is still post-warmup heap growth. Raw checkpoints retain that evidence
rather than applying an arbitrary RSS threshold or hiding growth.

## Scope and remaining acceptance

The native SQL load is a bounded development run on loopback Docker databases.
Latency percentiles use 1 ms upper-bound histogram buckets; the final bucket
includes values at/above 5,000 ms. Work continues until the duration deadline,
then outstanding commands finish before assertions and shutdown. Throughput
counts whole operations, with committed transactions recorded separately from
reads; it is not individual SQL-command throughput. The mixed scheduler chooses
transactions from the shared completion counter, so actual read/write fractions
are retained rather than assumed identical across runs.

These results close SQL-P4's declared bounded-load gate, not connection-loss
(SQL-P2), proxy/network interruption (SQL-P3), HA failover, multiple database
versions (SQL-P5), multi-hour production soak, large result sets, slow consumers,
production TLS rotation, mobile devices or real application frame budgets.
Current stream APIs are benchmarked through a fold; this does not cover every
stream operator or arbitrarily deep region-wrapper nesting. Follow the
[sequential acceptance plan](acceptance-plan.md) for outstanding work.

The former [core benchmark record](benchmarks.md) remains a historical checkpoint;
use this report for the current source. OpenAI performance evidence remains
separate and is linked from its own guide.
