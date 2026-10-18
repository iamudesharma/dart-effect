import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:effect_core/effect_core.dart';
import 'package:effect_flutter/effect_flutter.dart';

void main() {
  testWidgets(
    'ValueListenableBuilder renders owned effect output and async close is explicit',
    (tester) async {
      final controller = EffectController<int, String, Unit>(Unit.value);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder<EffectState<int, String>>(
            valueListenable: controller,
            builder: (_, state, _) => Text(switch (state) {
              EffectData(:final value) => '$value',
              _ => 'waiting',
            }),
          ),
        ),
      );
      expect(find.text('waiting'), findsOneWidget);
      await tester.runAsync(() => controller.run(Effect.succeed(42)));
      await tester.pump();
      expect(find.text('42'), findsOneWidget);
      await tester.runAsync(controller.close);
    },
  );
  test('new request cancels previous request and waits its cleanup before starting', () async {
    final controller = EffectController<int, String, Unit>(Unit.value);
    final started = Completer<void>();
    final events = <String>[];
    final first = controller.run(
      Effect.fromFuture<int, String, Unit>(() {
        started.complete();
        return Completer<int>().future;
      }).ensuring(
        Effect.sync<Unit, String, Unit>(() {
          events.add('cleanup');
          return Unit.value;
        }),
      ),
    );
    await started.future;
    final second = controller.run(
      Effect.sync<int, String, Unit>(() {
        events.add('second');
        return 2;
      }),
    );
    expect(await first, isA<Failure<int, String>>());
    expect(await second, isA<Success<int, String>>());
    expect(events, ['cleanup', 'second']);
    expect(controller.value, isA<EffectData<int, String>>());
    await controller.close();
    controller.dispose();
    expect(() => controller.run(Effect.succeed(3)), throwsStateError);
  });
  test(
    'dispose prevents post-disposal notifications and close awaits cleanup',
    () async {
      final controller = EffectController<int, String, Unit>(Unit.value);
      final started = Completer<void>();
      var calls = 0, cleaned = false;
      controller.addListener(() => calls++);
      final running = controller.run(
        Effect.fromFuture<int, String, Unit>(() {
          started.complete();
          return Completer<int>().future;
        }).ensuring(
          Effect.sync<Unit, String, Unit>(() {
            cleaned = true;
            return Unit.value;
          }),
        ),
      );
      await started.future;
      final before = calls;
      controller.dispose();
      await controller.close();
      await running;
      expect(calls, before);
      expect(cleaned, true);
    },
  );
}
