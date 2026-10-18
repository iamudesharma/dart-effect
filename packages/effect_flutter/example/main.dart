import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:effect_core/effect_core.dart';
import 'package:effect_flutter/effect_flutter.dart';

void main() => runApp(const Demo());

class Demo extends StatefulWidget {
  const Demo({super.key});
  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> {
  final owner = EffectController<int, String, Unit>(Unit.value);
  @override
  void initState() {
    super.initState();
    unawaited(owner.run(Effect.succeed(42)));
  }

  @override
  void dispose() {
    owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ValueListenableBuilder<EffectState<int, String>>(
      valueListenable: owner,
      builder: (_, state, _) => Center(
        child: Text(switch (state) {
          EffectData(:final value) => '$value',
          EffectFailed() => 'Failed',
          _ => 'Loading',
        }),
      ),
    ),
  );
}
