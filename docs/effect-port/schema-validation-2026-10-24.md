# effect_schema validation — 2026-10-24

## Scope and status

The existing unpublished draft is hardened for independent review. No package
was published, no website was deployed, and other toolkit packages were not
implemented in this pass. Existing unrelated SQL integration edits were preserved.
Package manifest remains `0.1.0-dev.1`; a release version is a separate decision.

## Changes and contracts

- Synchronous per-call traversal context; no timers, futures or global state in
  pure decode/encode. Effect decoding remains lazy and repeats validation.
- Default limits: 64 nested codec calls and 100 issues; first mode reports one.
  Cyclic input/recursive schema paths stop with validation errors. List/object
  traversal stops at its diagnostic cap. Unions must still search later branches
  for a successful result. Limits do not bound valid output, callback duration,
  union branch count or Dart JSON parser allocations.
- Preserve/rename collisions fail rather than overwrite data, in both directions.
- Throwing default factories become field issues. Union encoding retains nested
  paths. Special keys use bracket-quoted diagnostic paths.
- Object domain-name membership is computed once per schema instead of allocating
  a fresh set on every encode.
- Expanded README, executable examples, isolated candidate verifier, and a
  repository-only performance/retention harness excluded from the archive.

## Executed acceptance

| Check | Result |
| --- | --- |
| Schema analyzer | No issues |
| Schema Dart VM tests | 22 passed |
| Schema Chrome behavioral tests | 22 passed |
| Core regression tests | 131 passed |
| Root analyzer and analyzer fixture harness | Passed; 5 fixtures |
| Dependent effect_ai tests | 3 passed |
| Dependent effect_http_server loopback test | 1 passed |
| Dependent effect_sql_schema tests | 3 passed, including SQLite |
| Executable example, JavaScript compilation | Passed |
| Isolated schema analyzer/tests/example with hosted effect_core 0.0.3 | Passed |
| Isolated pub.dev publish dry run | Zero warnings; nothing published |
| Shared integration skill validation/index refresh | Passed |

Boundary tests independently cover absent/null/default/optional fields, rename
collisions, nested paths, first-error short circuit, bounded overload diagnostics,
cyclic data, depth reset between siblings and calls, successful union fallback
after budget exhaustion, default exceptions, immutable outputs, non-finite numbers,
malformed JSON, transformation failures and lazy Effect re-execution.

Run the isolated candidate verifier from the package directory:
`python3 tool/check_package.py`. It avoids parent monorepo `.pubignore` rules and
local dependency overrides by copying only candidate files into a temporary
folder. Direct in-tree dry run was rejected because the parent rules exclude
nested packages; this is not the validated publication procedure.

## Performance comparison

Baseline: `e4ef4b99014b28aab3efd71ac9482f802dbab599`. New library SHA-256: `25ce3cbfe4096af5ae698ff4b1cb07c54e833d4672aa05547d138274466f8fc9`.
Both use the same Dart SDK/core resolution and harness. AOT medians below combine
three fresh processes per variant with alternating order, nine samples of
100,000 operations per case after 20,000 warmup operations. Inputs are small
three-field API objects (ID, name, tags). Raw sample arrays, initial JIT runs and
first-operation measurements are in [the JSON evidence](schema-validation-2026-10-24.json).
First-operation measurements are not whole-process startup measurements.

| Operation | Original µs/op | Hardened µs/op | Change |
| --- | ---: | ---: | ---: |
| decode-valid | 0.566 | 0.589 | +4.1% |
| decode-invalid | 1.650 | 1.879 | +13.9% |
| encode-valid | 0.641 | 0.573 | -10.6% |

Validation bounds add work. Invalid decoding was about 0.23 µs/op slower in this
workload; valid encoding improved after avoiding a per-call field-name set.
These are synthetic host measurements, not a general application speedup or
Flutter frame guarantee. Large valid data and expensive callbacks remain
application-level scheduling responsibilities. Benchmarks intentionally do not
compare bounded errors with unbounded errors as if they returned identical output.

## Retention evidence

The extended allocation check ran 200 cycles × 2,000 iterations, each creating a
schema, 4 KiB payload, input, valid output and invalid result. All **100,000 sampled
weak references were collected** after requested and observed GC; a strong
positive control stayed alive. External memory delta was zero. Post-GC heap
rose 554,208 bytes; final RSS decreased 2,572,288 bytes. In the latter half,
heap rose 233,920 bytes and RSS decreased 12,075,008 bytes.

The harness retains its 200 checkpoint reports and the VM/JIT/profiler allocate
memory, so those process measurements are not per-schema retained-byte totals.
The small heap increase is not fully attributed by retaining-path analysis.
This is an allocation stress/reachability check, not a multi-hour soak or proof
that arbitrary caller closures and preserved values cannot retain memory.

Reproduce from the package directory:

```sh
dart run tool/benchmark.dart
dart compile exe tool/benchmark.dart -o /tmp/schema-benchmark
/tmp/schema-benchmark
dart --enable-vm-service=0 run tool/benchmark.dart --memory --soak
```

For the old variant, extract the baseline library with `git show`, point a copy
of the same harness at it, and use the same package configuration. No reference
snapshot or Node source is required.

## Explicit remaining boundaries

Generated Dart models, recursive JSON Schema references and service-aware custom
validators are future features. Structural JSON Schema does not encode arbitrary
refinements or transformations. No physical-device/frame acceptance or universal
leak-freedom claim is made. Publication and hosted installation of this schema
package have not occurred; current acceptance uses a local candidate with hosted
core dependencies.
