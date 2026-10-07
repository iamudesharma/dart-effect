import 'dart:async';

import 'package:blot_effect/blot_effect.dart';

Future<void> main() async {
  var attempts = 0;
  // Every run gets a fresh timer and cancellation hook. A real I/O adapter can
  // replace the timer with its transport's abort operation.
  final request = Effect.defer<String, String, Unit>(() {
    Timer? timer;
    final result = Completer<String>();
    return Effect.fromFuture<String, String, Unit>(
      () {
        final attempt = ++attempts;
        timer = Timer(const Duration(milliseconds: 5), () {
          if (attempt < 3) {
            result.completeError(StateError('temporary'));
          } else {
            result.complete('response');
          }
        });
        return result.future;
      },
      onError: (error, stack) => 'temporary failure',
      onCancel: () => timer?.cancel(),
    );
  });
  final runtime = Runtime(Unit.value);
  print(
    await runtime.runFuture(
      request.retry(
        Schedule(
          recurrences: 3,
          initialDelay: const Duration(milliseconds: 5),
          factor: 2,
          jitter: .2,
          seed: 7,
        ),
      ),
    ),
  );
  await runtime.shutdown();
}
