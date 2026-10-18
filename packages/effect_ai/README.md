# effect_ai

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_ai:
    path: /path/to/effect_dart/packages/effect_ai

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
  effect_schema:
    path: /path/to/effect_dart/packages/effect_schema
```

## Usage

```dart
import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';
import 'package:effect_ai/effect_ai.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final model = FunctionLanguageModel<Unit>((messages) => Effect.succeed(AiResponse(text: '42')));
  try { print(await runtime.runFuture(model.structured([], Schema.integer))); } finally { await runtime.shutdown(); }
}
```

## Contracts and limits

Provider-neutral LanguageModel/EmbeddingModel interfaces, a function adapter, structured JSON validation, typed tools and a bounded explicit ToolAgent loop. Only registered application handlers run. Refusal/incomplete generation differ from transport success. Calls are single-attempt; tool execution is not transactional. No external model/API acceptance or vendor-neutral provider compatibility is implied by fixture tests.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
