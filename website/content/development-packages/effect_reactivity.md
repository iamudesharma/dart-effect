# effect_reactivity

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_reactivity:
    path: /path/to/effect_dart/packages/effect_reactivity

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
```

## Usage

```dart
import 'package:effect_reactivity/effect_reactivity.dart';

Future<void> main() async {
  final state = SubscriptionRef(0);
  state.set(42);
  print(await state.changes.first);
  state.close();
}
```

## Contracts and limits

SubscriptionRef uses conflated latest-value delivery: slow listeners do not receive every transition. Snapshot registration is atomic; each listener has one pending state. Cancel subscriptions and close the owner. Channel drains accepted values before a typed End/Failure; destructive shutdown remains distinct.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
