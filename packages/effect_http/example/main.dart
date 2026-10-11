import 'package:effect_core/effect_core.dart';
import 'package:effect_http/effect_http.dart';
import 'package:http/http.dart' as http;

/// Run against a local HTTP fixture: dart run example/main.dart http://localhost:8080/
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('Supply an HTTP URL');
    return;
  }
  final client = http.Client(), runtime = Runtime(Unit.value);
  try {
    final response = await runtime.runExit(
      EffectHttp(client)
          .request<Unit>('GET', Uri.parse(args.single))
          .timeout(
            const Duration(seconds: 10),
            () => const HttpFailure('deadline exceeded'),
          ),
    );
    switch (response) {
      case Success(:final value):
        print('${value.status}: ${value.text}');
      case Failure(:final cause):
        print('HTTP outcome: $cause');
    }
  } finally {
    await runtime.shutdown();
    client.close();
  }
}
