#!/usr/bin/env python3
"""Functional validation kept separate from performance timing and load totals."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile
from remaining_performance import ROOT, BUILD, database, now, run
from sql_tls_acceptance import IMAGES, certificates


def suite(command, cwd, env, name):
    result = subprocess.run(command + ['-r', 'json'], cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    BUILD.joinpath(name + '.jsonl').write_text(result.stdout)
    events = []
    for line in result.stdout.splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    done = [e for e in events if e.get('type') == 'testDone' and not e.get('hidden')]
    row = {'command': command, 'exit_code': result.returncode,
           'passed': sum(e.get('result') == 'success' and not e.get('skipped') for e in done),
           'skipped': sum(bool(e.get('skipped')) for e in done),
           'failed': sum(e.get('result') != 'success' and not e.get('skipped') for e in done)}
    if result.returncode or not row['passed'] or row['skipped'] or row['failed']:
        raise RuntimeError(f'{name} failed or skipped: {row}; inspect build/remaining-performance/{name}.jsonl')
    print(name, row, flush=True)
    return row


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    report = {'started_at_utc': now(), 'success': False, 'checks': [], 'suites': {}, 'examples': [], 'images': IMAGES, 'database_versions': {}}
    created = []
    try:
        for name, cwd in [('effect_core', ROOT), *[(name, ROOT / 'packages' / name) for name in ['effect_sql', 'effect_postgres', 'effect_mysql']]]:
            directories = [name for name in ['lib', 'test', 'example', 'tool'] if (cwd / name).is_dir()]
            for command in [['dart', 'format', '--output=none', '--set-exit-if-changed', *directories], ['dart', 'analyze']]:
                run(command, cwd, env)
                report['checks'].append({'package': name, 'command': command, 'exit_code': 0})
        report['suites']['core_vm'] = suite(['dart', 'test'], ROOT, env, 'core-vm')
        report['suites']['core_chrome'] = suite(['dart', 'test', '-p', 'chrome'], ROOT, env, 'core-chrome')
        run(['dart', 'run', 'tool/check_fixtures.dart'])
        report['checks'].append({'package': 'effect_core', 'command': ['dart', 'run', 'tool/check_fixtures.dart'], 'exit_code': 0})
        for source in sorted((ROOT / 'example').glob('*.dart')):
            run(['dart', 'run', str(source)], ROOT, env)
            report['examples'].append(str(source.relative_to(ROOT)))
        run(['dart', 'compile', 'js', 'example/web.dart', '-o', str(BUILD / 'web.js')])
        report['checks'].append({'command': ['dart', 'compile', 'js', 'example/web.dart'], 'exit_code': 0, 'scope': 'compilation only; Chrome suite separately verified'})
        package = ROOT / 'packages/effect_sql'
        report['suites']['sql_vm'] = suite(['dart', 'test', 'test/sql_test.dart'], package, env, 'sql-vm')
        report['suites']['sql_chrome'] = suite(['dart', 'test', 'test/sql_test.dart', '-p', 'chrome'], package, env, 'sql-chrome')
        with tempfile.TemporaryDirectory(prefix='effect-performance-validation-') as directory:
            tls = Path(directory)
            certificates(tls)
            for db in ['postgres', 'mysql']:
                mapped = database(db, tls, created)
                name = created[-1]
                package_name = 'effect_postgres' if db == 'postgres' else 'effect_mysql'
                package = ROOT / 'packages' / package_name
                if db == 'postgres':
                    env['EFFECT_PG_PORT'] = mapped
                    env.update({'PGHOST': '127.0.0.1', 'PGPORT': mapped, 'PGDATABASE': 'effect_test', 'PGUSER': 'postgres', 'PGPASSWORD': 'effect_test_password', 'PGSSLMODE': 'disable'})
                    report['database_versions'][db] = run(['docker', 'exec', name, 'postgres', '--version'])
                else:
                    env['EFFECT_MYSQL_PORT'] = mapped
                    env['EFFECT_MYSQL_CERT_PATH'] = str(tls / 'valid.pem')
                    env.update({'MYSQL_HOST': '127.0.0.1', 'MYSQL_PORT': mapped, 'MYSQL_DATABASE': 'effect_test', 'MYSQL_USER': 'root', 'MYSQL_PASSWORD': 'effect_test_password', 'MYSQL_CA': str(tls / 'root.pem')})
                    report['database_versions'][db] = run(['docker', 'exec', name, 'mysqld', '--version'])
                tests = [str(p.relative_to(package)) for p in sorted((package / 'test').glob('*test.dart')) if p.name != 'tls_acceptance_test.dart']
                report['suites'][package_name] = suite(['dart', 'test', *tests], package, env, package_name)
                run(['dart', 'run', 'example/main.dart'], package, env)
                report['examples'].append(str((package / 'example/main.dart').relative_to(ROOT)))
        report['success'] = True
    finally:
        report['cleanup'] = []
        for name in reversed(created):
            result = subprocess.run(['docker', 'rm', '--force', '--volumes', name], capture_output=True, timeout=30)
            report['cleanup'].append({'name': name, 'exit_code': result.returncode})
        report['containers_removed'] = all(r['exit_code'] == 0 for r in report['cleanup'])
        report['success'] = report['success'] and report['containers_removed']
        sources = [Path(__file__), ROOT / 'tool/remaining_performance.py', ROOT / 'tool/sql_tls_acceptance.py',
                   *ROOT.glob('lib/**/*.dart'), *ROOT.glob('test/**/*.dart'), *ROOT.glob('example/**/*.dart'),
                   *ROOT.glob('packages/effect_sql/lib/**/*.dart'), *ROOT.glob('packages/effect_sql/test/**/*.dart'),
                   *ROOT.glob('packages/effect_postgres/lib/**/*.dart'), *ROOT.glob('packages/effect_postgres/test/**/*.dart'), *ROOT.glob('packages/effect_postgres/example/**/*.dart'),
                   *ROOT.glob('packages/effect_mysql/lib/**/*.dart'), *ROOT.glob('packages/effect_mysql/test/**/*.dart'), *ROOT.glob('packages/effect_mysql/example/**/*.dart')]
        report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)}
        report['finished_at_utc'] = now()
        (ROOT / 'docs/effect-port/remaining-performance-validation.json').write_text(json.dumps(report, indent=2) + '\n')
    if not report['success']:
        raise RuntimeError('Validation or cleanup failed')


if __name__ == '__main__':
    main()
