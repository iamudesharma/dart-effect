# Changelog

## 0.1.0-dev.1

Initial independent Dart port. Typed error families and concrete aggregate
environments replace TypeScript union inference. No generator DSL or ecosystem
compatibility. Context key presence is checked at runtime. Dart covariance permits widening R; mismatched provision through widening becomes a defect. Scoped forks are bounded by both parent and scope, unlike upstream scope-only longevity. Resource brackets create a local scope. Failed layer construction invalidates its whole scope memo domain. Cleanup failures use
a sequential Cause tree; race aggregates failures without upstream annotations.
Fibers are same-isolate async concurrency; cancellation is cooperative. No forced
cancellation of arbitrary Futures or CPU loops. Scope ownership and layer memo
sharing are explicit.

Added same-isolate Ref, memoized Deferred, FIFO weighted Semaphore,
SynchronizedRef, zero-capacity/bounded Queue and bounded atomic PubSub.
Added lazy pull EffectStream, fold/first/collect/drain Sink, scoped resources,
bounded buffer and native Stream pause/cancel adapters. Full ecosystem scope
was subsequently narrowed by the user to core, PostgreSQL and MySQL.
Detailed upstream runner/case documentation and literal test catalogue added.


Added optional effect_sql, effect_postgres and effect_mysql packages. PostgreSQL/PG
uses postgres; MySQL uses mysql_client_plus. Bound queries, bounded leasing,
transaction/savepoint callbacks, expired-handle checks, scope cleanup and typed
error classification are implemented. MySQL rejects invalid TLS certificates
by default and drains active work on interruption; PostgreSQL force-closes and
discards an interrupted connection. Real database and portable lifecycle tests
have an isolated pinned-image runner with teardown.

## Package naming

Renamed the provisional `blot_effect`, `blot_sql`, `blot_postgres` and
`blot_mysql` packages to `effect_core`, `effect_sql`, `effect_postgres` and
`effect_mysql`. Update both dependency names and package import paths.
The public Effect and SQL API types are unchanged. Earlier JSON validation
records retain the names and source hashes used when those checks ran.

## OpenAI integration

Added `effect_openai` for openai_dart 10.0.1: typed request helpers, reusable
Responses/Chat streams, generic SDK endpoint wrappers, isolated abort state,
scoped SDK ownership, typed failures, examples and transport/lifecycle tests.
