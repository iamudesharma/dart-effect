import 'package:effect_observability/effect_observability.dart';

Future<void> main() async {
  final metrics = MetricRegistry();
  metrics.increment('requests_total');
  print(metrics.prometheus());
  print(TraceContext.root().headers);
}
