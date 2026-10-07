import 'package:effect_core/effect_core.dart';

final class Greeter {
  Greeter(this.prefix);
  final String prefix;
  String greet(String name) => '$prefix, $name';
}

Future<void> main() async {
  final prefix = ServiceKey<String>('prefix');
  final greeter = ServiceKey<Greeter>('greeter');
  final layer = Layer<String>(
    prefix.effect<String>().map((value) => greeter.bind(Greeter(value))),
    dependencies: [Layer.service<String, String>(prefix, 'Hello')],
  );
  final program = layer.use(
    greeter.effect<String>().map((service) => service.greet('Dart')),
  );
  print(await Runtime(Context()).runFuture(program));
}
