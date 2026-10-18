## 0.1.0-dev.1

Unpublished development implementation; requires development core 0.0.3-dev.1.

- LRU value caches, shared loads, separate success/expected-failure TTL,
  nullable-safe inspection and immutable counters.
- Scoped resource generations, callback-based refresh, idle expiry,
  invalidate-all and exactly-once release after borrower cleanup.
- Explicit periodic expiry/refresh with injected clocks and awaited shutdown.
- Preserve plain-cache retirement diagnostics and distinguish scoped acquisition
  outcomes from appended cleanup failures. Bound diagnostic history to 32 records.
- Contract, concurrency, deterministic state-model, Chrome and real HTTP tests;
  reproducible JIT/AOT and post-GC reachability tooling.
