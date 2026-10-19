# effect_test

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_test:
    path: /path/to/effect_dart/packages/effect_test

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
```

## Usage

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_test/effect_test.dart';
import 'package:test/test.dart';

Future<void> main() async {
  test('typed outcome', () async {
    final runtime = testRuntime(Unit.value);
    expect(await runtime.runExit(Effect.fail<int, String, Unit>('expected')), expectedFailure<String>(equals('expected')));
  });
}
```

## Contracts and limits

Development dependency only. Runtime teardown awaits shutdown. Condition/clock helpers wait for observable suspension, with finite event-turn limits. These helpers are not a universal leak detector.

## Validate

Run `dart analyze`, `dart test`, and `dart test example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
