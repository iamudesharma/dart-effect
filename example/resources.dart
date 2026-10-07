import 'package:blot_effect/blot_effect.dart';

Future<void> main() async {
  final connection = ServiceKey<String>('connection');
  final layer = Layer.resource<String, String>(
    connection,
    Effect.sync<String, String, Context>(() {
      print('open');
      return 'connected';
    }),
    (_) => Effect.sync<Object?, String, Context>(() {
      print('close');
      return null;
    }),
  );
  print(
    await Runtime(Context()).runFuture(layer.use(connection.effect<String>())),
  );
}
