# effect_observability

Unpublished development package (`0.1.0-dev.1`). Use only for an explicitly requested local/development integration. The existing hosted packages do not contain this API.

## Install locally

```yaml
dependencies:
  effect_observability:
    path: /path/to/effect_dart/packages/effect_observability

dependency_overrides:
  effect_core:
    path: /path/to/effect_dart
```

## Usage

```dart
import 'package:effect_observability/effect_observability.dart';

Future<void> main() async {
  final metrics = MetricRegistry();
  metrics.increment('requests_total');
  print(metrics.prometheus());
  print(TraceContext.root().headers);
}
```

## Contracts and limits

Bounded metric cardinality, counters/gauges/cumulative histograms, Prometheus text and W3C traceparent propagation. BoundedExporter has explicit flush/close; a failed batch is dropped and its failure surfaced, without automatic replay. This does not implement OTLP wire formats, a collector, full spans, request-local fiber context or a background daemon.

## Validate

Run `dart analyze`, `dart test`, and `dart run example/main.dart` from this package directory. Portable scenarios also run in Chrome; native-only integrations do not. Fixtures are not proof of production services, mobile acceptance or universal leak freedom.
