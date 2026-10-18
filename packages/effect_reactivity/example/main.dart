import 'package:effect_reactivity/effect_reactivity.dart';

Future<void> main() async {
  final state = SubscriptionRef(0);
  state.set(42);
  print(await state.changes.first);
  state.close();
}
