import 'dart:io';

import 'package:effect_platform/effect_platform.dart';
import 'package:effect_config/effect_config.dart';
import 'package:effect_core/effect_core.dart';
import 'package:test/test.dart';

int calculate() => 40 + 2;
int fail() => throw StateError('worker failure');
int spin() {
  while (true) {
    /* Intentionally terminated by isolate kill. */
  }
}

void main() {
  test(
    'environment and JSON providers preserve typed invalid supplied config',
    () async {
      expect(
        Config.port('APP.PORT')
            .load(environmentConfig(environment: {'APP_PORT': '8080'})),
        8080,
      );
      final dir = await Directory.systemTemp.createTemp('effect-config-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/config.json');
      await file.writeAsString('{"database":{"port":5432}}');
      expect(
        Config.port('database.port').load(await jsonFileConfig(file)),
        5432,
      );
    },
  );
  test(
    'isolate success and failure propagate without keeping message ports alive',
    () async {
      final rt = Runtime(Unit.value);
      addTearDown(rt.shutdown);
      expect(
        await rt.runFuture(
          isolateTask<int, String, Unit>(
            calculate,
            onError: (e, _) => e.toString(),
          ),
        ),
        42,
      );
      final failed = await rt.runExit(
        isolateTask<int, String, Unit>(fail, onError: (e, _) => e.toString()),
      );
      expect((failed as Failure<int, String>).cause, isA<Expected<String>>());
    },
  );
  test(
    'cancellation terminates CPU worker and runtime can shut down',
    () async {
      final rt = Runtime(Unit.value);
      final fiber = rt.fork(
        isolateTask<int, String, Unit>(spin, onError: (e, _) => e.toString()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        await fiber.interruptAndAwait().timeout(const Duration(seconds: 2)),
        isA<Failure<int, String>>(),
      );
      await rt.shutdown();
    },
  );
}
