# OpenAI performance and memory evidence

Measured 10 October 2026 on Apple M1, macOS arm64, Dart 3.13.0,
openai_dart 10.0.1 and the local effect_openai 0.0.1 runtime sources. This package
adds lifecycle/error-handling capabilities; it is not a faster HTTP client.
The previous core microbenchmarks do not prove OpenAI performance or memory safety.

## Research and measurement choice

Flutter's [performance guidance](https://docs.flutter.dev/perf/ui-performance)
uses profile mode on real hardware, rather than debug timings.
The [memory guide](https://docs.flutter.dev/tools/devtools/memory) distinguishes
reachable retained objects, Dart heap/external allocations, heap capacity and RSS.
A garbage collector cannot reclaim objects still held by an owner.
[Dart AOT compilation](https://dart.dev/tools/dart-compile) provides native
release-like timing; we use separately instrumented JIT heap diagnostics.
The official [VM service allocation API](https://api.flutter.dev/flutter/vm_service/VmService/getAllocationProfile.html)
allows a GC request before class counts, but does not guarantee GC. Our runner
requires changing service-GC timestamps before accepting the diagnostic.

A custom async harness measures actual HTTP and SSE work with Stopwatch,
validated outputs and awaited cleanup. It compares the established Dart SDK with
the adapter, not copied Node benchmarks or a fake protocol implementation.
Both use the same loopback fixture, SDK configuration, payload and disabled SDK
retries. No API key, live model or ChatGPT account is used. Remote service speed
and model quality are outside this measurement.

## Compiled native timing

Three fresh processes per workload/implementation, alternating the order;
three warmup batches and nine measured batches per process. Setup, pool/client
construction, shutdown and heap-GC instrumentation are outside timing. Individual
abort/cancel cleanup is inside its operation time. Output/event/status checks and
request-count checks are in both measured paths. The direct SDK cancellation
baseline also signals abort and awaits stream/request cancellation.

Values below are pooled batch medians divided by operations per batch; they are
**amortized time**, not independently measured per-request latency or token cadence.
Small differences may be run noise; raw process medians and batch p95s are retained.

| Workload | Direct SDK µs/op | Effect µs/op | Extra µs/op | Median difference |
| --- | ---: | ---: | ---: | ---: |
| Small JSON request | 150.49 | 165.12 | +14.63 | +9.7% |
| Request with 10 ms fixture delay | 12713.70 | 12775.45 | +61.75 | +0.5% |
| Bounded requests, concurrency 8 | 118.57 | 126.02 | +7.45 | +6.3% |
| Consume SSE deltas without collecting | 10.32 | 18.03 | +7.72 | +74.8% |
| 401 / 429 / 500 classification | 160.80 | 173.91 | +13.11 | +8.2% |
| Abort before response headers | 260.37 | 263.90 | +3.53 | +1.4% |
| Read one event, abort and cancel | 310.90 | 332.20 | +21.30 | +6.9% |

Batches contain 100 JSON/failure requests, 20 delayed requests, 200 bounded
requests, five streams of 256 events (1,280 SSE deltas), or 30 abort/early-exit
operations. The streaming rows use sequential consumers and discard events;
Sink.collect is intentionally excluded because collecting retains all values.
Fixture requests were not replayed, at most eight bounded requests were in flight,
and no detached fixture socket remained after a batch.

The CPU-heavy stream adapter path has the largest overhead: about 75% above the
SDK in this run, around 7.7 extra microseconds per delta. That is real overhead
from interpreting per-event effects and scoped cleanup; do not call it a speedup.
The 10 ms delayed request case differed by approximately 0.5%, while fast JSON
requests differed by approximately 10%. Real network/model latency may dominate,
but these local results do not establish live API latency.

## Retention and memory checks

Three fresh JIT/VM-service runs for each implementation. After warmup, six batches
repeat real requests, streaming, failures, aborts and early exits, with seven
post-GC checkpoints per run. Each run executes 1,855 HTTP requests. The Effect
runs additionally churn 180 owned lifecycles and 256 KiB closure payloads;
this additional owner test means total heap/RSS comparisons are not equal-work
allocation measurements.

- Zero retained `_Operation`, Fiber, FiberContext and Scope instances at all
  Effect checkpoints. One reusable adapter and SDK client intentionally stay alive.
- Each Effect run collected all 540 weakly tracked adapter/runtime/payload
  targets: **1,620 across three repetitions**. A deliberately strongly held
  positive-control object remained reachable.
- External memory delta was zero in both implementations across every repetition.
- Main-isolate post-warmup heap grew by about 1.00 MiB for Effect and 0.85 MiB for
  the direct SDK. JIT/service/helper/cache activity is included; this is not zero
  total-memory growth or proof of universal leak freedom. Heap capacity and RSS
  are recorded separately and must not be called retained allocations per request.

The deterministic owner/operation checks are suitable correctness gates.
The timing distributions are an initial descriptive baseline, not arbitrary
hardware-independent pass/fail limits. A future regression must compare the same
hardware, SDK, fixture and compilation mode, inspect process-level variation,
and recheck correctness before changing runtime behavior.

## Native Flutter profile evidence

Flutter 3.47.0 / Dart 3.13 on the real macOS desktop, **profile mode**, three
fresh direct-SDK and three fresh Effect runs in alternating order. No simulator
or emulator was used. Each run warms the HTTP/SSE/error paths, then runs the
same animated UI and mixed workloads for a six-second window. Faster paths can
complete more batches, so operation counts are retained alongside frame data.
The runner disables DDS to keep its direct VM-service attachment stable.

| Implementation | Recorded frames (3 runs) | Median of build p95s (ms) | Median of raster p95s (ms) | Stages above 16.67 ms: build / raster |
| --- | ---: | ---: | ---: | ---: |
| Direct SDK | 1142 | 0.419 | 0.599 | 0 / 0 |
| Effect adapter | 1150 | 0.388 | 0.591 | 0 / 0 |

These are build and raster stage measurements, not end-to-end input latency or
a promise of frame pacing in another app. GC requests happen before/after frame
recording. Before/after native heap checks also showed zero retained operations,
fibers, contexts and scopes while the intended application client stayed alive.
The harness awaits runtime/adapter shutdown before closing its owned fixture and
exiting. Mobile platforms, real Flutter widget disposal journeys, frame-by-frame
stream UI updates, slow-consumer buffering, production payloads and Flutter web
memory still need their own acceptance. The raw native profile record is
[openai-flutter-performance.json](openai-flutter-performance.json).

## Error handling and portability

All **50 VM and 42 Chrome adapter tests passed** on this source. Those cover typed
SDK failures, programmer defects, interruption, explicit retry, sibling isolation,
redacted summaries, and awaited owned cleanup. The benchmark also repeatedly
asserts HTTP failure kind, no unexpected request replay, interruption outcomes,
stream counts and real socket closure. These checks show documented behavior;
they do not prove that arbitrary user callbacks cooperate with cancellation or
that every possible SDK endpoint/live server failure has been accepted.

## Reproduce

From the repository root, with dependencies already installed:

```sh
python3 tool/openai_performance.py
# Native macOS profile app (Flutter/Xcode and cached SDK dependencies required):
python3 tool/openai_flutter_performance.py
```

The first runner compiles the native benchmark, executes 42 fresh AOT timing
processes plus six heap-diagnostic processes, and writes
[openai-performance.json](openai-performance.json). Partial/failed runs carry
`success: false`; missing GC, uncollected tracked owners, unexpected requests,
open fixture sockets and invalid outcomes fail the run. No VM service token is
stored in evidence. The native runner generates a development-only macOS shell
under ignored build/, copies the shared workload and tracked Flutter UI template,
and writes [openai-flutter-performance.json](openai-flutter-performance.json).
Its temporary shell disables app sandboxing to write local evidence and serves
only loopback fixtures; it is not an application deployment configuration.

Benchmark sources are development-only and excluded from published package
archives. No runtime or dependency versions changed and no package was republished.
Native mobile, Flutter web/browser heap, production workloads and live OpenAI
memory/latency remain separate acceptance gates. Re-run profile measurements on
your actual application and target device, including async owner shutdown and
slow consumers; never capture BuildContext in a callback that outlives its widget.
