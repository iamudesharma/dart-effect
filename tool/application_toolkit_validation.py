#!/usr/bin/env python3
"""Validate application toolkit independently; never publishes or rewrites old evidence."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/application-toolkit'
PORTABLE = {'effect_schema', 'effect_config', 'effect_cache', 'effect_batch', 'effect_reactivity', 'effect_test', 'effect_ai', 'effect_observability'}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def command(args, cwd, name, tests=False, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=180)
    BUILD.joinpath(name + '.log').write_text(result.stdout + result.stderr)
    row = {'command': args, 'exit_code': result.returncode}
    if tests:
        events = []
        for line in result.stdout.splitlines():
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        done = [e for e in events if e.get('type') == 'testDone' and not e.get('hidden')]
        row['passed'] = sum(e.get('result') == 'success' and not e.get('skipped') for e in done)
        row['skipped'] = sum(bool(e.get('skipped')) for e in done)
        row['failed'] = sum(e.get('result') != 'success' and not e.get('skipped') for e in done)
    print(name, row, flush=True)
    if result.returncode or (tests and (not row['passed'] or row['failed'])):
        raise RuntimeError(f'{name} failed; inspect {BUILD / (name + ".log")}')
    return row


def fingerprints():
    paths=[Path(__file__), *ROOT.glob('lib/**/*.dart'), *ROOT.glob('test/**/*.dart'), *ROOT.glob('packages/*/lib/**/*.dart'), *ROOT.glob('packages/*/test/**/*.dart')]
    return {str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--browser', action='store_true')
    parser.add_argument('--sql', action='store_true')
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    report = {'started_at_utc': now(), 'success': False, 'packages': {}, 'sql_acceptance': 'not run'}
    initial_sources=fingerprints()
    try:
        packages = [('effect_core', ROOT)] + [(p.name, p) for p in sorted((ROOT / 'packages').iterdir()) if (p / 'pubspec.yaml').exists()]
        for name, cwd in packages:
            executable = 'flutter' if name == 'effect_flutter' else 'dart'
            checks = report['packages'][name] = {}
            checks['resolve'] = command([executable, 'pub', 'get', '--offline'], cwd, name + '-resolve')
            checks['analyze'] = command([executable, 'analyze'], cwd, name + '-analyze')
            checks['vm'] = command([executable, 'test', '-r', 'json'], cwd, name + '-vm', tests=True)
            if args.browser and (name in PORTABLE or name in {'effect_core', 'effect_sql', 'effect_http', 'effect_openai', 'effect_sql_schema'}):
                tests = ['test/client_test.dart', 'test/sdk_test.dart'] if name == 'effect_openai' else ['test/portable_test.dart'] if name == 'effect_http' else ['test/decoding_test.dart'] if name == 'effect_sql_schema' else []
                checks['chrome'] = command(['dart', 'test', '-p', 'chrome', *tests, '-r', 'json'], cwd, name + '-chrome', tests=True)
            if name == 'effect_core':
                checks['fixtures'] = command(['dart', 'run', 'tool/check_fixtures.dart'], cwd, 'core-fixtures')
                checks['web_compile'] = command(['dart', 'compile', 'js', 'example/web.dart', '-o', str(BUILD / 'web.js')], cwd, 'core-web-compile')
            # New self-contained examples only; existing credentialed examples
            # retain separate live-service acceptance requirements.
            if name in PORTABLE | {'effect_platform', 'effect_sqlite', 'effect_sql_schema', 'effect_http_server'}:
                source = cwd / 'example/main.dart'
                if source.exists():
                    cmd = ['dart', 'test', str(source)] if name == 'effect_test' else ['dart', 'run', str(source)]
                    checks['example'] = command(cmd, cwd, name + '-example')
        if args.sql:
            from remaining_performance import database
            from sql_tls_acceptance import certificates
            created = []
            try:
                with tempfile.TemporaryDirectory(prefix='effect-toolkit-sql-') as folder:
                    tls = Path(folder)
                    certificates(tls)
                    for db, package in [('postgres', 'effect_postgres'), ('mysql', 'effect_mysql')]:
                        mapped = database(db, tls, created)
                        env = os.environ.copy()
                        env['EFFECT_PG_PORT' if db == 'postgres' else 'EFFECT_MYSQL_PORT'] = mapped
                        if db == 'mysql':
                            env['EFFECT_MYSQL_CERT_PATH'] = str(tls / 'valid.pem')
                        report[db] = command(['dart', 'test', 'test/classification_test.dart', 'test/integration_test.dart', '-r', 'json'], ROOT / 'packages' / package, 'native-' + db, tests=True, env=env)
                        assert report[db]['skipped'] == 0
                report['sql_acceptance'] = 'passed selected native suites; TLS negative-chain suite not rerun'
            finally:
                report['cleanup'] = []
                for name in reversed(created):
                    result = subprocess.run(['docker', 'rm', '--force', '--volumes', name], capture_output=True, timeout=30)
                    report['cleanup'].append({'name': name, 'exit_code': result.returncode})
                assert all(item['exit_code'] == 0 for item in report['cleanup'])
        if fingerprints()!=initial_sources:
            raise RuntimeError('Sources changed during validation; rerun with stable inputs')
        report['success'] = True
    except BaseException:
        report['success']=False
        raise
    finally:
        report['finished_at_utc'] = now()
        report['source_sha256'] = fingerprints()
        (ROOT / 'docs/effect-port/application-toolkit-validation.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
