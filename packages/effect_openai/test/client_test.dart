import 'dart:async';
import 'dart:convert';

import 'package:effect_core/effect_core.dart';
import 'package:effect_openai/effect_openai.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

OpenAIClient sdkClient({http.Client? transport}) => OpenAIClient(
  config: const OpenAIConfig(
    authProvider: ApiKeyProvider('fixture-key'),
    retryPolicy: RetryPolicy(maxRetries: 0),
  ),
  httpClient: transport,
);

OpenAIFailure expected<A>(Exit<A, OpenAIFailure> exit) =>
    ((exit as Failure<A, OpenAIFailure>).cause as Expected<OpenAIFailure>)
        .error;

void main() {
  late Runtime<Unit> runtime;
  late EffectOpenAIClient ai;
  setUp(() {
    runtime = Runtime(Unit.value);
    ai = EffectOpenAIClient(sdkClient(), closeClient: true);
  });
  tearDown(() async {
    await runtime.shutdown();
    await ai.shutdown();
  });

  test('[AI01] lazy reusable requests allocate fresh abort state', () async {
    var calls = 0;
    final aborts = <Future<void>>[];
    final effect = ai.request<int, Unit>((_, abort) async {
      calls++;
      aborts.add(abort);
      return calls;
    });
    expect(calls, 0);
    expect(await runtime.runFuture(effect), 1);
    expect(await runtime.runFuture(effect), 2);
    expect(identical(aborts[0], aborts[1]), isFalse);
  });

  test('[AI02] cancellation drains cleanup before returning', () async {
    final started = Completer<void>();
    final aborted = Completer<void>();
    final release = Completer<void>();
    final fiber = runtime.fork(
      ai.request<int, Unit>((_, abort) async {
        started.complete();
        await abort;
        aborted.complete();
        await release.future;
        throw const AbortedException();
      }),
    );
    await started.future;
    var finished = false;
    final result = fiber.interruptAndAwait().then((exit) {
      finished = true;
      return exit;
    });
    await aborted.future;
    expect(finished, isFalse);
    release.complete();
    expect((await result as Failure).cause, isA<Interrupted>());
  });

  test(
    '[AI03] cancelling one concurrent run leaves its sibling usable',
    () async {
      final started = [Completer<void>(), Completer<void>()];
      final finish = Completer<int>();
      var index = 0;
      final effect = ai.request<int, Unit>((_, abort) {
        final current = index++;
        started[current].complete();
        return current == 0
            ? abort.then<int>((_) => throw const AbortedException())
            : finish.future;
      });
      final first = runtime.fork(effect);
      final second = runtime.fork(effect);
      await Future.wait(started.map((c) => c.future));
      expect(
        (await first.interruptAndAwait() as Failure).cause,
        isA<Interrupted>(),
      );
      finish.complete(42);
      expect((await second.awaitExit() as Success).value, 42);
    },
  );

  test('[AI04] timeout signals abort and awaits underlying work', () async {
    final started = Completer<void>();
    var aborted = false;
    final effect = ai
        .request<int, Unit>((_, abort) async {
          started.complete();
          await abort;
          aborted = true;
          throw const AbortedException();
        })
        .timeout(
          const Duration(milliseconds: 20),
          () => const OpenAIFailure(
            kind: OpenAIFailureKind.timeout,
            operation: 'deadline',
          ),
        );
    final result = runtime.runExit(effect);
    await started.future;
    expect(expected(await result).kind, OpenAIFailureKind.timeout);
    expect(aborted, isTrue);
  });

  test(
    '[AI05] SDK abortion is interruption, not recoverable expected error',
    () async {
      var recovered = false;
      final result = await runtime.runExit(
        ai
            .request<int, Unit>((_, _) async {
              throw const AbortedException();
            })
            .catchAll((_) {
              recovered = true;
              return Effect.succeed(1);
            }),
      );
      expect((result as Failure).cause, isA<Interrupted>());
      expect(recovered, isFalse);
    },
  );

  test('[AI06] programmer errors remain defects and are not retried', () async {
    var calls = 0;
    final result = await runtime.runExit(
      ai
          .request<int, Unit>((_, _) {
            calls++;
            throw StateError('programmer bug');
          })
          .catchAll((_) => Effect.succeed(1)),
    );
    expect((result as Failure).cause, isA<Defect>());
    expect(calls, 1);
  });

  for (final (error, kind) in <(OpenAIException, OpenAIFailureKind)>[
    (
      const RequestTimeoutException(message: 'timeout'),
      OpenAIFailureKind.timeout,
    ),
    (
      const ConnectionException(message: 'network'),
      OpenAIFailureKind.connection,
    ),
    (const ParseException(message: 'bad JSON'), OpenAIFailureKind.decoding),
  ]) {
    test('[AI07] ${kind.name} SDK failures retain original cause', () async {
      final failure = expected(
        await runtime.runExit(
          ai.request<int, Unit>((_, _) async => throw error),
        ),
      );
      expect(failure.kind, kind);
      expect(identical(failure.cause, error), isTrue);
    });
  }

  test(
    '[AI08] summaries omit server message, prompt and credential text',
    () async {
      const error = RateLimitException(
        message: 'secret prompt/key',
        code: 'secret-code',
        requestId: 'secret-request',
        retryAfter: Duration(seconds: 2),
      );
      final failure = expected(
        await runtime.runExit(
          ai.request<int, Unit>(
            (_, _) async => throw error,
            operation: 'secret-operation',
          ),
        ),
      );
      expect(failure.retryAfter, const Duration(seconds: 2));
      expect(failure.requestId, 'secret-request');
      expect(failure.code, 'secret-code');
      expect(failure.toString(), isNot(contains('secret')));
    },
  );

  test('[AI09] shutdown aborts active requests and rejects new work', () async {
    final started = Completer<void>();
    final result = runtime.runExit(
      ai.request<int, Unit>((_, abort) async {
        started.complete();
        await abort;
        throw const AbortedException();
      }),
    );
    await started.future;
    await ai.shutdown();
    expect((await result as Failure).cause, isA<Interrupted>());
    expect(
      expected(await runtime.runExit(ai.request<int, Unit>((_, _) async => 1)))
          .kind,
      OpenAIFailureKind.closed,
    );
    await ai.shutdown();
  });

  test(
    '[AI10] borrowed SDK clients remain usable after adapter shutdown',
    () async {
      final transport = MockClient(
        (_) async => http.Response(jsonEncode(responseJson()), 200),
      );
      final sdk = sdkClient(transport: transport);
      final borrowed = EffectOpenAIClient(sdk);
      await borrowed.shutdown();
      expect(
        (await sdk.responses.create(
          CreateResponseRequest(
            model: 'fixture-model',
            input: ResponseInput.text('test'),
          ),
        )).outputText,
        'Hello Effect',
      );
      sdk.close();
      transport.close();
    },
  );

  test(
    '[AI11] layer lazily creates and closes one SDK per construction scope',
    () async {
      final key = ServiceKey<EffectOpenAIClient>('openai');
      var created = 0;
      var closed = 0;
      final layer = EffectOpenAIClient.layer(key, () {
        created++;
        return _CountingClient(() => closed++);
      });
      final contextRuntime = Runtime(Context());
      addTearDown(contextRuntime.shutdown);
      final program = layer.use(
        Effect.environment<EffectOpenAIClient, OpenAIFailure, Context>(
          (ctx) => ctx.get(key),
        ).flatMap((client) => client.request<int, Context>((_, _) async => 42)),
      );
      expect(created, 0);
      expect(await contextRuntime.runFuture(program), 42);
      expect((created, closed), (1, 1));
      expect(await contextRuntime.runFuture(program), 42);
      expect((created, closed), (2, 2));
    },
  );

  test('[AI12] owned shutdown is idempotent', () async {
    var closed = 0;
    final owned = EffectOpenAIClient(
      _CountingClient(() => closed++),
      closeClient: true,
    );
    await Future.wait([owned.shutdown(), owned.shutdown()]);
    expect(closed, 1);
  });

  test('[AI13] stream is lazy/reusable and delivers ordered values', () async {
    var opened = 0;
    final effect = ai
        .stream<int, Unit>((_, _) {
          opened++;
          return Stream.fromIterable([1, 2, 3]);
        })
        .run(Sink.collect());
    expect(opened, 0);
    expect(await runtime.runFuture(effect), [1, 2, 3]);
    expect(await runtime.runFuture(effect), [1, 2, 3]);
    expect(opened, 2);
  });

  test('[AI14] take(0) does not acquire or open upstream', () async {
    var opened = 0;
    final effect = ai
        .stream<int, Unit>((_, _) {
          opened++;
          return Stream.value(1);
        })
        .take(0)
        .run(Sink.collect());
    expect(await runtime.runFuture(effect), isEmpty);
    expect(opened, 0);
  });

  test(
    '[AI15] early sink aborts before awaiting source cancellation',
    () async {
      var cancelled = 0;
      final stream = ai.stream<int, Unit>((_, abort) {
        final controller = StreamController<int>();
        controller.onListen = () => controller.add(7);
        controller.onCancel = () async {
          await abort; // Would deadlock if cancellation were signalled afterwards.
          cancelled++;
        };
        return controller.stream;
      });
      expect(await runtime.runFuture(stream.take(1).run(Sink.collect())), [7]);
      expect(cancelled, 1);
    },
  );

  test(
    '[AI16] interruption cancels a stream blocked before its first event',
    () async {
      final started = Completer<void>();
      var cancelled = false;
      final fiber = runtime.fork(
        ai
            .stream<int, Unit>((_, abort) {
              final controller = StreamController<int>();
              controller.onListen = started.complete;
              controller.onCancel = () async {
                await abort;
                cancelled = true;
              };
              return controller.stream;
            })
            .run(Sink.collect()),
      );
      await started.future;
      expect(
        (await fiber.interruptAndAwait() as Failure).cause,
        isA<Interrupted>(),
      );
      expect(cancelled, isTrue);
    },
  );

  test(
    '[AI17] stream SDK errors are typed and callback defects remain defects',
    () async {
      for (final error in [
        const AuthenticationException(message: 'bad key'),
        StateError('bug'),
      ]) {
        final exit = await runtime.runExit(
          ai
              .stream<int, Unit>((_, _) => Stream.error(error))
              .run(Sink.collect()),
        );
        final cause = (exit as Failure).cause;
        expect(
          cause,
          error is OpenAIException ? isA<Expected>() : isA<Defect>(),
        );
      }
    },
  );

  test(
    '[AI18] synchronous stream factory failures still release ownership',
    () async {
      final exit = await runtime.runExit(
        ai
            .stream<int, Unit>((_, _) => throw StateError('bug'))
            .run(Sink.collect()),
      );
      expect((exit as Failure).cause, isA<Defect>());
      await ai.shutdown();
    },
  );

  test(
    '[AI19] shutdown cancels a paused stream without waiting for another pull',
    () async {
      final inSink = Completer<void>();
      final resumeSink = Completer<void>();
      var cancelled = false;
      final result = runtime.runExit(
        ai
            .stream<int, Unit>((_, abort) {
              final controller = StreamController<int>();
              controller.onListen = () => controller.add(1);
              controller.onCancel = () async {
                await abort;
                cancelled = true;
              };
              return controller.stream;
            })
            .run(
              Sink<int, int, OpenAIFailure, Unit>.fold(
                () => 0,
                (sum, n) => Effect.fromFuture(() async {
                  inSink.complete();
                  await resumeSink.future;
                  return (sum + n, true);
                }),
              ),
            ),
      );
      await inSink.future;
      await ai.shutdown();
      expect(cancelled, isTrue);
      resumeSink.complete();
      expect((await result as Failure).cause, isA<Interrupted>());
    },
  );
  test(
    '[AI20] ordinary child is aborted before the owning layer closes its SDK',
    () async {
      final started = Completer<void>();
      final trace = <String>[];
      final key = ServiceKey<EffectOpenAIClient>('openai');
      final layer = EffectOpenAIClient.layer(
        key,
        () => _CountingClient(() => trace.add('close')),
      );
      final contextRuntime = Runtime(Context());
      addTearDown(contextRuntime.shutdown);
      final body =
          Effect.environment<EffectOpenAIClient, OpenAIFailure, Context>(
            (ctx) => ctx.get(key),
          ).flatMap(
            (client) => client
                .request<int, Context>((_, abort) async {
                  started.complete();
                  await abort;
                  trace.add('abort');
                  throw const AbortedException();
                })
                .fork()
                .flatMap(
                  (_) =>
                      Effect.fromFuture<int, OpenAIFailure, Context>(() async {
                        await started.future;
                        return 42;
                      }),
                ),
          );
      expect(await contextRuntime.runFuture(layer.use(body)), 42);
      expect(trace, ['abort', 'close']);
    },
  );

  test('[AI21] stream cancellation acknowledgement is awaited', () async {
    final started = Completer<void>();
    final cancelling = Completer<void>();
    final release = Completer<void>();
    final fiber = runtime.fork(
      ai
          .stream<int, Unit>((_, abort) {
            final source = StreamController<int>();
            source.onListen = started.complete;
            source.onCancel = () async {
              await abort;
              cancelling.complete();
              await release.future;
            };
            return source.stream;
          })
          .run(Sink.collect()),
    );
    await started.future;
    var finished = false;
    final exit = fiber.interruptAndAwait().then((exit) {
      finished = true;
      return exit;
    });
    await cancelling.future;
    expect(finished, isFalse);
    release.complete();
    expect((await exit as Failure).cause, isA<Interrupted>());
  });

  test(
    '[AI22] a shut-down adapter rejects streaming without opening the source',
    () async {
      await ai.shutdown();
      var opened = false;
      final exit = await runtime.runExit(
        ai
            .stream<int, Unit>((_, _) {
              opened = true;
              return Stream.value(1);
            })
            .run(Sink.collect()),
      );
      expect(expected(exit).kind, OpenAIFailureKind.closed);
      expect(opened, isFalse);
    },
  );

  test(
    '[AI23] layer release happens after defects and retained handles expire',
    () async {
      final key = ServiceKey<EffectOpenAIClient>('openai');
      var closed = 0;
      late EffectOpenAIClient retained;
      final layer = EffectOpenAIClient.layer(
        key,
        () => _CountingClient(() => closed++),
      );
      final contextRuntime = Runtime(Context());
      addTearDown(contextRuntime.shutdown);
      final exit = await contextRuntime.runExit(
        layer.use(
          Effect.environment<EffectOpenAIClient, OpenAIFailure, Context>(
            (ctx) => ctx.get(key),
          ).flatMap((client) {
            retained = client;
            return Effect.sync<int, OpenAIFailure, Context>(
              () => throw StateError('body'),
            );
          }),
        ),
      );
      expect((exit as Failure).cause, isA<Defect>());
      expect(closed, 1);
      expect(
        expected(
          await runtime.runExit(retained.request<int, Unit>((_, _) async => 1)),
        ).kind,
        OpenAIFailureKind.closed,
      );
    },
  );
}

final class _CountingClient extends OpenAIClient {
  _CountingClient(this.onClose)
    : super(
        config: const OpenAIConfig(retryPolicy: RetryPolicy(maxRetries: 0)),
      );
  final void Function() onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}
