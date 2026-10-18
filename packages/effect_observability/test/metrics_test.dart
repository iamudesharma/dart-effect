import 'package:effect_observability/effect_observability.dart';
import 'package:test/test.dart';

void main() {
  test('metrics export cumulative buckets and escaped labels with cardinality bound', () {
    final registry = MetricRegistry(maxSeries: 3);
    registry.increment('requests_total', labels: {'path': 'a"\nb'});
    registry.gauge('inflight', 2);
    registry.observe('latency_seconds', .2, buckets: [.1, .5]);
    final out = registry.prometheus();
    expect(out, contains('latency_seconds_bucket{le="0.1"} 0'));
    expect(out, contains('latency_seconds_bucket{le="0.5"} 1'));
    expect(out, contains('a\\"\\nb'));
    expect(() => registry.increment('other'), throwsStateError);
    expect(
      () => registry.increment('requests_total', amount: -1),
      throwsArgumentError,
    );
  });
  test('W3C context parsing, child propagation and zero IDs', () {
    final parent = TraceContext.root();
    final child = parent.child();
    expect(child.traceId, parent.traceId);
    expect(child.spanId, isNot(parent.spanId));
    expect(
      TraceContext.parse(child.traceparent)!.traceparent,
      child.traceparent,
    );
    expect(TraceContext.parse('00-${'0' * 32}-${'0' * 16}-01'), null);
    expect(TraceContext.parse('malformed'), null);
  });
  test(
    'bounded exporter flushes once and reports drop/failure explicitly',
    () async {
      final batches = <List<int>>[];
      final exporter = BoundedExporter<int>(
        (batch) async {
          batches.add(batch);
        },
        capacity: 2,
        batchSize: 1,
      );
      expect(exporter.add(1), true);
      expect(exporter.add(2), true);
      expect(exporter.add(3), false);
      expect(exporter.dropped, 1);
      await exporter.close();
      expect(batches, [
        [1],
        [2],
      ]);
      expect(exporter.pending, 0);
      expect(exporter.add(4), false);
      final failed = BoundedExporter<int>(
        (_) async => throw StateError('collector'),
        capacity: 1,
      );
      failed.add(1);
      await expectLater(failed.flush(), throwsStateError);
      expect(failed.dropped, 1);
      await failed.close();
    },
  );
}
