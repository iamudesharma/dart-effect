import 'package:effect_core/effect_core.dart';

Future<void> main() async {
  final metrics = RuntimeMetrics();
  final runtime = Runtime(Unit.value, metrics: metrics);
  final breaker = CircuitBreaker(failureThreshold: 3);
  final limiter = RateLimiter(const Duration(milliseconds: 10));
  var attempts = 0;
  final read = Effect.defer<String, String, Unit>(() {
    attempts++;
    return attempts < 2 ? Effect.fail('temporary') : Effect.succeed('ready');
  });
  final result = await runtime.runFuture(
    limiter
        .limit(
          breaker.protect(
            read.retry(
              Schedule(
                recurrences: 2,
                initialDelay: const Duration(milliseconds: 5),
                maxDelay: const Duration(milliseconds: 20),
                elapsedBudget: const Duration(seconds: 1),
              ),
              whileError: (error) => error == 'temporary',
            ),
            onOpen: () => 'service unavailable',
          ),
        )
        .traced('safe-read'),
  );
  print(
    '$result after $attempts attempts; ${metrics.completed} fiber completed',
  );
  await runtime.shutdown();
}
