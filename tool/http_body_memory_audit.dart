// Development-only retained-body audit; requires --enable-vm-service=0.
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

// Use --packages=packages/effect_http/.dart_tool/package_config.json when running.
// ignore: avoid_relative_lib_imports
import '../packages/effect_http/lib/effect_http.dart';
import 'performance_memory.dart';

Future<Map<String, Object?>> profile(HeapProbe probe) async {
  await Future<void>.delayed(const Duration(milliseconds: 30));
  final p = await probe.rpc('getAllocationProfile', {
    'isolateId': developer.Service.getIsolateId(Isolate.current),
    'gc': true,
  });
  return {'gc': p['dateLastServiceGC'], 'memory': p['memoryUsage']};
}

Future<Map<String, Object?>> sample(
  HeapProbe probe,
  int bytes,
  bool prototype,
) async {
  final body = Uint8List(bytes);
  final before = await profile(probe);
  final result = prototype
      ? Uint8List.fromList(body).asUnmodifiableView()
      : HttpResult(200, const {}, body).body;
  final after = await profile(probe);
  final added =
      ((after['memory'] as Map)['heapUsage'] as int) -
      ((before['memory'] as Map)['heapUsage'] as int);
  check(result.length == body.length && body.length == bytes, 'live controls');
  body[0] = 7;
  check(result[0] == 0, 'defensive copy aliases input');
  var immutable = false;
  try {
    result[0] = 1;
  } on UnsupportedError {
    immutable = true;
  }
  check(immutable, 'mutable response');
  return {
    'logicalBodyBytes': bytes,
    'constructorAddedDartHeapBytes': added,
    'responseBodyRuntimeType': result.runtimeType.toString(),
    'mode': prototype ? 'prototype-typed-defensive-copy' : 'current-HttpResult',
    'before': before,
    'after': after,
  };
}

Future<void> main() async {
  final probe = await HeapProbe.connect();
  try {
    await sample(probe, 65536, false);
    await sample(probe, 65536, true);
    final rows = <Object?>[];
    for (final bytes in [1024 * 1024, 4 * 1024 * 1024]) {
      rows.add(await sample(probe, bytes, false));
      rows.add(await sample(probe, bytes, true));
    }
    print(
      jsonEncode({
        'measurements': rows,
        'productionCodeModified': false,
        'note': 'Constructor-only retained heap after observed GC with typed input held as control. Small profiler noise remains. Request accumulation and UTF-8 decoding are additional costs. Prototype checks defensive copying and immutability but is not a production API change.',
      }),
    );
  } finally {
    await probe.close();
  }
}
