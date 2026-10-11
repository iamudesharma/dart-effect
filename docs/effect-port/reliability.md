# Reliability additions — development branch

These APIs are implemented in the checkout and not included in the currently
published effect_core 0.0.1 release. No publication or website deployment is part
of this change. Earlier performance reports measure their recorded revision;
they do not measure tracing or these new helpers.

## Timeout diagnostics

When the timer wins, timeout interrupts and awaits its worker. The result retains
the caller's timeout error followed by all non-interruption worker diagnostics in
an ordered Sequential Cause. Parent cancellation remains interruption, with
cleanup diagnostics appended. A throwing timeout factory becomes a Defect and
still retains failed cleanup. Composite outcomes cannot be recovered/retried as
ordinary expected failures. Worker success before the timer is unchanged.
Cleanup is masked and exactly once, and can extend the deadline indefinitely.

## Typed retries and schedules

`effect.retry(schedule, whileError: (E error) => bool,
retryAfter: (E error, DateTime now) => Duration?)` evaluates callbacks only for a
single Expected cause. Defects, cancellation and composite cleanup failures are
not retried. Callback exceptions are defects. Recurrences count additional runs.

`Schedule.maxDelay` caps exponential jittered local delay. Each execution receives
an independent Random source by default; explicit `seed` repeats a sequence for
testing. `elapsedBudget` includes operation and sleep time using the injected
Clock. It stops admission of a retry at or beyond the budget, including after
scheduler oversleep. It does not interrupt an ongoing attempt. Use timeout for
that. RealClock is wall time, so wall-clock adjustment can affect this budget;
applications requiring monotonic policy can supply a clock with that behavior.

A Retry-After callback overrides local delay and cap. The budget may reject that
retry rather than ignore the server delay. The HTTP package parses delta-seconds
and IMF-fixdate; past dates become zero and invalid input falls back to backoff.
Negative callback delays become zero. No implicit status-based retry exists.

## Lifecycle tracing and metrics

`Runtime(lifecycle: sink, metrics: RuntimeMetrics())` emits start, cleanup and end
for every root and child, including failed cleanup. IDs are runtime-local; parent
IDs link child spans. End is after owned children and finalizers have completed.
`effect.traced('name')` adds named region start/end; enclosing scope finalizers
belong to that scope rather than the region. Events omit error values and the
environment. Users choose safe names and export/redaction policy.

Metrics count starts, active and completed fibers, terminal failures and pure
interruptions, plus total fiber duration (overlapping child time is counted).
This is bounded aggregate state, not an exporter, latency histogram or OpenTelemetry
implementation. Tracing allocates events only when enabled; counters are isolate
local. Observer exceptions cannot change effect outcomes. A blocking observer
still blocks the isolate, so keep sinks short and bound any external queue.

## Circuit breaker

`CircuitBreaker.protect(effect, onOpen: () => E,
countsAsFailure: (E) => bool)` counts consecutive selected Expected errors.
Success resets the consecutive counter. Defects, interruption and composites
do not count, and do not close an open breaker. On reaching failureThreshold it
rejects subsequent admission until resetAfter. Exactly one half-open probe runs;
its selected failure reopens, success closes, and cancellation or defect releases
the probe while leaving the breaker open. Results from older closed-state
admissions cannot close a newly opened circuit. This is per-instance, same-isolate
state, without detached timers, persistence or cross-isolate coordination.

Policy order is explicit: a breaker around a retry sees only its final result;
a retry around a breaker counts each admitted attempt. No helper automatically
replays an operation.

## Rate limiting

`RateLimiter(interval).limit(effect)` reserves FIFO time slots before execution.
It spaces admissions, not completions, and does not bound concurrency. Cancelled
reservations leave gaps to avoid bursts; waiting sleeps observe cancellation and
are removed. Reservations are two scalar values, not a retained queue. This is
an optional admission-spacing helper, not a distributed/token-bucket limiter.
Compose bounded traversal or Semaphore when concurrency also needs a bound.

## Optional HTTP/SSE

See [effect_http README](../../packages/effect_http/README.md) for ownership,
installation and examples. `http` is an optional package dependency; core stays
portable with no runtime dependency and no dart:io import. No reconnect,
automatic write retry, credential storage or live account access is implemented.

## Verification boundaries

Core lifecycle regression scenarios cover timeout plus cleanup, parent
interruption, throwing timeout factory, retry predicates, cap/seed/budget,
retry cancellation, metrics and parent-linked traces, single half-open probe,
probe interruption, failure filtering and cancellation-safe admission spacing.
HTTP uses real local IOClient fixtures and portable mock fixtures; no external
API key is needed. Production network failover, live BrowserClient abortion,
mobile lifecycle and performance of enabled tracing remain separate acceptance.

Latest verification on 11 October 2026: **230 VM tests**, **184 Chrome tests**,
five analyzer fixtures, seven core examples and two database examples passed.
All six package analyzers passed. Both owned SQL containers were removed.
The first legacy SQL-runner attempt lacked Docker; its next attempt used a leaf
certificate for the MySQL example and failed. The CA-based runner then passed
both native suites and examples, without skipped tests in its selected suites.
Negative TLS-chain acceptance remains a separate dated check. Machine-readable
results and source hashes are in [reliability-validation.json](reliability-validation.json).
