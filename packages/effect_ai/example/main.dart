import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';
import 'package:effect_ai/effect_ai.dart';

Future<void> main() async {
  final runtime = Runtime(Unit.value);
  final model = FunctionLanguageModel<Unit>(
    (messages) => Effect.succeed(AiResponse(text: '42')),
  );
  try {
    print(await runtime.runFuture(model.structured([], Schema.integer)));
  } finally {
    await runtime.shutdown();
  }
}
