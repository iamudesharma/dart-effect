import 'dart:async';

import 'package:effect_reactivity/effect_reactivity.dart';
import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'initial snapshot plus concurrent updates has no registration gap',
    () async {
      final ref = SubscriptionRef(0);
      final iterator = StreamIterator(ref.changes);
      expect(await iterator.moveNext(), true);
      expect(iterator.current, 0);
      ref.set(1);
      ref.set(2);
      expect(await iterator.moveNext(), true);
      expect(iterator.current, 2);
      await iterator.cancel();
      expect(ref.subscriberCount, 0);
      ref.close();
    },
  );
  test('late subscribers see current state and close is idempotent', () async {
    final ref = SubscriptionRef<int?>(null);
    ref.set(3);
    expect(await ref.changes.first, 3);
    ref.close();
    ref.close();
    expect(await ref.changes.isEmpty, true);
    expect(() => ref.set(4), throwsStateError);
  });
  test(
    'channel drains accepted values before typed terminal failure',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      final channel = Channel<int, String>(2);
      await rt.runFuture(channel.offer<Unit>(1));
      channel.fail('terminal');
      expect(
        (await rt.runFuture(
          channel.take<Unit>(),
        ) as ChannelValue<int, String>).value,
        1,
      );
      expect(
        (await rt.runFuture(
          channel.take<Unit>(),
        ) as ChannelFailure<int, String>).error,
        'terminal',
      );
      expect(
        await rt.runExit(channel.offer<Unit>(2)),
        isA<Failure<bool, QueueClosed>>(),
      );
    },
  );
}
