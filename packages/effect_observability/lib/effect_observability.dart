/// Bounded application metrics and W3C trace context. No exporter dependencies.
library;

import 'dart:math';
import 'dart:async';
import 'dart:collection';

final class MetricRegistry {
  MetricRegistry({this.maxSeries = 1024}) {
    if (maxSeries < 1) throw ArgumentError.value(maxSeries);
  }
  final int maxSeries;
  final _series = <String, _Series>{};
  int get seriesCount => _series.length;
  _Series _get(
    String name,
    Map<String, String> labels,
    String type,
    List<double> bounds,
  ) {
    if (!RegExp(r'^[a-zA-Z_:][a-zA-Z0-9_:]*$').hasMatch(name)) {
      throw ArgumentError('Invalid metric name');
    }
    if (labels.keys.any(
      (s) => !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(s) || s == 'le',
    )) {
      throw ArgumentError('Invalid label');
    }
    final keys = labels.keys.toList()..sort();
    final normalized = {for (final key in keys) key: labels[key]!};
    final identity =
        '$name${normalized.entries.map((e) => '${e.key.length}:${e.key}${e.value.length}:${e.value}').join()}';
    final old = _series[identity];
    if (old != null) {
      if (old.type != type || old.bounds.toString() != bounds.toString()) {
        throw ArgumentError('Metric type conflict');
      }
      return old;
    }
    if (_series.length >= maxSeries) {
      throw StateError('Metric cardinality bound reached');
    }
    if (_series.values.any((s) => s.name == name && s.type != type)) {
      throw ArgumentError('Metric type conflict');
    }
    return _series[identity] = _Series(name, type, normalized, bounds);
  }

  void increment(
    String name, {
    double amount = 1,
    Map<String, String> labels = const {},
  }) {
    if (!amount.isFinite || amount < 0) throw ArgumentError.value(amount);
    _get(name, labels, 'counter', []).value += amount;
  }

  void gauge(
    String name,
    double value, {
    Map<String, String> labels = const {},
  }) {
    if (!value.isFinite) throw ArgumentError.value(value);
    _get(name, labels, 'gauge', []).value = value;
  }

  void observe(
    String name,
    double value, {
    List<double> buckets = const [.005, .01, .025, .05, .1, .25, .5, 1, 5],
    Map<String, String> labels = const {},
  }) {
    if (!value.isFinite ||
        buckets.any((n) => !n.isFinite) ||
        buckets.toSet().length != buckets.length) {
      throw ArgumentError('Invalid histogram');
    }
    for (var i = 1; i < buckets.length; i++) {
      if (buckets[i] <= buckets[i - 1]) {
        throw ArgumentError('Buckets must increase');
      }
    }
    final series = _get(name, labels, 'histogram', List.unmodifiable(buckets));
    series.value += value;
    series.count++;
    for (var i = 0; i < buckets.length; i++) {
      if (value <= buckets[i]) series.counts[i]++;
    }
  }

  String prometheus() {
    final out = StringBuffer();
    final declared = <String>{};
    for (final s in _series.values) {
      if (declared.add(s.name)) out.writeln('# TYPE ${s.name} ${s.type}');
      if (s.type == 'histogram') {
        for (var i = 0; i < s.bounds.length; i++) {
          out.writeln(
            '${s.name}_bucket${_labels({...s.labels, 'le': s.bounds[i].toString()})} ${s.counts[i]}',
          );
        }
        out.writeln(
          '${s.name}_bucket${_labels({...s.labels, 'le': '+Inf'})} ${s.count}',
        );
        out.writeln('${s.name}_sum${_labels(s.labels)} ${s.value}');
        out.writeln('${s.name}_count${_labels(s.labels)} ${s.count}');
      } else {
        out.writeln('${s.name}${_labels(s.labels)} ${s.value}');
      }
    }
    return out.toString();
  }
}

final class _Series {
  _Series(this.name, this.type, this.labels, this.bounds)
    : counts = List.filled(bounds.length, 0);
  final String name, type;
  final Map<String, String> labels;
  final List<double> bounds;
  final List<int> counts;
  double value = 0;
  int count = 0;
}

String _labels(Map<String, String> labels) => labels.isEmpty
    ? ''
    : '{${labels.entries.map((e) => '${e.key}="${e.value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', r'\n')}"').join(',')}}';

final class TraceContext {
  const TraceContext._(this.traceId, this.spanId, this.sampled);
  final String traceId, spanId;
  final bool sampled;
  String get traceparent => '00-$traceId-$spanId-${sampled ? '01' : '00'}';
  static TraceContext? parse(String? input) {
    if (input == null ||
        !RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$')
            .hasMatch(input)) {
      return null;
    }
    final parts = input.split('-');
    if (parts[1] == ('0' * 32) || parts[2] == ('0' * 16)) return null;
    return TraceContext._(
      parts[1],
      parts[2],
      int.parse(parts[3], radix: 16) & 1 == 1,
    );
  }

  static String _id(int bytes) => List.generate(
    bytes,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  static TraceContext root({bool sampled = true}) =>
      TraceContext._(_id(16), _id(8), sampled);
  TraceContext child() => TraceContext._(traceId, _id(8), sampled);
  Map<String, String> get headers => {'traceparent': traceparent};
}

/// Optional bounded push-export boundary. Export failures are surfaced to the
/// flushing caller; failed batches are dropped rather than silently replayed.
final class BoundedExporter<T> {
  BoundedExporter(this.send, {this.capacity = 1024, this.batchSize = 128}) {
    if (capacity < 1 || batchSize < 1) {
      throw ArgumentError('Invalid export bounds');
    }
  }
  final Future<void> Function(List<T>) send;
  final int capacity, batchSize;
  final _queue = Queue<T>();
  bool _closed = false;
  Future<void>? _flushing, _closing;
  int dropped = 0;
  int get pending => _queue.length;
  bool add(T record) {
    if (_closed || _queue.length >= capacity) {
      dropped++;
      return false;
    }
    _queue.add(record);
    return true;
  }

  Future<void> flush() {
    if (_flushing != null) return _flushing!;
    final done = Completer<void>();
    _flushing = done.future;
    Future<void>(() async {
      try {
        while (_queue.isNotEmpty) {
          final batch = <T>[];
          while (batch.length < batchSize && _queue.isNotEmpty) {
            batch.add(_queue.removeFirst());
          }
          try {
            await send(List.unmodifiable(batch));
          } catch (_) {
            dropped += batch.length;
            rethrow;
          }
        }
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _flushing = null;
      }
    });
    return done.future;
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    return _closing = flush();
  }
}
