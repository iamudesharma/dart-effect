# effect_schema

Synchronous validation and bidirectional codecs for Dart and Flutter, with typed
Effect failures when needed. No timers, isolates, runtime dependencies beyond
`effect_core`, or code generation are required.

**Unpublished development package (`0.1.0-dev.1`).** This API is not part of the
hosted Effect packages. Use an explicit local integration while it is reviewed.

## Install for development

```yaml
dependencies:
  effect_schema:
    path: /path/to/effect_dart/packages/effect_schema
```

Requires Dart >=3.13.0. `effect_core` uses a version constraint; a local override
is only necessary when intentionally testing unreleased core changes.

## Validate API input

```dart
import 'package:effect_schema/effect_schema.dart';

final userSchema = Schema.object({
  'id': Field(Schema.integer),
  'name': Field(
    Schema.string.refine((value) => value.isNotEmpty, 'Name is required'),
    wireName: 'display_name',
  ),
  'active': Field(Schema.boolean, defaultValue: () => true),
  'note': Field(Schema.string.nullable(), optional: true),
});

void main() {
  final result = userSchema.decode({'id': 42, 'display_name': 'Ada'});
  switch (result) {
    case Valid(:final value):
      print(value); // {id: 42, name: Ada, active: true}
      print(userSchema.encode(value).orThrow); // Uses display_name again.
    case Invalid(:final error):
      for (final issue in error.issues) {
        print('${issue.location}: ${issue.message}');
      }
  }
}
```

`orThrow` throws `SchemaError` for invalid data. Use pattern matching at external
boundaries when invalid input is expected. Errors contain paths and messages,
not the invalid payload or callback exception text. Field names still appear in
paths; apply your application's log redaction policy.

## Semantics

- Missing required fields fail. `optional: true` allows absence, not explicit
  `null`; use `.nullable()` to accept null.
- Defaults are fresh **wire-format** values, validated on each use. They apply
  only to absent fields. A throwing factory produces a field-level issue.
- Unknown fields are rejected by default. `UnknownFields.strip` removes them;
  `preserve` keeps them. Preserved keys that collide with renamed output fields
  fail instead of silently overwriting data.
- Lists and object outputs are unmodifiable. This is not a deep freeze of
  arbitrary domain objects or preserved unknown values.
- `Schema.number` rejects NaN/infinities. Conversions and refinements that throw
  produce validation issues. A throwing `Schema.lazy` builder is a programming
  error and propagates; keep schema builders pure.
- Unions select the first successful branch. Later branches are still tried
  after the diagnostic limit fills. Encoding retains nested branch error paths.

## Codecs and JSON

```dart
final date = Schema.string.transform<DateTime>(
  DateTime.parse,
  (value) => value.toIso8601String(),
);
final timestamp = date.decode('2026-10-24T00:00:00.000Z').orThrow;
final text = date.encode(timestamp).orThrow;

final integersJson = Schema.integer.list().json();
final values = integersJson.decode('[1,2,3]').orThrow;
final encoded = integersJson.encode(values).orThrow;
```

Transforms must implement their intended round-trip rules. Defaults, stripping,
and normalization can change the original wire representation. `toJsonSchema()`
exports structural wire schemas; arbitrary predicates/transforms are not
expressible there. Custom `Schema.value<T>(type)` and literals require callers
to supply JSON-compatible types/values when exporting. Recursive JSON Schema
references and generated models remain future work.

## Bound validation work

```dart
final result = Schema.integer.list().decode(
  ['bad', 'also bad'],
  limits: const ValidationLimits(maxDepth: 64, maxIssues: 10),
);
```

Defaults are 64 nested codec calls and 100 reported issues. Depth includes
wrappers such as nullable, lazy and transforms, not just JSON nesting. Cyclic
inputs to recursive schemas fail at this boundary. Both limits must be positive.
`ValidationMode.first` reports one issue. In all mode, collection traversal stops
when its error budget fills; the returned list may therefore be incomplete.

These limits bound validation diagnostics and recursion, **not input bytes,
successful output size, branch count, or callback execution time**. Bound HTTP
body sizes before JSON parsing. `.json()` calls Dart's synchronous JSON parser
before schema validation; validation depth does not constrain parser allocation.
Do not raise depth arbitrarily: traversal uses the Dart call stack. Large valid
inputs still allocate output and can occupy the UI isolate; offload large jobs
at the application boundary after measuring your workload.

## Use with Effect

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  try {
    final effect = Schema.integer.decodeEffect<Unit>('invalid');
    final exit = await runtime.runExit(effect);
    print(exit); // Failure with an Expected<SchemaError> cause.
  } finally {
    await runtime.shutdown();
  }
}
```

Effect decoding is lazy and re-runs with fresh traversal state. Synchronous
validation cannot be interrupted mid-call; cancellation applies at runtime
checkpoints, not inside a user predicate.

## Verification

```sh
dart pub get
dart analyze
dart test
dart test --platform chrome
dart run example/main.dart
python3 tool/check_package.py
```

The candidate checker copies publishable files to a temporary directory, resolves
hosted dependencies without overrides, runs analysis/tests/examples and
`dart pub publish --dry-run`. This avoids the monorepo parent ignore rules; it
never publishes.

Repository-only profiling: `dart run tool/benchmark.dart` and
`dart --enable-vm-service=0 run tool/benchmark.dart --memory`. The harness imports
repository diagnostic tooling and is excluded from the published archive.
Benchmarks measure codec throughput; requested-GC weak-reference checks cover
schema/input/output/error retention. Neither establishes universal leak freedom,
Flutter device frame performance or service acceptance.

## Runnable Flutter example

The repository includes [`examples/schema_flutter`](../../examples/schema_flutter).
It demonstrates typed profile decoding, field errors, a name form and outgoing
JSON, with widget tests for request ordering and unmount behavior. It uses local
fixtures and the local schema package; no API key is needed. The example is kept
outside the published package to keep Flutter out of schema dependencies.
