# Blot Effect architecture

Design established before implementation. This repository was empty; the name
`blot_effect` is provisional. Portable Dart 3.13 core, no runtime dependencies.

## Type contract

`Effect<A,E,R>` carries a value, expected error family, and actual environment R.
`Runtime<R>` supplies R and `Effect.environment` accesses it with a typed selector.
Composition retains E and R. Differing errors require an explicit sealed common
family or mapError; differing services use an explicit aggregate environment.
No inferred TypeScript unions or generator DSL. Dart generic parameters are covariant: widening an Effect requiring a subtype into Effect<A,E,Object> allows a broad Runtime<Object> to accept it. R is therefore requirement documentation with typed selectors and a checked runtime boundary, not complete compile-time provision evidence. Ordinary unrelated concrete types are rejected, while widened misuse becomes a defect. `provide(R)` removes R by
returning an effect with `Unit` environment. Context is an alternative immutable
heterogeneous registry: keys are identity based and generic; missing keys are
runtime defects, not statically proven requirements. `R=Context` does not prove
that a specific key exists. No unchecked public dynamic API.

## Runtime contract

Use an instruction tree with an iterative interpreter and explicit continuation
stack. Map/flatMap/recovery must not recursively execute the left spine. Yield
to the event queue after a bounded number of instructions (default 1024).
Constructors, Future factories and composition are lazy and re-evaluated per run.
Failures, defects with stack traces, and interruption have distinct Cause variants.
Recovery/retry matches only a single typed expected failure. Composite cleanup
causes are not silently recovered. Cleanup failures append sequentially to the
original failure, retaining all causes. A successful body plus failed cleanup
becomes failed Exit.

| Operation | Lifetime/ordering contract |
| --- | --- |
| runtime.runExit | Creates root fiber, scope and child registry; returns only after cleanup |
| fork | Child belongs to current fiber; child interruption and await at parent completion |
| forkScoped | Child additionally belongs to enclosing scope; terminated when scope closes |
| join | Awaits child Exit; propagates failure into joining effect |
| interrupt | Idempotent cancellation signal; interrupt-and-await waits for protected cleanup |
| race | First successful result wins; if first fails await other; always terminate/await loser |
| timeout | Interrupt and await worker; typed timeout is explicit via caller-supplied E |
| scope | LIFO finalizers; exactly once; children interrupted and awaited before finalizers |
| acquire/use/release | Local scope; acquisition protected until release registered; use interruptible; scoped children awaited before protected release |
| shutdown | Reject new roots, interrupt all roots, await cleanup |
| traversal | Positive bound; stable result order; fail-fast, interrupt and await siblings |

Cancellation is cooperative: token checkpoints, asynchronous wait races, and
optional adapter cancellation hooks that are awaited on interruption. Late Future completion cannot resume the
fiber after interruption. Ordinary Future I/O can continue in the background;
only explicit hooks can stop underlying operations. Protected finalization may
wait indefinitely if user cleanup never completes. Same-isolate fibers provide
asynchronous concurrency, not CPU parallelism. Isolate adapters are deferred.

## Services and policy interface

Modules use `Effect.asyncExit((FiberContext<R> context) async => Exit<A,E>)`;
`FiberContext` exposes environment, token, clock, scope, runtime, and logger,
plus `evaluate(effect)` for nested effects and `masked()` for cleanup.
Runtime exposes `runExit`, `runFuture`, `fork`, `shutdown`. Effect has succeed,
fail, sync, defer, fromFuture, asyncExit, environment, map, flatMap, mapError,
catchAll, provide, ensuring, scoped, acquireUseRelease, fork, forkScoped, sleep,
timeout, race and traverse. `Exit` variants: Success.value / Failure.cause.
`Cause` variants: Expected.error / Defect.error+stackTrace / Interrupted /
Sequential.first+second. `Unit` is the empty environment singleton.

Clock interface: `Future<void> sleep(Duration, CancellationToken)` and
`DateTime get now`. RealClock and manually advanced TestClock; cancellation
removes pending sleepers. Logs are immutable timestamp/level/message/fields
records delivered to an injected sink. Layer graphs memoize by layer identity
within a build scope; detect cycles per traversal path; share in-flight builds;
close scope after partial failure. No global caches.

See decisions and feature-matrix for exact implemented surface and divergences.

Layer construction is a scope-wide transaction: a failed build invalidates that memo domain and closes acquired services, after waiting for protected in-flight acquisitions. Do not retain previously built Context values across a failed construction in the same scope. A complete graph with Layer.use is the preferred ownership boundary. Parallel roots use a wait-dependency graph to detect cycles. Memoization uses the first environment supplied to a node in that scope.

The stack-safety proof covers map/flatMap/defer instruction chains. Repeated nesting of region wrappers (provide, scoped, ensuring, mapError, custom asyncExit) is not a general stack-safety claim; wrapper depth is an unbenchmarked limitation. Custom asyncExit is a runtime extension boundary: arbitrary user waits must use context.evaluate(fromFuture(...)) or observe the cancellation token; the interpreter cannot forcibly stop such code.
