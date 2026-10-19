# Package memory and scheduling fixes — 19 October 2026

This is an **unpublished implementation follow-up**, based on merged main after
PR #14. It covers the seven implemented packages: core, cache, HTTP, SQL,
PostgreSQL, MySQL and OpenAI. It does not import the unfinished toolkit PR #13.
The [earlier audit](core-memory-audit.md) and its JSON remain unchanged as the
before-change evidence. Reproduce that original audit from commit `851dd25`;
its old saturation probe intentionally assumes the former unlimited owners.
Current proof is [memory-fixes-validation.json](memory-fixes-validation.json).

## Findings and disposition

| Audit | Implemented response | Remaining boundary |
| --- | --- | --- |
| A1 | Both cache types bound total unfinished/resource owners, including retiring generations, with `maxOwners` (default twice resident capacity). Admission rejects immediately, optionally mapped by `onCapacity` into E. | Protected cleanup is awaited. Arbitrary values, borrowers and caller-created root fibers still require application budgets. Nested refresh cannot deadlock waiting for its own last owner permit. |
| A2 | Queue producers/consumers, semaphore waiters and hub publishers now have finite `maxPending` (default 1024); hubs also cap subscribers. SQL exposes the pending lease budget. | Bounds count owned records, not payload bytes or already-created caller tasks. Acquire admission before constructing expensive payloads. A rejected offer returns `QueueFull`, within the existing QueueClosed error family; it does not close the queue. |
| A3 | HTTP uses packed Uint8List defensive storage, BytesBuilder accumulation and a private owned-byte transfer. Combined request/SSE admission defaults to 32. Buffered responses share a 32 MiB logical byte budget. | Returned responses belong to callers. Transport chunks, transient growth/copies, decoding and SSE strings are separate costs. Logical byte limits are not a process RSS ceiling. |
| A4 | Runtime/span metrics, retry budgets, circuit cooldowns and limiter slots use elapsedTime. Stateful limiter/breaker instances require the same Clock object across uses. | Legacy Clock implementations retain documented wall-time fallback. Wall timestamps and Retry-After date interpretation remain wall time. |
| A5 | Cache close uses a microtask instead of an event timer; empty scopes avoid scheduling their cleanup callback. | Root startup and interpreter event yields are deliberately preserved for fairness, registration and cancellation-before-start. Removing every event hop would risk starvation. |
| A6 | Completed cache entries retain validated Exit values and discard Fiber/token references. Warm hits and peek read the outcome directly. | Pending shared loads still have interruptible independent waiters and explicit lifetime. |
| A7 | Cancellation futures/listener sets and scope containers allocate lazily. Pure/sync/map leaves avoid context cloning; synchronous interpreter leaves avoid an await. Already-compatible Exit/Cause values are reused. | This is a targeted reduction, not a claim of zero allocations. Environment/covariance checks remain at extension boundaries. |
| A8 | Existing explicit idle maintenance/purge is retained and tested, with documentation requiring it when idle memory release matters. | TTL is intentionally lazy by default. No implicit timers or forced production GC were added. Resident capacity counts entries, not arbitrary value weight. |
| A9 | Traverse pulls inputs on worker demand, preserves result order and stops pulling after failure. Empty input with huge concurrency no longer allocates that many workers. runCollect accepts maxItems/onLimit. SQL adapters avoid redundant intermediate row-list copies. | Successful traversal/SQL results are still materialized. Use stream folds, pagination and bounded queries. A driver may buffer results before the adapter sees them. |
| A10 | Cause mapping, restoration and timeout diagnostic filtering are iterative. Foreign expected leaves become defects while neighboring valid errors survive. | This fixes cause-tree conversion; arbitrarily nested region wrappers still have the separate documented stack-depth limitation. |
| A11 | Existing safe cancellation/drain ordering is preserved; SQL admission is bounded and lifecycle metrics use elapsed time. | MySQL has no public command cancel API. Cleanup/drain can exceed a timeout; silently abandoning a busy socket or finalizer would be incorrect. Actual provider/server deadlines need application-specific configuration. |
| A12 | Diagnostic drain/drop counters and explicit owner shutdown are retained and documented. | Typed error payload sizes cannot be bounded generically without losing diagnostics. Drop closed owners and drained records when no longer needed; a reachable object is not itself a leak. |

A further native SQL review found that MySQL prepared-statement deallocation
could hide the command error. The driver now transports both failures through
SqlCommandCleanupException; SQL classifies them independently into an ordered
Sequential Cause and discards the uncertain connection. The regression test
proves both error identities, operation names and pool recovery on a fresh lease.

OpenAI additionally shares one finite admission limit (64 by default) across
requests and streams. Rejection is `OpenAIFailureKind.overloaded`, before invoking
the SDK. Cancellation still aborts/drains; slots are released when work settles.
The pool uses `SqlFailureKind.overloaded`; semaphore callers may supply `onFull`.
Cache/semaphore overload without an error mapper is a StateError defect, never
interruption and never a silently dropped success. New enum cases may require
updating exhaustive application switches before adopting the eventual release.

## Validation contracts

`python3 tool/validate_memory_fixes.py` records fatal-info analysis, independently
resolved packages, all portable package tests on VM/Chrome, native driver
classification tests, analyzer type fixtures, examples, web compilation, native
AOT/JIT scheduling/correctness, packed-byte retained heap and three fresh
requested-GC processes under saturated cache/queue ownership.

For real PostgreSQL/MySQL contracts and examples, first run:

```sh
python3 tool/sql_integration.py --report build/memory-fixes-sql.json
python3 tool/validate_memory_fixes.py
```

The SQL runner starts isolated pinned database containers, removes only those it
created and records skipped TLS suites separately. A skipped TLS suite is not
fresh CA-chain acceptance. OpenAI tests use actual SDK HTTP/SSE fixtures without
an API key. They are not a live OpenAI provider test or an attempt to use ChatGPT
credentials. Flutter physical-device frame profiling and production soak remain
separate acceptance work.

The SDK's [packed byte builder](https://api.dart.dev/dart-typed_data/BytesBuilder-class.html)
and [event-queue starvation guidance](https://api.dart.dev/dart-async/scheduleMicrotask.html)
inform the implementation. Measurements use the installed SDK recorded in the
JSON, independently from the current online documentation patch version.

## Executed follow-up results

- Fatal-info analysis and five analyzer fixtures passed.
- 269 VM tests and 245 browser tests passed without skips in the portable and
  driver-classification matrix. This includes 137 core, 38 cache, 13 HTTP,
  21 SQL and 51 OpenAI VM cases, plus nine driver classification cases.
- Real PostgreSQL/MySQL runner: SQL 21, PostgreSQL 13, MySQL 19 passed; six
  separate TLS cases were skipped without their dedicated CA-chain environment.
  Both database examples printed the expected greeting; all created containers
  were removed. Those suites include classification tests also counted above;
  totals must not be added as if all cases were unique.
- All seven root examples ran, plus cache/OpenAI examples and HTTP against a
  local loopback server. Core web compilation passed. Website source checks
  passed (37 pages); no hosting deployment is part of this change.
- JIT and AOT retained all 50,001 expected errors at cause depth 50,000.
  A 10 ms monotonic operation reported 10 ms after a one-day wall rewind, and
  the limiter requested zero extra delay. Traverse generated one input before
  its first failing operation, rather than all 10,000 inputs.
- Three fresh VM processes each retained at most two blocked cache owners and
  two queue producers under configured limits, rejected 62 excess operations
  per scenario, then collected every tracked payload after release/purge/close:
  **36/36 tracked payloads** across the three scenarios/processes.
- A 4 MiB HttpResult retained 4,195,024 additional heap bytes, versus the earlier
  33,558,096-byte audit measurement. This is constructor-only retained storage,
  not request peak RSS. The unchanged read-only HTTP probe's `current-HttpResult`
  samples measure this branch's modified production implementation.
- In this native AOT sample, root success p50/p95 was 4/5 µs and warm cache
  hit 5/5 µs (2,000 operations each). Earlier samples were 5/5 and 6/6 µs.
  This is a host observation with measurement noise, not a statistical speedup
  guarantee or Flutter frame result. Root fairness remains explicitly tested.

Before any future publication, assign release versions and raise sibling
dependency minimums to the releases containing these new APIs. All checks here
use the documented local development overrides; hosted-only consumer acceptance
and publication remain separate gates.
