import 'dart:convert';

import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'client_test.dart' show expected, sdkClient;
import 'support/fixtures.dart';

void main() {
  late Runtime<Unit> runtime;
  late http.Client transport;
  late EffectOpenAIClient ai;
  final received = <http.Request>[];
  setUp(() {
    received.clear();
    runtime = Runtime(Unit.value);
  });
  tearDown(() async {
    await runtime.shutdown();
    await ai.shutdown();
    transport.close();
  });
  void setup(
    Object response, {
    int status = 200,
    Map<String, String>? headers,
  }) {
    transport = MockClient((request) async {
      received.add(request);
      return http.Response(
        jsonEncode(response),
        status,
        headers: headers ?? {},
      );
    });
    ai = EffectOpenAIClient(sdkClient(transport: transport), closeClient: true);
  }

  test(
    '[WIRE01] real SDK response request, auth, Unicode and typed output',
    () async {
      setup(responseJson());
      final effect = ai.createResponse<Unit>(
        CreateResponseRequest(
          model: 'fixture-model',
          input: ResponseInput.text('नमस्ते 🌏'),
          maxOutputTokens: 12,
        ),
      );
      expect(received, isEmpty);
      expect((await runtime.runFuture(effect)).outputText, 'Hello Effect');
      expect((await runtime.runFuture(effect)).id, 'resp_fixture');
      expect(received, hasLength(2));
      expect(received.first.url.path, '/v1/responses');
      expect(received.first.headers['authorization'], 'Bearer fixture-key');
      final body = jsonDecode(received.first.body) as Map;
      expect(body['input'], 'नमस्ते 🌏');
      expect(body['max_output_tokens'], 12);
    },
  );

  test('[WIRE02] real SDK chat completions retain messages and text', () async {
    setup(chatJson());
    final result = await runtime.runFuture(
      ai.createChatCompletion<Unit>(
        ChatCompletionCreateRequest(
          model: 'fixture-model',
          messages: [ChatMessage.user('Hi')],
        ),
      ),
    );
    expect(result.text, 'Hello chat');
    expect(received.single.url.path, '/v1/chat/completions');
    expect((jsonDecode(received.single.body) as Map)['messages'], [
      {'role': 'user', 'content': 'Hi'},
    ]);
  });

  test('[WIRE03] real SDK embeddings retain vectors and usage', () async {
    setup(embeddingJson());
    final result = await runtime.runFuture(
      ai.createEmbedding<Unit>(
        EmbeddingRequest(
          model: 'fixture-embedding',
          input: EmbeddingInput.text('Hello'),
        ),
      ),
    );
    expect(result.firstEmbedding, [0.25, -0.5]);
    expect(result.usage?.totalTokens, 2);
    expect(received.single.url.path, '/v1/embeddings');
  });

  test('[WIRE04] real SDK moderation retains flagged outcome', () async {
    setup({
      'id': 'mod_fixture',
      'model': 'fixture-moderation',
      'results': [
        {
          'flagged': true,
          'categories': {for (final key in moderationKeys) key: false},
          'category_scores': {for (final key in moderationKeys) key: 0.0},
        },
      ],
    });
    final result = await runtime.runFuture(
      ai.createModeration<Unit>(
        ModerationRequest(input: ModerationInput.text('Example')),
      ),
    );
    expect(result.anyFlagged, isTrue);
    expect(received.single.url.path, '/v1/moderations');
  });

  test(
    '[WIRE05] response retrieval and explicit background cancellation',
    () async {
      setup(responseJson(status: 'cancelled'));
      await runtime.runFuture(ai.retrieveResponse<Unit>('resp_fixture'));
      await runtime.runFuture(ai.cancelResponse<Unit>('resp_fixture'));
      expect(received.map((r) => (r.method, r.url.path)), [
        ('GET', '/v1/responses/resp_fixture'),
        ('POST', '/v1/responses/resp_fixture/cancel'),
      ]);
    },
  );

  test(
    '[WIRE06] generic wrapper provides other SDK endpoints with typed results',
    () async {
      setup({
        'object': 'list',
        'data': [
          {
            'id': 'fixture-model',
            'object': 'model',
            'created': 1,
            'owned_by': 'fixture',
          },
        ],
      });
      final result = await runtime.runFuture(
        ai.request<ModelList, Unit>(
          (client, abort) => client.models.list(abortTrigger: abort),
          operation: 'models.list',
        ),
      );
      expect(result.data.single.id, 'fixture-model');
      expect(received.single.url.path, '/v1/models');
    },
  );

  for (final (status, kind) in [
    (400, OpenAIFailureKind.invalidRequest),
    (401, OpenAIFailureKind.authentication),
    (403, OpenAIFailureKind.permission),
    (404, OpenAIFailureKind.notFound),
    (409, OpenAIFailureKind.conflict),
    (422, OpenAIFailureKind.invalidRequest),
    (429, OpenAIFailureKind.rateLimit),
    (500, OpenAIFailureKind.server),
    (503, OpenAIFailureKind.server),
    (418, OpenAIFailureKind.api),
  ]) {
    test(
      '[WIRE07] real SDK HTTP $status becomes ${kind.name} without hidden adapter retry',
      () async {
        setup(
          {
            'error': {
              'message': 'secret response',
              'type': 'fixture',
              'code': 'fixture-code',
            },
          },
          status: status,
          headers: {'retry-after': '2', 'x-request-id': 'req_fixture'},
        );
        final failure = expected(
          await runtime.runExit(
            ai.createResponse<Unit>(
              CreateResponseRequest(
                model: 'fixture-model',
                input: ResponseInput.text('private prompt'),
              ),
            ),
          ),
        );
        expect(failure.kind, kind);
        expect(failure.statusCode, status);
        expect(failure.cause, isA<ApiException>());
        expect(failure.toString(), isNot(contains('secret')));
        expect(received, hasLength(1));
        if (status == 429) {
          expect(failure.retryAfter, const Duration(seconds: 2));
        }
      },
    );
  }

  test(
    '[WIRE08] explicit Effect retry re-executes a failed SDK request',
    () async {
      transport = MockClient((request) async {
        received.add(request);
        return received.length == 1
            ? http.Response(
                jsonEncode({
                  'error': {'message': 'temporary'},
                }),
                503,
              )
            : http.Response(jsonEncode(responseJson()), 200);
      });
      ai = EffectOpenAIClient(
        sdkClient(transport: transport),
        closeClient: true,
      );
      final result = await runtime.runFuture(
        ai
            .createResponse<Unit>(
              CreateResponseRequest(
                model: 'fixture-model',
                input: ResponseInput.text('test'),
              ),
            )
            .retry(Schedule(recurrences: 1)),
      );
      expect(result.outputText, 'Hello Effect');
      expect(received, hasLength(2));
    },
  );
}

const moderationKeys = [
  'hate',
  'hate/threatening',
  'harassment',
  'harassment/threatening',
  'self-harm',
  'self-harm/intent',
  'self-harm/instructions',
  'sexual',
  'sexual/minors',
  'violence',
  'violence/graphic',
];
