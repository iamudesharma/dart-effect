# effect_config

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_config:
    path: /path/to/effect_dart/packages/effect_config

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
```

## Usage

```dart
import 'package:effect_config/effect_config.dart';

Future<void> main() async {
  final provider = ConfigProvider({'PORT': '8080'});
  print(Config.port('PORT').load(provider));
}
```

## Contracts and limits

Missing defaults never hide malformed supplied values. Map providers are immutable snapshots. Fallback applies only to absent paths. Redacted formatting hides secrets; reveal is explicit. This is not encryption or secure memory. Native providers are in effect_platform.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
