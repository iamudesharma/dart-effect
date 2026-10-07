# Historical expansion and current foundation contracts

The earlier entire-ecosystem request has been superseded. Current scope is the
reusable Effect core and PostgreSQL/MySQL adapters using established Dart drivers.
Read sql-adapters.md for the active scope and SQL contracts. The full upstream
inventory is historical reference; no empty Dart package counts as a port.

Implementation order follows dependencies: state/concurrency, stream/sink,
schema/data/config/cache/observability, platform/network/process/storage,
SQL/RPC/workflow/cluster/eventlog, AI/CLI/reactivity and framework/tooling adapters.
That former full port roadmap is outside the current selected scope. Dart equivalents for JS-runtime-specific packages require
explicit compatibility decisions. External driver/vendor integrations require
real integration tests in addition to mocked protocol tests.

## Foundation interfaces

Ref mutation is atomic within a single isolate; async mutation uses a semaphore.
Deferred stores exactly one Exit; cancelling a waiter does not complete Deferred.
Completing from an Effect memoizes one evaluation; lazy completeWith is not yet
advertised. Semaphore uses strict FIFO weighted permits, removes cancelled
waiters and restores permits on all body exits. Invalid requests above capacity
fail immediately (upstream may suspend; intentional Dart difference).

BoundedQueue supports zero-capacity rendezvous and FIFO producer/consumer waits.
Offer/take register synchronously before suspension; cancellation withdraws only
uncommitted operations. Shutdown discards buffered data, wakes all blocked parties
with QueueClosed and rejects later operations. Graceful end/drain is separate and
not equivalent to shutdown. Sliding/dropping modes must be identified separately.
PubSub must publish atomically to currently subscribed queues: a slow subscriber
backpressures bounded publishing, cancelling before acceptance delivers to none;
unsubscription/shutdown wakes blocked publishers. New subscribers receive future
messages, not replay. Scope owns subscriptions.

EffectStream is pull based, scoped and lazy per consumption. Each pull yields one
value/end/typed Cause; no unbounded buffering. Early consumer exit closes upstream
and awaits resource cleanup. Buffered adaptation has an explicit positive bound,
producer interruption and awaited shutdown. Native Stream adapters must not assert
that pause support forcibly stops an external source ignoring pause/cancel.

Tests derive from pinned test behavior, with original Dart scenarios, controlled
completers and manual clocks. Each scenario records Given/When/Then, upstream
source/test names, Dart operation, invariants and intentional differences.
