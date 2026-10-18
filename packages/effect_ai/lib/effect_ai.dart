/// Provider-neutral generation contracts and explicitly bounded tool execution.
library;

import 'dart:convert';

import 'package:effect_core/effect_core.dart';
import 'package:effect_schema/effect_schema.dart';

enum FinishReason { complete, toolCalls, refused, incomplete, failed }

final class AiMessage {
  const AiMessage(this.role, this.content);
  final String role, content;
}

final class AiUsage {
  const AiUsage({this.inputTokens = 0, this.outputTokens = 0});
  final int inputTokens, outputTokens;
}

final class ToolCall {
  const ToolCall(this.id, this.name, this.arguments);
  final String id, name;
  final Object? arguments;
}

final class AiResponse {
  AiResponse({
    required this.text,
    this.finish = FinishReason.complete,
    this.usage = const AiUsage(),
    List<ToolCall> calls = const [],
  }) : calls = List.unmodifiable(calls);
  final String text;
  final FinishReason finish;
  final AiUsage usage;
  final List<ToolCall> calls;
}

enum AiFailureKind {
  transport,
  refused,
  incomplete,
  invalidOutput,
  unknownTool,
  limit,
}

final class AiFailure implements Exception {
  const AiFailure(this.kind, this.message, {this.validation});
  final AiFailureKind kind;
  final String message;
  final SchemaError? validation;
  @override
  String toString() => 'AiFailure(${kind.name}, $message)';
}

abstract interface class LanguageModel<R> {
  Effect<AiResponse, AiFailure, R> generate(List<AiMessage> messages);
}

abstract interface class EmbeddingModel<R> {
  Effect<List<List<double>>, AiFailure, R> embed(List<String> inputs);
}

/// Adapt an existing provider's typed request/response operation without adding
/// a dependency on a vendor SDK to the neutral package.
final class FunctionLanguageModel<R> implements LanguageModel<R> {
  FunctionLanguageModel(this._generate);
  final Effect<AiResponse, AiFailure, R> Function(List<AiMessage>) _generate;
  @override
  Effect<AiResponse, AiFailure, R> generate(List<AiMessage> messages) =>
      Effect.defer(() => _generate(List.unmodifiable(messages)));
}

extension StructuredModel<R> on LanguageModel<R> {
  Effect<T, AiFailure, R> structured<T>(
    List<AiMessage> messages,
    Schema<T> schema,
  ) => generate(messages).flatMap((response) {
    if (response.finish != FinishReason.complete) {
      return Effect.fail(
        AiFailure(
          response.finish == FinishReason.refused
              ? AiFailureKind.refused
              : AiFailureKind.incomplete,
          'Generation did not complete',
        ),
      );
    }
    Object? input;
    try {
      input = jsonDecode(response.text);
    } catch (_) {
      return Effect.fail(
        const AiFailure(AiFailureKind.invalidOutput, 'Expected JSON output'),
      );
    }
    final decoded = schema.decode(input);
    return switch (decoded) {
      Valid(:final value) => Effect.succeed(value),
      Invalid(:final error) => Effect.fail(
        AiFailure(
          AiFailureKind.invalidOutput,
          'Schema rejected model output',
          validation: error,
        ),
      ),
    };
  });
}

final class ToolDefinition<R> {
  ToolDefinition._(this.name, this.inputSchema, this._run);
  final String name;
  final Map<String, Object?> inputSchema;
  final Effect<Object?, AiFailure, R> Function(Object?) _run;
  static ToolDefinition<R> typed<A, B, R>(
    String name,
    Schema<A> input,
    Schema<B> output,
    Effect<B, AiFailure, R> Function(A) handler,
  ) => ToolDefinition._(name, input.toJsonSchema(), (arguments) {
    final decoded = input.decode(arguments);
    if (decoded is Invalid<A>) {
      return Effect.fail(
        AiFailure(
          AiFailureKind.invalidOutput,
          'Invalid tool arguments',
          validation: decoded.error,
        ),
      );
    }
    return Effect.defer(() => handler((decoded as Valid<A>).value))
        .flatMap((value) {
          final encoded = output.encode(value);
          return switch (encoded) {
            Valid(:final value) => Effect.succeed(value),
            Invalid(:final error) => Effect.fail(
              AiFailure(
                AiFailureKind.invalidOutput,
                'Invalid tool result',
                validation: error,
              ),
            ),
          };
        });
  });
}

final class ToolResult {
  const ToolResult(this.id, this.value);
  final String id;
  final Object? value;
}

/// Only explicitly registered handlers run. Never executes model-provided code.
final class Toolkit<R> {
  Toolkit(
    Iterable<ToolDefinition<R>> tools, {
    this.maxCalls = 16,
    this.concurrency = 4,
  }) {
    if (maxCalls < 1 || concurrency < 1) {
      throw ArgumentError('Invalid execution bounds');
    }
    for (final tool in tools) {
      if (_tools.containsKey(tool.name)) {
        throw ArgumentError('Duplicate tool name');
      }
      _tools[tool.name] = tool;
    }
  }
  final _tools = <String, ToolDefinition<R>>{};
  final int maxCalls, concurrency;
  Effect<List<ToolResult>, AiFailure, R> execute(List<ToolCall> calls) =>
      Effect.defer(() {
        if (calls.length > maxCalls ||
            calls.map((c) => c.id).toSet().length != calls.length) {
          return Effect.fail(
            const AiFailure(
              AiFailureKind.limit,
              'Tool call bound or unique IDs violated',
            ),
          );
        }
        // Validate names before starting any handler.
        if (calls.any((call) => !_tools.containsKey(call.name))) {
          return Effect.fail(
            const AiFailure(
              AiFailureKind.unknownTool,
              'Unregistered tool requested',
            ),
          );
        }
        return Effect.traverse<ToolCall, ToolResult, AiFailure, R>(
          calls,
          (call) => _tools[call.name]!
              ._run(call.arguments)
              .map((value) => ToolResult(call.id, value)),
          concurrency: concurrency,
        );
      });
}

/// Explicit bounded tool loop. Model calls and handlers are single-attempt.
/// Supply the provider's tool declarations when constructing its adapter.
final class ToolAgent<R> {
  ToolAgent(
    this.model,
    this.toolkit, {
    this.maxSteps = 4,
    this.maxTokens = 100000,
  }) {
    if (maxSteps < 1 || maxTokens < 1) {
      throw ArgumentError('Invalid agent budget');
    }
  }
  final LanguageModel<R> model;
  final Toolkit<R> toolkit;
  final int maxSteps, maxTokens;
  Effect<AiResponse, AiFailure, R> run(List<AiMessage> input) =>
      Effect.asyncExit((ctx) async {
        final messages = List<AiMessage>.of(input);
        var tokens = 0;
        for (var step = 0; step < maxSteps; step++) {
          final generated = await ctx.evaluate(
            model.generate(List.unmodifiable(messages)),
          );
          if (generated is Failure<AiResponse, AiFailure>) return generated;
          final response = (generated as Success<AiResponse, AiFailure>).value;
          tokens += response.usage.inputTokens + response.usage.outputTokens;
          if (tokens > maxTokens) {
            return const Failure(
              Expected(AiFailure(AiFailureKind.limit, 'Token budget exceeded')),
            );
          }
          if (response.finish == FinishReason.complete) return generated;
          if (response.finish != FinishReason.toolCalls) {
            return Failure(
              Expected(
                AiFailure(
                  response.finish == FinishReason.refused
                      ? AiFailureKind.refused
                      : AiFailureKind.incomplete,
                  'Generation did not complete',
                ),
              ),
            );
          }
          final tools = await ctx.evaluate(toolkit.execute(response.calls));
          if (tools is Failure<List<ToolResult>, AiFailure>) {
            return Failure(tools.cause);
          }
          messages.add(AiMessage('assistant', response.text));
          for (final result
              in (tools as Success<List<ToolResult>, AiFailure>).value) {
            messages.add(
              AiMessage(
                'tool',
                jsonEncode({'id': result.id, 'value': result.value}),
              ),
            );
          }
        }
        return const Failure(
          Expected(AiFailure(AiFailureKind.limit, 'Step budget exceeded')),
        );
      });
}
