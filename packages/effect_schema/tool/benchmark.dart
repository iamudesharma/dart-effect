// Development only; excluded from the published archive.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:effect_schema/effect_schema.dart';

import '../../../tool/performance_memory.dart';

int sink = 0;
final schema = Schema.object({
  'id': Field(Schema.integer),
  'name': Field(Schema.string),
  'tags': Field(Schema.string.list()),
});
final valid = {
  'id': 42,
  'name': 'Ada',
  'tags': ['dart', 'api'],
};
final invalid = {
  'id': 'bad',
  'name': false,
  'tags': [1, 2],
};

void batch(String name, int count) {
  for (var i = 0; i < count; i++) {
    final Validation<Object?> result = switch (name) {
      'decode-valid' => schema.decode(valid),
      'decode-invalid' => schema.decode(invalid),
      'encode-valid' => schema.encode(valid),
      _ => throw ArgumentError(name),
    };
    sink += switch (result) {
      Valid() => 1,
      Invalid(:final error) => error.issues.length,
    };
  }
}

List<WeakReference<Object>> churn() {
  final refs = <WeakReference<Object>>[];
  for (var i = 0; i < 2000; i++) {
    final local = Schema.object({
      'id': Field(Schema.integer),
      'payload': Field(Schema.value<Uint8List>('object')),
    });
    final input = {'id': i, 'payload': Uint8List(4096)};
    final result = local.decode(input).orThrow;
    final failure = local.decode({'id': 'invalid'});
    if (i % 20 == 0) {
      refs.addAll([
        WeakReference(local),
        WeakReference(input),
        WeakReference(input['payload']!),
        WeakReference(result),
        WeakReference(failure),
      ]);
    }
  }
  return refs;
}

Future<void> main(List<String> args) async {
  final cycles = args.contains('--soak') ? 200 : 20;
  final report = <String, Object?>{
    'dart': Platform.version,
    'os': Platform.operatingSystem,
    'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
  };
  if (args.contains('--memory')) {
    final probe = await HeapProbe.connect();
    try {
      churn();
      await probe.snapshot();
      final snapshots = <Map<String, Object?>>[];
      var collected = 0;
      final strong = Uint8List(64);
      final control = WeakReference(strong);
      for (var cycle = 0; cycle < cycles; cycle++) {
        final refs = churn();
        snapshots.add(await probe.snapshot());
        final dead = refs.where((r) => r.target == null).length;
        check(
          dead == refs.length,
          'Schema/input/output/error retained: ${refs.length - dead}',
        );
        check(
          control.target != null && strong.length == 64,
          'Live control lost',
        );
        collected += dead;
      }
      report['memory'] = {
        ...memoryResult(snapshots, collected),
        'cycles': cycles,
        'operationsPerCycle': 2000,
        'referencesChecked': cycles * 500,
      };
    } finally {
      await probe.close();
    }
  } else {
    final results = <String, Object?>{};
    for (final name in ['decode-valid', 'decode-invalid', 'encode-valid']) {
      final first = Stopwatch()..start();
      batch(name, 1);
      first.stop();
      batch(name, 20000);
      final samples = <int>[];
      for (var sample = 0; sample < 9; sample++) {
        final watch = Stopwatch()..start();
        batch(name, 100000);
        watch.stop();
        samples.add(watch.elapsedMicroseconds);
      }
      results[name] = {
        'firstOperationUs': first.elapsedMicroseconds,
        'warmupOperations': 20000,
        'operationsPerSample': 100000,
        'samplesUs': samples,
      };
    }
    report['timing'] = results;
    report['sink'] = sink;
  }
  print(jsonEncode(report));
}
