// Credential-free example: the real SDK runs against a synthetic HTTP transport.
import 'dart:convert';

import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> main() async {
  final transport = MockClient(
    (_) async => http.Response(
      jsonEncode({
        'id': 'resp_example',
        'object': 'response',
        'created_at': 1,
        'status': 'completed',
        'output': [
          {
            'type': 'message',
            'id': 'msg_example',
            'role': 'assistant',
            'status': 'completed',
            'content': [
              {
                'type': 'output_text',
                'text': 'Hello from Effect OpenAI',
                'annotations': [],
              },
            ],
          },
        ],
      }),
      200,
    ),
  );
  final key = ServiceKey<EffectOpenAIClient>('openai');
  final layer = EffectOpenAIClient.layer(
    key,
    () => OpenAIClient(
      config: const OpenAIConfig(
        authProvider: ApiKeyProvider('synthetic-example-key'),
        retryPolicy: RetryPolicy(maxRetries: 0),
      ),
      httpClient: transport,
    ),
  );
  final runtime = Runtime(Context());
  try {
    final program =
        Effect.environment<EffectOpenAIClient, OpenAIFailure, Context>(
          (ctx) => ctx.get(key),
        ).flatMap(
          (client) => client.createResponse<Context>(
            CreateResponseRequest(
              model: 'fixture-model',
              input: ResponseInput.text('Say hello'),
            ),
          ),
        );
    final response = await runtime.runFuture(layer.use(program));
    print(response.outputText);
  } finally {
    await runtime.shutdown();
    // SDKs borrow injected HTTP transports, so the owner closes this transport.
    transport.close();
  }
}
