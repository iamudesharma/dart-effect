import 'dart:async';

import 'package:test/test.dart';

Future<void> eventTurn() => Future<void>.delayed(Duration.zero);
Future<void> checkpoint(
  bool Function() reached, {
  String reason = 'lost wake-up',
}) async {
  for (var i = 0; i < 200 && !reached(); i++) {
    await eventTurn();
  }
  expect(reached(), isTrue, reason: reason);
}
