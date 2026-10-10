// Development-only VM-service diagnostics. No runtime dependency or saved token.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

final class HeapProbe {
  HeapProbe._(this.socket) {
    socket.listen((message) {
      final value = jsonDecode(message as String) as Map<String, dynamic>;
      final waiter = pending.remove(value['id']);
      if (value.containsKey('error')) {
        waiter?.completeError(StateError('VM service RPC failed'));
      } else {
        waiter?.complete(value['result'] as Map<String, dynamic>);
      }
    });
  }
  final WebSocket socket;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  int next = 0;
  String? lastGC;
  static Future<HeapProbe> connect() async {
    final info = await developer.Service.getInfo();
    final uri = info.serverUri;
    if (uri == null) throw StateError('Run with --enable-vm-service=0');
    return HeapProbe._(
      await WebSocket.connect(
        uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
      ),
    );
  }

  Future<Map<String, dynamic>> rpc(String method, Map<String, Object?> params) {
    final id = ++next;
    final waiter = Completer<Map<String, dynamic>>();
    pending[id] = waiter;
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return waiter.future.timeout(const Duration(seconds: 10));
  }

  Future<Map<String, Object?>> snapshot() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final profile = await rpc('getAllocationProfile', {
      'isolateId': developer.Service.getIsolateId(Isolate.current),
      'gc': true,
    });
    final stamp = profile['dateLastServiceGC']?.toString();
    check(stamp != null && stamp != lastGC, 'Requested GC not observed');
    lastGC = stamp;
    final classes = <String, Object?>{};
    for (final entry in profile['members'] as List) {
      final cls = entry['class'] as Map;
      final name = cls['name'] as String;
      if ([
        'Fiber',
        'FiberContext',
        'Scope',
        'SqlSession',
        'SqlClient',
        'Runtime',
        '_Connection',
        '_CountedConnection',
      ].contains(name)) {
        // Duplicate private class names from different libraries must not overwrite.
        final key = '$name:${cls['id']}';
        classes[key] = {
          'name': name,
          'instances': entry['instancesCurrent'],
          'bytes': entry['bytesCurrent'],
        };
        if (['Fiber', 'FiberContext', 'Scope', 'SqlSession'].contains(name)) {
          check(
            entry['instancesCurrent'] == 0,
            '$name retained at idle checkpoint',
          );
        }
      }
    }
    return {
      'heap': profile['memoryUsage'],
      'gcTimestamp': stamp,
      'classes': classes,
      'rssBytes': ProcessInfo.currentRss,
    };
  }

  Future<void> close() => socket.close();
}

Map<String, Object?> memoryResult(
  List<Map<String, Object?>> snapshots,
  int collected,
) {
  final first = snapshots.first['heap'] as Map;
  final last = snapshots.last['heap'] as Map;
  return {
    'snapshots': snapshots,
    'collectedWeakReferences': collected,
    'heapUsedDeltaBytes':
        (last['heapUsage'] as int) - (first['heapUsage'] as int),
    'externalDeltaBytes':
        (last['externalUsage'] as int) - (first['externalUsage'] as int),
    'note': 'Requested and observed GC; RSS includes VM/JIT/profiler. Bounded reachability evidence, not universal leak freedom.',
  };
}
