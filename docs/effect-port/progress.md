# Progress and handoff — 7 October 2026

Repository note: upstream/npm snapshots, Node comparison tooling and generated
npm inventories are deliberately ignored by Git. Links to `references/` and
ignored inventories describe optional local evidence and will not resolve in a
fresh clone. Dart and database tests do not require those files.

The initially empty, non-Git workspace now contains `effect_core 0.1.0-dev.1`, an
independent portable Dart package. Phases 0–3 have a working local development
candidate with the limitations below. At the phases 0–3 checkpoint, no publication, deployment, application
migration, commit or push had been performed. No existing application was present.

## Phase 0 — local evidence

Completed bounded initial acquisition and froze reference contents. npm latest
was 4.0.1; explicitly resolved tag `effect@4.0.1` to full source SHA
`460272d30457f4697d8b8c52cad41caccbcace08`. Website source was independently pinned
to `ab792b825bd371cdf083754b7e1ff4f1096a7a68`, discovered via the official site's
organization link and official repository inventory. Source and npm package
versions agree. npm gitHead is absent, so publishing-source equality is not
asserted. Source/tests/internal modules, docs MDX/examples/navigation/API inputs,
normalized searchable guides, published core API pages, Dart references and
original archives are materialized locally. The pack occupies about 265 MB.

`references/effect/manifest.json` verifies 7,054 files, including preserved docs
symlink metadata. `urls.jsonl` has 514 mapping/status entries and 108 v4 guides
are preserved. Counts refer to URL-map statuses, including cached artifact
records and extracted source inputs, not an invented count of network requests.

Passed offline SHA-256, npm SRI/SHA1, package-version and archive-revision checks.
Also moved materialized upstream/docs-source/npm package trees aside, reconstructed
them exclusively from local archives, and verified the whole pack (see
restoration-results.json). Later restore with strengthened verifier passed.
Reference tooling has fetch, verify, restore, explicit refresh and local finalize.
Refresh requires an observed exact tag, stages acquisition, preserves prior pack,
and emits a pin diff requiring conformance/index review. No refresh was executed.

Four official sitemap/llms endpoints returned 404; source navigation and filenames
supply the versioned inventory. No core evidence gap blocks this implementation.
Website repository license is unidentified; reference-pack distribution rights
remain unresolved. Effect MIT source notices and Dart page notices are retained.
The local pack is usable offline; this is not certification for redistribution.

## Phase 1 — architecture and type contracts

Architecture/lifetime tables and initial type decision were written before broad
implementation. Contracts now document Dart's covariance explicitly: ordinary
concrete environment/error mismatches are rejected, but R widening permits misuse
which is guarded at runtime as a defect. Context key presence is runtime checked.
Typed key.bind gives direct value checks; widened additions have runtime checks.
A shared sealed error family and explicit aggregate environment compose APIs.
Five dedicated analyzer fixtures cover positive composition, accepted covariance,
and rejected error/environment/key programs. Four project-local skills validate
and AGENTS.md links them to the frozen pack. Independent review is embodied in
review_test.dart; agent roles stopped at a usage limit and root finished work.

## Phase 2 — runtime

Implemented lazy reusable constructors, iterative map/flatMap/defer execution,
expected/defect/interruption outcomes, Future boundaries, typed recovery/mapping,
provision, scopes and protected resource brackets, parent/scoped fibers, join,
interrupt-and-await, bounded traversal, first-success race, sleep, timeout and
shutdown. 100,000 binds are stack safe and fairness is tested by scheduling an
event inside the running chain. Cancellation propagates to waiting children,
completed-child listeners detach, and late Future values are ignored.

Cleanup is exactly once, LIFO and protected. Scoped resource children are awaited
before release. Body/cleanup causes are retained once, including partial layer
cleanup errors. Async abort hooks are awaited. Custom low-level scope errors
outside E become defects. Defective clocks are not translated into typed timeout.

## Phase 3 — services and policies

Implemented typed identity keys, immutable Context, basic dependency Layers with
scope-local in-flight sharing, diamond graphs, sequential dependency construction,
cycle/wait-graph detection and partial-acquisition rollback. Failed construction
invalidates its scope memo transaction and waits protected in-flight acquisitions
before release. Contexts from that domain must not be retained across failure.
Finite retry/repeat schedules implement limits, exponential delay, overflow-safe
zero delay and seeded jitter. Clock/logger injection and TestClock support
controlled testing. Four requested runnable examples are present and pass.

## Historical phase 0–3 validation

Environment: Dart SDK 3.13.0 stable, macOS arm64; Chrome browser tests. Dependencies
were installed/pinned separately from reference acquisition (`pubspec.lock`).
Node v22.23.2 is development-only; conformance restores npm locally from archive.

| Command | Result |
| --- | --- |
| dart format --output=none --set-exit-if-changed lib test example tool | 14 Dart files; zero changes |
| dart analyze | No issues found |
| dart test | 47 tests passed |
| dart test -p chrome | 47 tests passed |
| dart run tool/check_fixtures.dart | Five accepted/rejected fixtures passed |
| python3 tool/conformance/compare.py | Fourteen selected normalized observables match upstream |
| python3 tool/reference_snapshot.py verify | 7,054 files and integrity/version/revision checks passed |
| python3 tool/reference_snapshot.py restore | Local reconstruction and verification passed |
| dart compile js example/web.dart -o build/web-smoke.js | Passed |
| dart run example/{retry,resources,services,bounded}.dart (each separately) | response; open/close/connected; Hello, Dart; [2,4,6,8] |
| Dart JIT and compiled AOT benchmarks | Eleven samples after three warmups per workload; JSON retained |
| skill-creator quick_validate.py (each of four skills) | Passed |

See conformance-results.json, restoration-results.json, benchmarks.md and
validation-phase0-3.json for historical evidence/fingerprints. Performance baselines show overhead,
not speedups; no regression budgets are agreed and RSS is process-wide, not
allocation attribution. Benchmarks cover composition, deep chains, bounded
synthetic I/O and cancellation; policy/layer/stream performance is not measured.

## Remaining limits and deferred work

The user explicitly expanded scope to the entire ecosystem. This supersedes the
initial phase deferral. The initial concurrency and Stream/Sink foundation is now
implemented; schema/config/cache/observability and every external ecosystem
package remain unimplemented. Native Flutter/device/isolate checks are unrun.
See ecosystem-status.md for every upstream package and its current status.

Core differences and limits: cooperative cancellation cannot stop arbitrary I/O
without hooks or CPU loops; custom asyncExit must cooperate; never-finishing
protected work can delay shutdown forever. R is not full static dependency proof.
Only map/flatMap/defer depth is proved stack safe, not arbitrary region-wrapper
nesting. Scope rejects late registration, forkScoped has a narrower lifetime,
Cause is a sequential tree, layer failure invalidates its entire memo domain,
and unjoined/loser failures do not replace a successful parent/winner. See
feature-matrix.md, decisions/002-lifecycle-divergences.md and CHANGELOG.md.

No implementation blocker remains for the advertised subset. Wider parity,
performance budgets and documentation-snapshot distribution rights are separate
remaining gates. This is a local development candidate, not a production or
whole-ecosystem compatibility certification.

## Full ecosystem expansion — current validation

Implemented Ref, memoized Deferred, strict FIFO weighted Semaphore,
SynchronizedRef, zero-capacity/bounded Queue and bounded atomic PubSub. Implemented
pull-based EffectStream with map/mapEffect/filter/take, bounded buffering, scoped
acquisition/release and native Stream adapters; Sink supports fold, first, collect
and drain. Independent controlled interleavings test withdrawal, permit restoration,
lost wakeups, atomic fan-out and protected cleanup. Seeded state/List models test
observable behavior. A runnable buffered stream example uncovered covariance in
Sink callback access; fixed by invoking the callback within its original generic
context and added a widened-result regression. Rejected subscription scope
registration also rolls back, with a dedicated test.

Current checks (after those fixes):

| Check | Result |
| --- | --- |
| dart format --output=none --set-exit-if-changed lib test example tool | 21 Dart files; no changes |
| dart analyze | No issues found |
| dart test | 107 tests passed (47 existing, 34 concurrency, 26 stream) |
| dart test -p chrome | Same 107 tests passed |
| dart run tool/check_fixtures.dart | Five fixtures passed |
| python3 tool/conformance/compare.py | Fourteen runtime observables match pinned npm |
| python3 tool/conformance/compare.py --foundation | Six foundation records match pinned npm |
| python3 tool/reference_snapshot.py verify | 7,054 files plus npm/archive integrity checks passed |
| dart compile js example/stream.dart -o build/stream-smoke.js | Passed |
| dart run example/stream.dart | [6, 8], then first-value record (6) |

The inventory covers 39 manifests, 792 .ts source modules and 514 TS/TSX test files.
Only `effect` has a partial Dart implementation; all other packages remain
unported. The literal upstream test catalogue indexes 11,376 declarations; this
is approximate, not an executed or ported test count. Read testing.md for runner,
fixture, property-test, timing/cancellation design and detailed Dart cases.
Current source fingerprints are in validation.json. Existing benchmark recordings
remain historical phase 0–3 results; stream/concurrency performance is unmeasured.
No whole-ecosystem completion, API-equivalence or external integration claim is made.

## Latest user scope — reusable core, PostgreSQL and MySQL

The user replaced the full-ecosystem request with a focused Dart API package set,
using established pub.dev drivers. PostgreSQL/PG is one adapter using postgres
3.5.19. MySQL uses mysql_client_plus 0.1.3 after comparing current maintenance and
adoption evidence. Other Node package integrations are outside current scope.

Implemented optional effect_sql, effect_postgres and effect_mysql packages with bound
parameters, a lazy bounded pool, typed driver-error classification, scoped service
lifetimes, exclusive transactions, nested savepoints and expired handle checks.
Transaction body child fibers/finalizers finish before commit or rollback. Failed
commit/rollback discards uncertain connections. PostgreSQL interruption terminates
the local connection; MySQL drains active commands before rollback and reuse.
MySQL TLS certificate validation rejects by default instead of inheriting the
underlying driver's permissive callback. Test TLS pins the actual isolated server
certificate. Runtime dependencies remain zero in core; native adapter imports
remain outside core lib/. Development overrides are excluded from package archives.

Current SQL validation: 18 portable lifecycle tests, 13 PostgreSQL tests and 19
MySQL tests passed with no skips. Adapter counts include 11 PostgreSQL and 12 MySQL
real integration cases plus 2/7 driver classification/configuration cases.
The portable SQL suite also passes its 18 tests in Chrome. Core's 107 VM tests,
five fixtures, analyzer and JS compilation were checked again. Existing core
Chrome evidence is 107 passed; core sources did not change in this SQL milestone.
The isolated Docker runner uses pinned image digests, captures JSON results and
removes its test containers on exit. SQL detailed cases/contracts are in
sql-adapters.md; source fingerprints and counts are in sql-validation.json.

These are local development packages, not published artifacts or whole upstream
SQL API parity. Cursor streaming, migrations, query builders, production network
partition/load/soak tests, production CA deployments and database-version matrices
remain unimplemented or unverified as recorded in the adapter guide.

The PostgreSQL Layer/Context example executed against the isolated server before
the package rename. Both native adapter examples compiled to AOT executables. The
MySQL CLI example was not run against a production CA/hostname; real adapter tests
use an exact pinned test certificate and separately test default TLS rejection.

## Package rename — 2026-10-07

The public package family is now `effect_core`, `effect_sql`, `effect_postgres`
and `effect_mysql`. Dependency names, entrypoints, imports, local overrides,
examples, documentation and SQL acceptance tooling use these names. The core
package remains at the repository root. Public API type names are unchanged.

Analysis passed independently for all four packages. After the rename, all 157
VM tests passed, including the isolated PostgreSQL and MySQL acceptance suites
with no skips. Chrome passed 107 core and 18 portable SQL tests. Five analyzer
fixtures passed, the web example compiled, all five core examples executed, and
both native database examples compiled to AOT. Test containers were removed.
See `rename-validation.json` and the refreshed `sql-validation.json`. Earlier
JSON validation and benchmark records retain their original names and hashes
as historical evidence. The private GitHub repository is `iamudesharma/dart-effect`;
the working branch is `dart-effect`. Node/npm sources and snapshots remain ignored.

## OpenAI integration — 2026-10-07

The user added openai_dart to the focused scope. `effect_openai` uses 10.0.1
for lazy typed requests and scoped reusable streams, with independent abort
signals, owned/borrowed SDK lifetimes, Layer/Context provision, typed SDK failures
and generic endpoint wrappers. Primary helpers cover Responses, Chat, embeddings
and moderation. No Node/npm source is included.

Verified: 50 adapter VM tests (including eight actual loopback HTTP/SSE tests),
42 adapter Chrome tests, 107 core VM regression tests, five analyzer fixtures,
root/package analysis and formatting. The credential-free SDK example executed;
it compiled to JavaScript, and the live example compiled to a native executable.
Live OpenAI API/model acceptance was not run. Detailed contracts, test cases and
remaining boundaries are in openai-adapter.md and openai-validation.json.

## Next-priority work — 9 October 2026

Production SQL acceptance is in progress. The first task, isolated trusted CA
chains and hostname verification, passed three PostgreSQL and three MySQL tests
with zero skips/failures. All four owned containers were removed. No package
runtime code changed and no release was published.

The [ordered acceptance plan](acceptance-plan.md) defines the remaining recovery,
network-fault, soak and version-matrix tasks. Core 107 VM tests and five type
fixtures passed; both adapter analyzers and classification suites passed (2 PG,
7 MySQL). Broad root analysis encountered old ignored build/readme-checks source
errors; maintained lib/test/example/tool analysis passed independently. Existing
real transaction suites were not rerun in this TLS-only task.

## OpenAI performance evidence — 10 October 2026

Added [AOT timing and memory evidence](openai-performance.md), with direct SDK
comparisons, repeated VM post-GC owner checks, and six native macOS Flutter
profile runs. The adapter has measurable overhead, especially per-event SSE
interpretation; no speedup or universal leak freedom is claimed. Fifty VM and
42 Chrome adapter tests passed, plus 107 core tests and five type fixtures.
Maintained and broad root analysis passed after generated build probes and the
separate Flutter profile template were excluded from core analysis. The native
runner analyzes its generated Flutter lib independently. No runtime source or
package version changed, and no package was republished.

## Core and SQL performance evidence — 10 October 2026

[Current core and SQL measurements](remaining-performance.md) now cover the four remaining packages: repeated JIT/AOT core workloads, portable SQL overhead, verified-TLS real driver timing, queued/active cancellation recovery, bounded mixed load and post-GC retention. All 3,780 tracked closed targets were collected; 1,481,278 mixed-load operations completed with zero failed operations and peak executing command bound eight. Heap growth remains recorded; no universal leak-freedom or portable speedup claim is made.

Fresh functional validation passed 157 VM and 125 Chrome tests with zero skips/failures, four analyzers/format checks, five type fixtures, six core examples and both SQL examples. Owned containers were removed, including the initial MySQL bootstrap-readiness failure; resumed measurement provenance verifies unchanged Dart source hashes. SQL-P4 is delivered within its declared 30-second per-process scope. Connection-loss, proxy faults, version matrices, multi-hour production soak and mobile/app frame acceptance remain open. No published runtime source or package version changed.
