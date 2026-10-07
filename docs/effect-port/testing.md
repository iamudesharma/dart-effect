# Test design and the upstream npm ecosystem

Repository note: upstream/npm snapshots, Node comparison tooling and generated
npm inventories are deliberately ignored by Git. Links to `references/` and
ignored inventories describe optional local evidence and will not resolve in a
fresh clone. Dart and database tests do not require those files.

The executable Dart tests are independent scenarios derived from the frozen
Effect 4.0.1 contracts. The npm artifact contains published runtime code; upstream
TypeScript tests and its test runner are in the separately pinned source tree.
We compare selected normalized outcomes against the actual npm runtime and test
Dart-specific lifecycle behavior on the VM and Chrome. An upstream test inventory
is evidence of scope, not evidence that those tests have passed in Dart.

## How upstream writes its tests

The repository uses Vitest projects, not the Node built-in test runner.
[vitest.config.ts](../../references/effect/upstream/vitest.config.ts) selects
package-specific test projects. React/Solid use jsdom and Vue uses happy-dom;
Node/Bun/Deno platform suites depend on runtime availability. Integration and
cluster suites are gated by `EFFECT_INTEGRATION_TESTS` and `EFFECT_CLUSTER_TESTS`.
Coverage uses V8 with HTML output. The normal test glob excludes integration
files by default. A successful ordinary test run does not establish database,
network, cluster or browser-framework integration compatibility.

Tests commonly import `assert`, `describe` and `it` from
[@effect/vitest](../../references/effect/upstream/packages/vitest/src/index.ts).
`it.effect` returns an Effect, often built with `Effect.gen`; the harness scopes
it and provides TestConsole and TestClock. `it.live` scopes the effect with a
live environment. Layer fixtures can share a scoped construction with cleanup
at suite completion. Property tests generate arbitrary values and shrink a
failure to a smaller counterexample.

The [runner implementation](../../references/effect/upstream/packages/vitest/src/internal/internal.ts)
connects Vitest's AbortSignal to fiber interruption and awaits effect finalizers
when the test finishes. A test timeout must clean up its child work; a synchronous
infinite callback still cannot be preempted. Fake-clock tests explicitly adjust
TestClock instead of sleeping in wall time.

[Queue.test.ts](../../references/effect/upstream/packages/effect/test/Queue.test.ts)
lowers `Scheduler.MaxOpsBeforeYield` to expose a producer completing between an
empty check and waiter registration. Its helper yields up to a bounded number
of turns and checks fiber completion: this detects lost wakeups without hanging
the test suite. Tests include zero-capacity rendezvous, capacity limits, parked
batch producers, interruption withdrawal and duplicate-delivery regressions.

[Deferred.test.ts](../../references/effect/upstream/packages/effect/test/Deferred.test.ts)
checks first completion wins and distinguishes `complete` (evaluate and memoize
an Exit) from `completeWith` (store an Effect that can run for each await).
[Ref.test.ts](../../references/effect/upstream/packages/effect/test/Ref.test.ts)
checks both returned results and committed state. Our Ref.update returns the
new value and corresponds to upstream updateAndGet.

[Semaphore.test.ts](../../references/effect/upstream/packages/effect/test/Semaphore.test.ts)
includes weighted permits, partition sharing, fairness and restoration.
PartitionedSemaphore and dynamic resize are not implemented in Dart. Our
Semaphore rejects a weight beyond capacity; upstream can park that request.

[PubSub.test.ts](../../references/effect/upstream/packages/effect/test/PubSub.test.ts)
parameterizes capacities/strategies and checks per-subscriber ordering and
unsubscribe behavior. Dart currently offers bounded backpressure only; sliding,
dropping, replay and batches need independent milestones.

[Stream.test.ts](../../references/effect/upstream/packages/effect/test/Stream.test.ts)
checks backpressure and early/in-flight async-iterator cancellation, including
resource finalizer traces. Dart uses native Stream adapters, so pause/resume
and cancel-await semantics also need platform-specific tests.
[SchemaParser.test.ts](../../references/effect/upstream/packages/effect/test/schema/SchemaParser.test.ts)
checks accumulated issues, bounded parallel parsing, input reads and round
trips. Those schema contracts remain unimplemented.

The [complete literal test catalogue](upstream-test-catalog.json) records package,
file, line, title and test mode. It includes TS and TSX files. The scan excludes
multiline/generated names and does not expand `it.each`, loops or arbitrary
samples; its declaration count is deliberately approximate. Run
`python3 tool/test_catalog.py` to regenerate it from the frozen source, offline.

## Dart test cases

These are runnable specifications. Waiter registration is observed before
interruption. Completers control the critical interleaving. `checkpoint` in
[test support](../../test/support/checkpoints.dart) allows at most 200 event
turns and then fails, exposing lost wakeups. No fixed wall-time sleep is used
as evidence that a concurrent action has completed. Seeded models use an
ordinary List/state transition as an independent oracle, rather than repeating
the implementation's waiter logic.

| IDs | Given / action | Required observable result |
| --- | --- | --- |
| R01–R03 | A Ref, a lazy update, throwing callback, and 30 seeded state traces | No eager mutation; successful result/state agree with pure model; defect preserves state |
| D01–D02 | Multiple completions, nullable success and each Cause channel | First completion wins; null is a value; expected/defect/interruption stay distinct |
| D03 | Two parked awaiters; interrupt one, then complete | Only interrupted waiter is withdrawn; survivor receives original value |
| D04–D05 | Completion effect fails or two completers race | One evaluation/claim; every waiter sees the same memoized Exit |
| P01 | Weighted FIFO waiters; interrupt the head | Later request never bypasses the head until withdrawal; permits conserved |
| P02–P04 | Success/failure/defect/interruption, grant/cancel race, invalid weight | All held permits restored; race does not leak; invalid input rejected |
| P05–P06 | Twenty effectful modifications and a failed modification | Serialized updates commit exactly once; failed update preserves state |
| Q01 | Capacities 0/1/2/5, 25 FIFO values | Rendezvous works; storage never exceeds capacity; every value arrives once |
| Q02–Q04 | Full queue, blocked offer/take, canceled head waiter | Backpressure; cancellation withdraws uncommitted work; next waiter progresses |
| Q05–Q07 | Shutdown, nullable item and yieldEvery=1 rendezvous | Both sides wake with QueueClosed; null differs from empty; no lost wakeup |
| H01–H02 | Two subscribers, one slow/full | Same ordered delivery; publication commits to all current subscribers atomically |
| H03–H07 | Cancel blocked publication, unsubscribe, scope exit/shutdown, late subscribe | No partial publication; remaining subscriber progresses; waiters close; no replay; failed scope registration leaks no subscription |
| S01–S03 | Reuse source, seeded map/filter/take, take(0) | Fresh evaluation; List-equivalent values; take(0) never acquires |
| S04 | Resource stream ends through five outcome paths | Exactly one release after success, expected error, defect, interrupt or early exit |
| S05–S07 | Body/release fail, factory throws, release waits behind a gate | Both causes retained once; release still runs; interrupt awaits protected cleanup |
| S08 | Buffer capacity 1/2/5 with consumer held behind a gate | Capacity queued + one in-flight read + held consumer item; early exit awaits producer |
| S09–S10 | Buffered failure after data; idle producer interrupted | Preceding values preserved; producer canceled and release awaited |
| S11–S12 | Lazy native input, early exit, source error | Factory runs on consumption; subscription canceled; optional mapper defines typed error |
| S13–S15 | Pause/resume and cancel native output; typed source failure | Demand pauses with at most one prefetched value; order resumes; cancel awaits cleanup; Cause surfaced |
| S16–S20 | Reused sink, sink error, invalid params, long filter | Fresh sink state; reads stop/release; invalid input rejected; event queue gets a turn; nullable sink result survives covariant consumer widening |

Full runnable cases:
[concurrency_test.dart](../../test/concurrency_test.dart),
[stream_test.dart](../../test/stream_test.dart),
[runtime_test.dart](../../test/runtime_test.dart),
[services_test.dart](../../test/services_test.dart),
[review_test.dart](../../test/review_test.dart).
Parameterized Dart cases expand into individual tests; seeded iterations occur
inside a test. Neither is reported as thousands of separate test cases.

## Running and assessing the evidence

```sh
dart analyze
dart test
dart test -p chrome
dart run tool/check_fixtures.dart
python3 tool/conformance/compare.py
python3 tool/conformance/compare.py --foundation
python3 tool/reference_snapshot.py verify
```

The first conformance suite compares 14 existing runtime observables; the second
compares six foundation records (Ref, Deferred, bounded Queue, bounded PubSub,
permit restoration and Stream/Sink). Both use actual pinned npm code restored
from the local archive, with no registry request. Normalization compares public
values/flags/traces, not Dart and TypeScript internal Cause encodings. Shutdown
semantics and intentional divergences are covered by Dart tests, not silently
normalized into an upstream parity claim. Type fixtures test Dart's weaker
covariant environment guarantee explicitly.

SQL drivers require real database integration suites; platform adapters require
their actual runtimes; RPC/workflow/cluster need transport, persistence and
recovery tests; AI providers need protocol fixtures plus separately authorized
live integration. Framework bindings need lifecycle/render tests. The core VM
and Chrome suite does not validate those unported packages.

The user subsequently narrowed scope to core and PostgreSQL/MySQL.
[SQL adapter cases and driver selection](sql-adapters.md) cover the active native
work. The full upstream test catalogue is historical reference, not a list of
Node packages required for the Dart implementation.
