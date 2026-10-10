#!/usr/bin/env python3
"""Fresh-process AOT timings plus separate Dart VM heap diagnostics."""
from pathlib import Path
import datetime
import hashlib
import json
import math
import platform
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'packages/effect_openai'
BINARY = ROOT / 'build/openai-performance'
OUTPUT = ROOT / 'docs/effect-port/openai-performance.json'
WORKLOADS = ['request-json', 'request-delayed', 'bounded-8', 'stream-fold',
             'failures', 'request-cancel', 'stream-early']


def call(args):
    result = subprocess.run(args, cwd=PACKAGE, text=True, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f'Benchmark failed: {args[1:]}\n{result.stderr}')
    return result.stdout


def result_json(output):
    return json.loads(next(line for line in reversed(output.splitlines()) if line.startswith('{')))


def main():
    ROOT.joinpath('build').mkdir(exist_ok=True)
    call(['dart', 'compile', 'exe', '-Dbenchmark.aot=true', 'tool/performance.dart', '-o', str(BINARY)])
    report = {'started_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'sdk': call(['dart', '--version']).strip(), 'host': platform.platform(),
              'architecture': platform.machine(), 'timing_mode': 'AOT',
              'method': '3 fresh processes per implementation/workload, alternating SDK/Effect order; 3 warmup and 9 measured batches per process; same local HTTP/SSE fixture and SDK config, retries disabled; setup/shutdown and GC excluded from timing. No live API or Flutter frame measurement.',
              'timing': {}, 'memory': {}, 'success': False}
    try:
        for workload in WORKLOADS:
            runs = {'sdk': [], 'effect': []}
            for repetition in range(3):
                for implementation in (['sdk', 'effect'] if repetition % 2 == 0 else ['effect', 'sdk']):
                    runs[implementation].append(result_json(call([str(BINARY), workload, implementation])))
            summary = {}
            for implementation, rows in runs.items():
                samples = [value for row in rows for value in row['samplesMicros']]
                ordered = sorted(samples)
                summary[implementation] = {'medianBatchMicros': statistics.median(samples),
                                           'p95BatchMicros': ordered[math.ceil(len(ordered) * .95) - 1],
                                           'processMedianMicros': [statistics.median(row['samplesMicros']) for row in rows],
                                           'raw': rows}
            summary['effectToSdkMedianRatio'] = summary['effect']['medianBatchMicros'] / summary['sdk']['medianBatchMicros']
            report['timing'][workload] = summary
            print(workload, {key: row['medianBatchMicros'] for key, row in summary.items() if isinstance(row, dict)}, flush=True)
        for implementation in ['sdk', 'effect']:
            # No service URI/token is saved: retain only the final JSON diagnostic.
            rows = []
            for _ in range(3):
                row = result_json(call(['dart', '--enable-vm-service=0', 'tool/performance.dart', 'memory', implementation]))
                snapshots = row['snapshots']
                row['postWarmupHeapUsedDeltaBytes'] = snapshots[-1]['heap']['heapUsage'] - snapshots[0]['heap']['heapUsage']
                row['postWarmupExternalDeltaBytes'] = snapshots[-1]['heap']['externalUsage'] - snapshots[0]['heap']['externalUsage']
                row['gcObserved'] = all(s['gcTimestamp'] is not None for s in snapshots) and len({s['gcTimestamp'] for s in snapshots}) == len(snapshots)
                # Deterministic ownership checks, not a universal RSS/no-leak promise.
                if not row['gcObserved']:
                    raise RuntimeError('Requested GC not observed: heap evidence is inconclusive')
                for snapshot in snapshots:
                    if snapshot['classes'].get('_Operation', {}).get('instances', 0):
                        raise RuntimeError('Adapter operation retained after completed batch')
                rows.append(row)
            report['memory'][implementation] = rows
            print('memory', implementation, 'passed', flush=True)
        report['success'] = True
    finally:
        sources = [Path(__file__), PACKAGE / 'tool/performance.dart',
                   *ROOT.glob('lib/**/*.dart'), *PACKAGE.glob('lib/**/*.dart'),
                   PACKAGE / 'pubspec.lock']
        report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)}
        report['finished_at_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        OUTPUT.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
