// Native profile harness, never a live API credential or shipping application.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'performance.dart' as bench;

void main() => runApp(const MaterialApp(home: ProfileHarness()));

class ProfileHarness extends StatefulWidget {
  const ProfileHarness({super.key});
  @override
  State<ProfileHarness> createState() => _ProfileHarnessState();
}

class _ProfileHarnessState extends State<ProfileHarness>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation;
  final frames = <FrameTiming>[];
  String status = 'Warming up';
  bool recording = false;

  @override
  void initState() {
    super.initState();
    animation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    WidgetsBinding.instance.addTimingsCallback(onFrames);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(run()));
  }

  void onFrames(List<FrameTiming> values) {
    if (recording) frames.addAll(values);
  }

  Future<void> run() async {
    const implementation = String.fromEnvironment(
      'PERF_IMPLEMENTATION',
      defaultValue: 'effect',
    );
    const output = String.fromEnvironment('PERF_OUTPUT');
    final fixture = bench.Fixture();
    await fixture.start();
    final work = bench.Work(fixture, implementation == 'effect');
    bench.Profile? profile;
    try {
      for (final mode in ['request-json', 'stream-fold', 'failures']) {
        await work.batch(mode);
      }
      final info = await developer.Service.getInfo();
      if (info.serverUri != null) {
        final uri = info.serverUri!.replace(
          scheme: 'ws',
          path: '${info.serverUri!.path}ws',
        );
        profile = bench.Profile(await WebSocket.connect(uri.toString()));
      }
      final before = await profile?.snapshot();
      // No GC/VM service calls while recording frames.
      final timer = Stopwatch()..start();
      recording = true;
      var batches = 0;
      while (timer.elapsed < const Duration(seconds: 6)) {
        for (final mode in [
          'request-delayed',
          'bounded-8',
          'stream-fold',
          'failures',
          'request-cancel',
          'stream-early',
        ]) {
          if (mounted) setState(() => status = mode);
          await work.batch(mode);
          batches++;
        }
      }
      // Let engine delivery settle while the animation is still running.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      recording = false;
      animation.stop();
      final after = await profile?.snapshot();
      final sortedBuild =
          frames.map((f) => f.buildDuration.inMicroseconds).toList()..sort();
      final sortedRaster =
          frames.map((f) => f.rasterDuration.inMicroseconds).toList()..sort();
      bench.check(frames.length >= 100, 'Insufficient real profile frames');
      final p95Index = (frames.length * .95).ceil() - 1;
      final report = {
        'implementation': implementation,
        'mode': 'Flutter native profile',
        'platform': Platform.operatingSystem,
        'frames': frames.length,
        'durationMicros': timer.elapsedMicroseconds,
        'batches': batches,
        'buildP95Micros': sortedBuild[p95Index],
        'rasterP95Micros': sortedRaster[p95Index],
        'buildOver16_67ms': frames
            .where((f) => f.buildDuration.inMicroseconds > 16667)
            .length,
        'rasterOver16_67ms': frames
            .where((f) => f.rasterDuration.inMicroseconds > 16667)
            .length,
        'beforeHeap': before,
        'afterHeap': after,
        'requests': fixture.calls,
        'openFixtureSockets': fixture.sockets.length,
        'note': 'Minimal animated macOS UI with same loopback workload; descriptive 60 Hz stage threshold, not a real application/device frame guarantee. GC outside frame timing.',
      };
      await File(output).writeAsString(jsonEncode(report));
      await work.dispose();
      await fixture.dispose();
      await profile?.socket.close();
      exit(0);
    } catch (error, stack) {
      await File(output).writeAsString(
        jsonEncode({'failed': true, 'error': '$error', 'stack': '$stack'}),
      );
      await work.dispose();
      await fixture.dispose();
      await profile?.socket.close();
      exit(1);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(onFrames);
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RotationTransition(
              turns: animation,
              child: const Icon(Icons.sync, size: 48),
            ),
            const SizedBox(height: 24),
            const Text(
              'Effect OpenAI · native profile',
              style: TextStyle(fontSize: 24),
            ),
            const SizedBox(height: 12),
            Text(status),
            const SizedBox(height: 12),
            const Text('Local fixtures only · no API credentials'),
          ],
        ),
      ),
    ),
  );
}
