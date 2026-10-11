#!/usr/bin/env python3
"""Offline fresh-process core, portable SQL, and native SQL performance evidence."""
from pathlib import Path
import datetime
import hashlib
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from sql_tls_acceptance import IMAGES, certificates

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/effect-port/remaining-performance.json'
BUILD = ROOT / 'build/remaining-performance'


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def run(args, cwd=ROOT, env=None, timeout=90):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0:3]} failed: {result.stderr[-3000:]}\n{result.stdout[-1500:]}')
    return result.stdout.strip()


def decode(text):
    return json.loads(next(line for line in reversed(text.splitlines()) if line.startswith('{')))


def compare(binary, source, cwd, workloads, env, modes=('AOT',)):
    result = {}
    for mode in modes:
        results = {}
        for workload in workloads:
            rows = {'direct': [], 'effect': []}
            for repetition in range(3):
                for implementation in (['direct', 'effect'] if repetition % 2 == 0 else ['effect', 'direct']):
                    command = [str(binary)] if mode == 'AOT' else ['dart', str(source)]
                    rows[implementation].append(decode(run(command + [workload, implementation], cwd, env)))
            summary = {}
            for implementation, runs in rows.items():
                samples = [s for row in runs for s in row['samplesMicros']]
                ordered = sorted(samples)
                summary[implementation] = {'medianBatchMicros': statistics.median(samples),
                                           'p95BatchMicros': ordered[math.ceil(len(ordered) * .95) - 1],
                                           'processMediansMicros': [statistics.median(row['samplesMicros']) for row in runs], 'raw': runs}
            summary['effectToDirectMedianRatio'] = summary['effect']['medianBatchMicros'] / summary['direct']['medianBatchMicros']
            results[workload] = summary
            print(mode, workload, round(summary['effectToDirectMedianRatio'], 3), flush=True)
        result[mode] = results
    return result


def memory(source, cwd, env):
    results = {}
    for implementation in ['direct', 'effect']:
        results[implementation] = []
        for repetition in range(3):
            row = decode(run(['dart', '--enable-vm-service=0', str(source), 'memory', implementation], cwd, env))
            results[implementation].append(row)
            print('memory', cwd.name, implementation, repetition + 1, row['heapUsedDeltaBytes'], flush=True)
    return results


def compile_tool(source, cwd, binary):
    run(['dart', 'compile', 'exe', '-Dbenchmark.aot=true', str(source), '-o', str(binary)], cwd)


def database(db, tls, created):
    port = 5432 if db == 'postgres' else 3306
    name = f'effect-perf-{db}-{uuid.uuid4().hex[:10]}'
    created.append(name)
    args = ['docker', 'run', '--detach', '--pull=never', '--name', name, '--label', 'effect.performance=true', '--publish', f'127.0.0.1::{port}', '--volume', f'{tls / "valid"}:/effect-tls:ro']
    options = {'POSTGRES_PASSWORD': 'effect_test_password', 'POSTGRES_DB': 'effect_test'} if db == 'postgres' else {'MYSQL_ROOT_PASSWORD': 'effect_test_password', 'MYSQL_DATABASE': 'effect_test'}
    for key, value in options.items():
        args += ['--env', f'{key}={value}']
    if db == 'postgres':
        args += ['--entrypoint', 'sh', IMAGES[db], '-c', 'cp /effect-tls/server-key.pem /tmp/effect-key.pem && chown postgres:postgres /tmp/effect-key.pem && chmod 600 /tmp/effect-key.pem && exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/effect-tls/server.pem -c ssl_key_file=/tmp/effect-key.pem']
    else:
        args += [IMAGES[db], '--require-secure-transport=ON', '--ssl-ca=/effect-tls/ca.pem', '--ssl-cert=/effect-tls/server.pem', '--ssl-key=/effect-tls/server-key.pem']
    run(args)
    mapped = run(['docker', 'port', name, f'{port}/tcp']).split(':')[-1]
    deadline = time.monotonic() + 90
    while True:
        health = ['pg_isready', '-h', '127.0.0.1', '-U', 'postgres'] if db == 'postgres' else ['mysqladmin', '-h', '127.0.0.1', 'ping', '--silent']
        if subprocess.run(['docker', 'exec', name, *health], capture_output=True, timeout=10).returncode == 0:
            break
        if time.monotonic() > deadline:
            raise TimeoutError('Database startup')
        time.sleep(1)
    return mapped


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    report = {'started_at_utc': now(), 'sdk': run(['dart', '--version']), 'host': platform.platform(), 'architecture': platform.machine(),
              'success': False, 'core': {}, 'sql': {}, 'images': IMAGES,
              'method': '3 fresh alternating direct/Effect processes per timing workload; 3 warmup +9 measured batches. SQL AOT with 8 prewarmed TLS connections; same prepared protocol, decoding, materialized immutable results. Direct SQL uses a development-only 8-connection worker pool, not a comparison of vendor pool APIs. Core JIT+AOT; heap runs separately with observed VM-service GC. No upstream refresh or live credentials.',
              'limits': 'Single local macOS arm64/Docker host and one version per database. Bounded 30-second per-process load, not a long production soak; no mobile UI, HA, proxy/network-partition or browser heap acceptance.'}
    created = []
    completed = set()
    previous = None
    if '--resume' in sys.argv:
        previous_bytes = OUT.read_bytes()
        previous = json.loads(previous_bytes)
        if not previous.get('containers_removed'):
            raise RuntimeError('Cannot resume without successful prior cleanup')
        for file, digest in previous['source_sha256'].items():
            if file == 'tool/remaining_performance.py':
                continue  # Orchestration/readiness repair only; measured Dart sources must match.
            if hashlib.sha256((ROOT / file).read_bytes()).hexdigest() != digest:
                raise RuntimeError(f'Cannot reuse stale measurements: {file}')
        report['resumed_from'] = {'report_sha256': hashlib.sha256(previous_bytes).hexdigest(),
                                  'started_at_utc': previous['started_at_utc'],
                                  'finished_at_utc': previous['finished_at_utc'],
                                  'orchestrator_sha256': previous['source_sha256']['tool/remaining_performance.py'],
                                  'reason': 'Temporary MySQL initialization listener was not authentication-ready; TCP readiness check corrected. Measured Dart sources unchanged.'}
        if previous.get('core', {}).get('timing') and previous['core'].get('memory'):
            report['core'] = previous['core']
            completed.add('core')
        for name, row in previous.get('sql', {}).items():
            keys = ['timing', 'memory'] if name == 'synthetic' else ['timing', 'memory', 'cancellation', 'load']
            if all(row.get(key) for key in keys):
                if name != 'synthetic' and not all(len(row['load'][key]) == 3 for key in ['direct', 'effect']):
                    continue
                report['sql'][name] = row
                completed.add(name)
        report['resumed_from']['reused_scopes'] = sorted(completed)
        print('Reusing unchanged completed scopes:', sorted(completed), flush=True)
    try:
        core_source = ROOT / 'tool/core_performance.dart'
        core_binary = BUILD / 'core'
        if 'core' not in completed:
            compile_tool(core_source, ROOT, core_binary)
            report['core']['timing'] = compare(core_binary, core_source, ROOT, ['chain-10000', 'chain-100000', 'bounded-8', 'stream-fold', 'resources', 'failures', 'cancel'], env, ('AOT', 'JIT'))
            report['core']['memory'] = memory(core_source, ROOT, env)
        package = ROOT / 'packages/effect_sql'
        source = package / 'tool/performance.dart'
        binary = BUILD / 'synthetic'
        if 'synthetic' not in completed:
            compile_tool(source, package, binary)
            report['sql']['synthetic'] = {'timing': compare(binary, source, package, ['serial', 'bounded-8', 'transactions', 'failures'], env), 'memory': memory(source, package, env)}
        run(['docker', 'info', '--format', '{{.ServerVersion}}'])
        for image in IMAGES.values():
            run(['docker', 'image', 'inspect', image])
        with tempfile.TemporaryDirectory(prefix='effect-performance-') as directory:
            tls = Path(directory)
            certificates(tls)
            env['EFFECT_BENCH_CA'] = str(tls / 'root.pem')
            for db in ['postgres', 'mysql']:
                if db in completed:
                    continue
                env['EFFECT_BENCH_' + ('PG' if db == 'postgres' else 'MYSQL') + '_PORT'] = database(db, tls, created)
                package = ROOT / 'packages' / ('effect_postgres' if db == 'postgres' else 'effect_mysql')
                source = package / 'tool/performance.dart'
                binary = BUILD / db
                compile_tool(source, package, binary)
                row = {'timing': compare(binary, source, package, ['serial', 'delayed', 'bounded-8', 'transactions', 'failures'], env)}
                report['sql'][db] = row
                row['memory'] = memory(source, package, env)
                row['cancellation'] = [decode(run([str(binary), 'cancellation', 'effect'], package, env)) for _ in range(3)]
                print('cancellation', db, 'passed', flush=True)
                row['load'] = {'direct': [], 'effect': []}
                for repetition in range(3):
                    for implementation in (['direct', 'effect'] if repetition % 2 == 0 else ['effect', 'direct']):
                        load = decode(run([str(binary), 'soak', implementation], package, env))
                        row['load'][implementation].append(load)
                        print('load', db, implementation, repetition + 1, load['completed'], 'operations', flush=True)
        report['success'] = True
    except BaseException as error:
        report['failure_type'] = type(error).__name__
        raise
    finally:
        report['cleanup'] = previous['cleanup'].copy() if previous else []
        for name in reversed(created):
            result = subprocess.run(['docker', 'rm', '--force', '--volumes', name], capture_output=True, timeout=30)
            report['cleanup'].append({'name': name, 'exit_code': result.returncode})
        report['containers_removed'] = all(r['exit_code'] == 0 for r in report['cleanup'])
        report['success'] = report['success'] and report['containers_removed']
        sources = [Path(__file__), ROOT / 'tool/sql_tls_acceptance.py', ROOT / 'tool/performance_memory.dart', ROOT / 'tool/core_performance.dart',
                   *ROOT.glob('lib/**/*.dart'), *ROOT.glob('packages/effect_sql/lib/**/*.dart'), *ROOT.glob('packages/effect_postgres/lib/**/*.dart'), *ROOT.glob('packages/effect_mysql/lib/**/*.dart'),
                   *ROOT.glob('packages/effect_sql/tool/*.dart'), *ROOT.glob('packages/effect_postgres/tool/*.dart'), *ROOT.glob('packages/effect_mysql/tool/*.dart'),
                   ROOT / 'pubspec.lock', *ROOT.glob('packages/effect_sql/pubspec.lock'), *ROOT.glob('packages/effect_postgres/pubspec.lock'), *ROOT.glob('packages/effect_mysql/pubspec.lock')]
        report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)}
        report['finished_at_utc'] = now()
        OUT.write_text(json.dumps(report, indent=2) + '\n')
    if not report['success']:
        raise RuntimeError('Benchmark or cleanup failed')


if __name__ == '__main__':
    main()
