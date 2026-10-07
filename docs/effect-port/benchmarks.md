# Measured baseline

Dart 3.13.0 stable, macOS arm64; local VM JIT and compiled AOT. Three warmups,
eleven measured samples per workload; chain construction and execution included.
Synthetic bounded I/O uses 2,000 zero-duration event-queue waits, bound 8.
Cancellation baseline uses Future.any plus a token; effects additionally own
fiber/scope lifetimes. Different lifecycle guarantees mean this is descriptive,
not a claim of identical work or a speedup.

| Workload | Future JIT median (µs) | Effect JIT median (µs) | Future AOT median (µs) | Effect AOT median (µs) |
| --- | ---: | ---: | ---: | ---: |
| 10,000 compositions | 853 | 5659 | 1056 | 2461 |
| 100,000 compositions | 14703 | 60230 | 14591 | 58768 |
| Bounded I/O | 8849 | 37885 | 8373 | 25100 |
| 100 interruptions | 347 | 3291 | 76 | 859 |

Raw samples, mean, min and p90 are retained in benchmark-jit.json and
benchmark-aot.json. Process-wide current/maximum RSS is reported there; it is
not per-operation allocation attribution. No agreed regression budget exists.
The effects are slower in these workloads; lifecycle control has an overhead.
Stream benchmarks remain deferred because streams are not implemented.

Reproduce:

```sh
dart run tool/benchmark.dart > docs/effect-port/benchmark-jit.json
dart compile exe -Dbenchmark.aot=true tool/benchmark.dart -o build/benchmark
build/benchmark > docs/effect-port/benchmark-aot.json
```

This repository began without Git metadata. The benchmark source and runtime
fingerprints are retained in validation.json for revision identification.
