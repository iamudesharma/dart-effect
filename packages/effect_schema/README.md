# effect_schema

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_schema:
    path: /path/to/effect_dart/packages/effect_schema

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
```

## Usage

```dart
import 'package:effect_schema/effect_schema.dart';

Future<void> main() async {
  final schema = Schema.object({'id': Field(Schema.integer)});
  print(schema.decode({'id': 42}).orThrow);
}
```

## Contracts and limits

Pure decode/encode, nested paths, first/all errors, primitives, literals, unions, lists, optional/default/renamed object fields, refinements, recursive runtime schemas and structural JSON Schema. Arbitrary predicates are not expressible in generated JSON Schema. Recursive JSON Schema references and generated models remain separate work.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
