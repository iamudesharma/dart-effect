import 'package:effect_config/effect_config.dart';

Future<void> main() async {
  final provider = ConfigProvider({'PORT': '8080'});
  print(Config.port('PORT').load(provider));
}
