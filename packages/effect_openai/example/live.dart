// Opt-in live example. Requires OPENAI_API_KEY and OPENAI_MODEL.
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';

Future<void> main() async {
  final model = Platform.environment['OPENAI_MODEL'];
  if (model == null || model.isEmpty) {
    throw StateError('Set OPENAI_MODEL to a model enabled for your account.');
  }
  final client = EffectOpenAIClient.create(
    OpenAIConfig.fromEnvironment().copyWith(
      retryPolicy: const RetryPolicy(maxRetries: 0),
    ),
  );
  final runtime = Runtime(Unit.value);
  try {
    final result = await runtime.runExit(
      client.createResponse<Unit>(
        CreateResponseRequest(
          model: model,
          input: ResponseInput.text('Say hello.'),
          maxOutputTokens: 32,
          store: false,
        ),
      ),
    );
    switch (result) {
      case Success(:final value):
        print(value.outputText);
      case Failure(:final cause):
        if (cause case Expected<OpenAIFailure>(:final error)) {
          stderr.writeln(error); // Redacted adapter summary.
        } else {
          stderr.writeln('Request ended with ${cause.runtimeType}.');
        }
        exitCode = 1;
    }
  } finally {
    await runtime.shutdown();
    await client.shutdown();
  }
}
