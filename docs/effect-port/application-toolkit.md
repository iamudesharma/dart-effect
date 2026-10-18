# Application toolkit — development implementation

This work follows the 18 October 2026 attached review's recommended application
toolkit. RPC, workflows, clustering, CLI and GraphQL remain future product
proposals by explicit user choice. The review used default-branch d7dcbbb;
core 0.0.2 / HTTP 0.0.1 publication and website synchronization already existed
on the release branch before this work. Their published status is unchanged.

## Inventory and release boundary

**None of these development additions are published.** Core is 0.0.3-dev.1,
HTTP is 0.0.2-dev.1, and thirteen new packages are 0.1.0-dev.1. Use explicit local
path dependencies and the provided sibling overrides. Do not install these
unfinished versions into other applications as though they were hosted releases.
The canonical shared Effect skills catalog distinguishes local fingerprints from
registry verification. No upstream/npm sources or credentials are committed.

| Package | Implemented initial contract | Important remaining breadth |
| --- | --- | --- |
| effect_schema | Pure and Effect decoding, encoding, structural JSON Schema, nested issues, first/all modes, primitives/literals/lists/unions, recursive runtime models, refinements, defaults and renamed/optional object fields | Generated classes, dictionary combinators, recursive JSON Schema references, service-aware validators beyond flatMap composition |
| effect_config | Immutable providers, missing/invalid separation, typed port/URI/duration/boolean/int, fallback/nesting, explicit redaction | Rich aggregate derivation and generated environment interfaces |
| effect_cache | LRU capacity/TTL, single-flight loads, optional expected-failure TTL, refresh/invalidate/peek; scoped generations with borrower-held lifetimes | Idle-refresh schedules, specialized reusable pool/ScopedRef APIs |
| effect_batch | Tenant/auth grouping, identity deduplication, finite collection window, bounded pending work and batch size, one backend batch at a time | Adaptive/multi-backend scheduling and persistent cache integration |
| effect_reactivity | Latest-value SubscriptionRef and typed graceful Channel completion/failure | Lossless state histories and framework-specific Riverpod/BLoC bindings |
| effect_test | Automatic runtime teardown, typed Cause matcher, captured logs and bounded suspension/clock helpers | General heap leak detection and randomized schedulers |
| effect_flutter | ValueListenable controller/state, latest request wins, awaited replacement/close, no notifications after disposal | EffectStream/SubscriptionRef bindings, mobile journeys and persistence |
| effect_platform | Native environment/JSON configuration and killable one-shot isolate work | Worker pools, browser workers and serialization protocols |
| effect_sqlite | Established sqlite3 driver, prepared binds, one-connection pools, real transactions/rollback and constraint mapping | Browser/Wasm, cursor streaming and long-query worker architecture |
| effect_sql_schema | Row validation/cardinality, SQL/domain failure family, locked migration ledger/checksum checks | PostgreSQL/MySQL migration acceptance, driver cursors, fragments and bulk APIs |
| effect_ai | Provider-neutral model contracts, structured JSON generation, validated registered tools, bounded explicit agent steps/token admission | Concrete provider bridges, semantic acceptance, persistence, priced cost budgets, realtime/MCP |
| effect_observability | Bounded series, counters/gauges/histograms, Prometheus text, W3C traceparent and bounded explicit exporter lifecycle | OTLP wire protocol, complete span model, fiber-local context and instrumentation adapters |
| effect_http_server | Exact routing, typed/schema JSON handlers, body/admission limits and owned runtime shutdown | Streaming responses, multipart, TLS termination, shared API/OpenAPI/client derivation |

These are usable initial implementations, not completion of every bullet in the
review or full Effect ecosystem parity. The remaining breadth above is retained
as work, not hidden behind placeholder public APIs.

## Core and existing HTTP additions

- ManagedRuntime builds a Layer graph once, shares services between requests,
  rejects new work after close, interrupts requests and awaits their cleanup
  before releasing services. Service-close failures stay observable in Exit.
- Composition adds tap, asValue/asUnit, zip/zipWith, conditional execution,
  selective/subtype recovery, outcome inspection, hooks, first-completion race,
  scoped acquisition and pure Result. Cause inspection is iterative.
- Layer merge/provide remains sequential, memoized within one build scope.
- Streams add public fromPull/unfold sources, concat/flatMap, tap/index/scan,
  grouping and bounded ordered concurrent mapping. Concurrent mapping processes
  joined chunks rather than unbounded asynchronous read-ahead.
- Queue complete drains accepted values; takeOption distinguishes graceful end
  from destructive shutdown. Channel adds typed terminal failures. PubSub offers
  bounded replay and explicit backpressure/dropping/sliding policies; dropping
  rejects the entire publication if any subscriber is full.
- RealClock and TestClock expose optional monotonic elapsed time. Existing
  third-party Clock implementations remain source-compatible with a documented
  wall-time fallback. Shared breakers/limiters must use the same clock domain. Retry budgets, breakers, rate limiting, cache TTL and
  runtime duration metrics use elapsedTime. Timestamps/Retry-After dates use UTC
  wall time. Infinite retry/repeat is explicit, input-controlled repeat is
  supported, and zero-delay loops yield for timer/cancellation fairness.
- HTTP status errors retain bounded, explicitly accessed diagnostic text and a
  truncation flag; it is not logged automatically. Immutable request builders
  support headers/query/JSON. Requests and partial streams still never replay
  automatically.

## Lifecycle contracts

Plain cache shared loads belong to the explicitly borrowed runtime, not an
individual waiter. Cancelling one waiter leaves the shared load available to
others. Invalidation/eviction interrupts removed loads; stale completion cannot
reinsert an old generation. Capacity includes pending keys. Close caches and
resolvers before shutting down the runtime they borrow.

Scoped cache entries own a root scope. Eviction retires the generation; existing
borrowers finish before its release. New borrowers use a replacement generation.
Close awaits all borrowers and reports cleanup diagnostics. Capacity bounds
resident generations; active retired generations depend on application-level
concurrency limits. Never call close from inside a borrow that it must await.

Cache keys must include tenant and authorization identity where data differs.
Request resolver identity is (group,key); group must include tenant and auth
identity. Waiter cancellation does not abort another caller's batch. The pending
bound counts accepted unique requests. Protocol omissions become defects;
per-key expected errors retain their type. No implicit retries are introduced.

Flutter dispose initiates closure and prevents notifications; it cannot prove
async cleanup has completed. Owners requiring that guarantee must await close.
Isolate cancellation kills the worker and cannot guarantee worker finally blocks.
Do not acquire external resources inside a killable CPU computation.

SQL domain wrappers map an explicit sealed domain/SQL error family through the
existing rollback implementation; they do not turn domain failures into success
and accidentally commit. SQL errors during rollback stay sequential with the
body's domain cause. Migration ledger names/checksums are verified before adding
work. SQLite migrations are tested; PostgreSQL/MySQL dialect acceptance remains
unrun. MySQL DDL auto-commit prevents general rollback guarantees: transactional
DML or a dedicated database-specific rollout is required.

## Recommendation coverage and remaining engineering

The public packages cover initial slices of review areas 1–5 and 8–18. Area 6's
general region-wrapper stack safety, masking/restoration API, forkIn and advanced
supervision remain open; existing map/flatMap/defer stack-safety guarantees are
unchanged. Area 7's generated dependency evidence is still open; Dart covariance
and dynamic Context membership remain documented limitations. Broader schedule
algebra/calendar/cron and stream merge/recovery/time-window/leftover semantics
are not implemented by these initial finite/infinite and ordered-chunk operators.
Resource-sharing APIs beyond scoped-cache leases are still future toolkit work.

Do not call the full eighteen-area recommendation complete. The package inventory
and executable foundations are delivered; the table identifies the remaining API
and acceptance work. Durable/distributed product directions stay on the roadmap.

## Reproduce validation

Install the supported Dart/Flutter SDK and populate pub cache first. Normal
package execution and frozen upstream references remain offline:

```sh
python3 tool/application_toolkit_validation.py --browser --sql
```

This independently analyzes and runs every package, checks portable scenarios in
Chrome, runs self-contained examples, compiles the core web example and exercises
type fixtures. Native SQL acceptance requires the preinstalled pinned Docker
images and OpenSSL; it excludes the separately dated negative TLS-chain suite.
It writes only application-toolkit-validation.json, retaining older acceptance
and benchmark reports. CI configuration is included; local success is not a claim
that GitHub CI or physical-device acceptance has run.

Final local verification: **19 packages analyzed, 283 VM/Flutter tests and 226
Chrome tests passed**, plus five type fixtures, seven core examples and twelve
self-contained toolkit examples. The native PostgreSQL/MySQL selected suites
passed without skips and their owned containers were removed. Six negative TLS
chain checks retain their separately dated record. SQLite stale row-count/ID
reporting was corrected during audit and its two tests, three SQL-schema tests,
example and root analysis reran afterward; source hashes and the follow-up are
recorded in [application-toolkit-validation.json](application-toolkit-validation.json).
GitHub CI also passed for implementation revision ffd5523: [portable-and-native run](https://github.com/iamudesharma/dart-effect/actions/runs/39127337766). This does not add live-provider or physical-device acceptance.
