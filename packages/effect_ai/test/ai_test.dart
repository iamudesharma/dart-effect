import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';
import 'package:effect_ai/effect_ai.dart';
import 'package:test/test.dart';

void main() {
  test(
    'structured generation validates output and distinguishes refusals',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      final model = FunctionLanguageModel<Unit>(
        (_) => Effect.succeed(AiResponse(text: '{"n":3}')),
      );
      expect(
        await rt.runFuture(
          model.structured([], Schema.object({'n': Field(Schema.integer)})),
        ),
        {'n': 3},
      );
      final refusal = FunctionLanguageModel<Unit>(
        (_) => Effect.succeed(
          AiResponse(text: '{}', finish: FinishReason.refused),
        ),
      );
      final failed = await rt.runExit(refusal.structured([], Schema.integer));
      expect(
        ((failed as Failure<int, AiFailure>).cause as Expected<AiFailure>)
            .error
            .kind,
        AiFailureKind.refused,
      );
    },
  );
  test(
    'only validated registered tools run, with call and concurrency bounds',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      var calls = 0;
      final tool = ToolDefinition.typed<int, int, Unit>(
        'twice',
        Schema.integer,
        Schema.integer,
        (n) => Effect.sync(() {
          calls++;
          return n * 2;
        }),
      );
      final toolkit = Toolkit([tool], maxCalls: 2, concurrency: 1);
      expect(
        (await rt.runFuture(toolkit.execute([const ToolCall('1', 'twice', 4)])))
            .single
            .value,
        8,
      );
      expect(
        await rt.runExit(toolkit.execute([const ToolCall('2', 'unknown', 4)])),
        isA<Failure<List<ToolResult>, AiFailure>>(),
      );
      expect(
        await rt.runExit(
          toolkit.execute([const ToolCall('3', 'twice', 'wrong')]),
        ),
        isA<Failure<List<ToolResult>, AiFailure>>(),
      );
      expect(calls, 1);
    },
  );
  test(
    'tool agent bounds explicit repeated generation and tool execution',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      var executions = 0, requests = 0;
      final tool = ToolDefinition.typed<int, int, Unit>(
        'echo',
        Schema.integer,
        Schema.integer,
        (n) => Effect.sync(() {
          executions++;
          return n;
        }),
      );
      final model = FunctionLanguageModel<Unit>(
        (_) => Effect.sync(() {
          requests++;
          return AiResponse(
            text: '',
            finish: FinishReason.toolCalls,
            calls: [ToolCall('$requests', 'echo', 1)],
          );
        }),
      );
      final agent = ToolAgent(model, Toolkit([tool]), maxSteps: 2);
      final result = await rt.runExit(agent.run([]));
      expect(
        ((result as Failure<AiResponse, AiFailure>).cause
                as Expected<AiFailure>)
            .error
            .kind,
        AiFailureKind.limit,
      );
      expect(requests, 2);
      expect(executions, 2);
    },
  );
}
