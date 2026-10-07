import 'dart:async';
import 'dart:math';

import 'package:blot_effect/blot_effect.dart';
import 'package:test/test.dart';

void main() {
  test('service keys have identity and additions leave source immutable', () {
    final a = ServiceKey<int>('same');
    final b = ServiceKey<String>('same');
    final empty = Context();
    final one = empty.add(a, 1);
    final both = one.add(b, 'two');
    expect(empty.contains(a), false);
    expect(one.contains(b), false);
    expect(both.get(a), 1);
    expect(both.get(b), 'two');
    expect(() => one.get(b), throwsA(isA<MissingService>()));
    final nullable = ServiceKey<String?>('nullable');
    expect(empty.add(nullable, null).get(nullable), null);
  });

  test('missing services are defects', () async {
    final key = ServiceKey<int>('missing');
    final exit = await Runtime(Context()).runExit(key.effect<String>());
    expect((exit as Failure<int, String>).cause, isA<Defect<String>>());
  });

  test('diamond sharing and scope ownership release resources once', () async {
    final events = <String>[];
    final key = ServiceKey<int>('resource');
    final shared = Layer.resource<int, String>(
      key,
      Effect.sync<int, String, Context>(() {
        events.add('acquire');
        return 7;
      }),
      (_) => Effect.sync<Object?, String, Context>(() {
        events.add('release');
        return null;
      }),
    );
    final left = Layer<String>(
      Effect.succeed<Context, String, Context>(Context()),
      dependencies: [shared],
    );
    final right = Layer<String>(
      Effect.succeed<Context, String, Context>(Context()),
      dependencies: [shared],
    );
    final graph = Layer<String>(
      Effect.succeed<Context, String, Context>(Context()),
      dependencies: [left, right],
    );
    final runtime = Runtime(Context());
    expect(await runtime.runFuture(graph.use(key.effect<String>())), 7);
    expect(events, ['acquire', 'release']);
    expect(await runtime.runFuture(graph.use(key.effect<String>())), 7);
    expect(events, ['acquire', 'release', 'acquire', 'release']);
  });

  test('concurrent builds share acquisition within the same scope', () async {
    final gate = Completer<int>();
    var acquired = 0;
    final key = ServiceKey<int>('shared');
    final layer = Layer<String>(
      Effect.fromFuture<Context, String, Context>(() async {
        acquired++;
        return Context().add(key, await gate.future);
      }),
    );
    final program = Effect.asyncExit<int, String, Context>((context) async {
      final first = context.evaluate(layer.build());
      final second = context.evaluate(layer.build());
      gate.complete(9);
      final exits = await Future.wait([first, second]);
      return Success(
        (exits[0] as Success<Context, String>).value.get(key) +
            (exits[1] as Success<Context, String>).value.get(key),
      );
    });
    expect(await Runtime(Context()).runFuture(program), 18);
    expect(acquired, 1);
  });

  test(
    'failed graph releases partial acquisition before failure escapes',
    () async {
      final events = <String>[];
      final key = ServiceKey<int>('resource');
      final resource = Layer.resource<int, String>(
        key,
        Effect.succeed<int, String, Context>(1),
        (_) => Effect.sync<Object?, String, Context>(() {
          events.add('release');
          return null;
        }),
      );
      final graph = Layer<String>(
        Effect.fail<Context, String, Context>('failed'),
        dependencies: [resource],
      );
      final inspect = Effect.asyncExit<Unit, String, Context>((context) async {
        final exit = await context.evaluate(graph.build());
        expect(exit, isA<Failure<Context, String>>());
        expect(events, ['release']);
        return Success(Unit.value);
      });
      await Runtime(Context()).runFuture(inspect);
      expect(events, ['release']);
    },
  );

  test('cycle is a defect instead of waiting on its own memo entry', () async {
    late Layer<String> a;
    late Layer<String> b;
    a = Layer.suspend(() => b, name: 'a');
    b = Layer.suspend(() => a, name: 'b');
    final exit = await Runtime(Context()).runExit(a.build());
    final cause = (exit as Failure<Context, String>).cause as Defect<String>;
    expect(cause.error, isA<LayerCycle>());
  });

  test(
    'retry counts extra runs and never retries defects or composites',
    () async {
      var runs = 0;
      final effect = Effect.defer<int, String, Unit>(() {
        runs++;
        return Effect.fail<int, String, Unit>('expected');
      });
      await Runtime(Unit.value).runExit(effect.retry(Schedule(recurrences: 2)));
      expect(runs, 3);
      runs = 0;
      final defect = Effect.sync<int, String, Unit>(() {
        runs++;
        throw StateError('defect');
      });
      await Runtime(Unit.value).runExit(defect.retry(Schedule(recurrences: 2)));
      expect(runs, 1);
      runs = 0;
      final composite = Effect.asyncExit<int, String, Unit>((_) {
        runs++;
        return Failure(Sequential(Expected('a'), Expected('b')));
      });
      await Runtime(Unit.value)
          .runExit(composite.retry(Schedule(recurrences: 2)));
      expect(runs, 1);
    },
  );

  test('repeat returns last success and stops on failure', () async {
    var runs = 0;
    final effect = Effect.sync<int, String, Unit>(() => ++runs);
    expect(
      await Runtime(Unit.value)
          .runFuture(effect.repeat(Schedule(recurrences: 2))),
      3,
    );
    runs = 0;
    final failed = Effect.defer<int, String, Unit>(() {
      runs++;
      return Effect.fail<int, String, Unit>('stop');
    });
    await Runtime(Unit.value).runExit(failed.repeat(Schedule(recurrences: 2)));
    expect(runs, 1);
  });

  test('seeded jitter is reproducible, bounded and exponential', () {
    final policy = Schedule(
      recurrences: 4,
      initialDelay: Duration(seconds: 1),
      factor: 2,
      jitter: .2,
      seed: 3,
    );
    final first = Random(policy.seed);
    final second = Random(policy.seed);
    for (var i = 0; i < 4; i++) {
      final delay = policy.delay(i, first);
      expect(delay, policy.delay(i, second));
      expect(
        delay.inMicroseconds,
        inInclusiveRange(800000 * pow(2, i), 1200000 * pow(2, i)),
      );
    }
  });

  test('logs use injected sink and immutable fields', () async {
    final records = <LogRecord>[];
    await Runtime(
      Unit.value,
      logger: records.add,
    ).runFuture(log<String, Unit>('hello', fields: {'request': 1}));
    expect(records.single.message, 'hello');
    expect(records.single.fields['request'], 1);
    expect(() => records.single.fields['request'] = 2, throwsUnsupportedError);
  });
  test('zero delay remains zero after exponential overflow', () {
    final zero = Schedule(recurrences: 2000, factor: 2);
    expect(zero.delay(2000, Random(1)), Duration.zero);
    final huge = Schedule(
      recurrences: 2000,
      initialDelay: Duration(microseconds: 1),
      factor: 2,
    );
    expect(huge.delay(2000, Random(1)).inMicroseconds, 9007199254740991);
    expect(() => zero.delay(-1, Random(1)), throwsArgumentError);
  });
  test(
    'partial Layer cleanup errors are reported once without duplicated causes',
    () async {
      var releases = 0;
      final resource = Layer.resource<int, String>(
        ServiceKey<int>('r'),
        Effect.succeed(1),
        (_) => Effect.defer(() {
          releases++;
          return Effect.fail('cleanup');
        }),
      );
      final failed = Layer<String>(
        Effect.fail('build'),
        dependencies: [resource],
      );
      final exit = await Runtime(Context()).runExit(failed.build());
      final cause =
          (exit as Failure<Context, String>).cause as Sequential<String>;
      expect((cause.first as Expected).error, 'build');
      expect((cause.second as Expected).error, 'cleanup');
      expect(releases, 1);
    },
  );
}
