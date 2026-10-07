# 002: Explicit Dart lifecycle differences

Source authority: references/effect/upstream/packages/effect/src/{Effect,Scope,Cause,Layer}.ts
and internal/{effect,layer}.ts. See the reference index for tests and v4 docs.

- Sequential Cause trees replace v4 reason arrays and annotations. Normal typed
  recovery/retry only accepts a standalone Expected cause; it cannot hide cleanup
  failures or interruption. Both failed race branches are ordered by completion.
- Scope only supports sequential LIFO finalizers and rejects late registration.
  Upstream runs a late finalizer immediately with the recorded close Exit.
- forkScoped is bounded by parent AND scope; it cannot outlive its parent to a
  longer scope as upstream may allow. Detached forks are deferred.
- Resource brackets create a local scope and terminate scoped children before
  release. Unscoped fork children remain parent-owned; choose forkScoped for
  children using the bracket's resource. Cleanup-created unjoined children are
  interrupted and awaited before root termination.
- A successful race winner is retained even if loser cleanup fails. The loser is
  always awaited. Unjoined child failure is observed via its handle and does not
  automatically fail the parent. The parent is responsible for join where needed.
- Protected acquisition/release gets a non-cancelled token. Async adapter hooks
  are awaited; arbitrary custom Futures and CPU loops cannot be forcibly stopped.
- A failed Layer build invalidates the entire scope memo transaction. Pending
  protected acquisitions settle/register release before closure. This basic
  design does not promise independent failure isolation between graphs sharing a
  build scope; construct the complete graph before use and prefer Layer.use.
- Memo domains use node identity and the first environment supplied. There is no
  global memo cache. Missing Context services and dependency cycles are defects.
- Low-level Scope callbacks can return existential causes. Expected errors outside
  the root E family become defects, avoiding an untyped thrown Future exception.
