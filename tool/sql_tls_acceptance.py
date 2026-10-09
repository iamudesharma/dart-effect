#!/usr/bin/env python3
"""Offline, isolated trusted-CA acceptance. Never imports the legacy SQL runner."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGES = {
    'postgres': 'postgres@sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73',
    'mysql': 'mysql@sha256:6ea90827b1100f8f2ae306a539f86d2c264a26ed435a2a9f75551dd5c3aeb242',
}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def call(args):
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=60).stdout.strip()


def certificates(directory):
    def req(name, subject, self_signed=False):
        args = ['openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-subj', subject,
                '-keyout', str(directory / f'{name}-key.pem')]
        if self_signed:
            args += ['-x509', '-days', '2']
        call(args + ['-out', str(directory / f'{name}.pem' if self_signed else directory / f'{name}.csr')])

    def sign(name, issuer, extension):
        ext = directory / f'{name}.ext'
        ext.write_text(extension)
        call(['openssl', 'x509', '-req', '-in', str(directory / f'{name}.csr'),
              '-CA', str(directory / f'{issuer}.pem'), '-CAkey', str(directory / f'{issuer}-key.pem'),
              '-CAcreateserial', '-days', '2', '-extfile', str(ext), '-out', str(directory / f'{name}.pem')])

    req('root', '/CN=Effect isolated root CA', True)
    req('wrong-root', '/CN=Effect unrelated root CA', True)
    req('intermediate', '/CN=Effect isolated intermediate CA')
    sign('intermediate', 'root', 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n')
    for name, san in [('valid', 'DNS:localhost,IP:127.0.0.1'), ('wrong-host', 'DNS:wrong.invalid')]:
        req(name, '/CN=Effect isolated server')
        sign(name, 'intermediate', f'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName={san}\n')
        folder = directory / name
        folder.mkdir()
        (folder / 'server.pem').write_text((directory / f'{name}.pem').read_text() + (directory / 'intermediate.pem').read_text())
        (folder / 'server-key.pem').write_bytes((directory / f'{name}-key.pem').read_bytes())
        (folder / 'ca.pem').write_bytes((directory / 'root.pem').read_bytes())
        # Fixture-only material in a temporary directory; PG copies to owner-only mode.
        for path in folder.iterdir():
            path.chmod(0o644)


def main():
    report = {'started_at_utc': now(), 'images': IMAGES, 'suites': {},
              'scope': 'Isolated root/intermediate CA chains, unrelated-root and hostname rejection; not production infrastructure acceptance.',
              'success': False}
    created = []
    output = ROOT / 'docs/effect-port/sql-tls-validation.json'
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    try:
        call(['docker', 'info', '--format', '{{.ServerVersion}}'])
        for image in IMAGES.values():
            call(['docker', 'image', 'inspect', image])  # No automatic pull/network refresh.
        with tempfile.TemporaryDirectory(prefix='effect-sql-tls-') as temporary:
            tls = Path(temporary)
            certificates(tls)
            env = os.environ.copy()
            env['EFFECT_SQL_TLS_CA'] = str(tls / 'root.pem')
            env['EFFECT_SQL_TLS_WRONG_CA'] = str(tls / 'wrong-root.pem')
            token = uuid.uuid4().hex[:10]
            for db, port in [('postgres', 5432), ('mysql', 3306)]:
                for fixture in ['valid', 'wrong-host']:
                    name = f'effect-tls-{db}-{fixture}-{token}'
                    args = ['docker', 'run', '--detach', '--pull=never', '--name', name,
                            '--label', 'effect.sql.tls.test=true', '--publish', f'127.0.0.1::{port}',
                            '--volume', f'{tls / fixture}:/effect-tls:ro']
                    options = {'POSTGRES_PASSWORD': 'effect_test_password', 'POSTGRES_DB': 'effect_test'} if db == 'postgres' else {'MYSQL_ROOT_PASSWORD': 'effect_test_password', 'MYSQL_DATABASE': 'effect_test'}
                    for key, value in options.items():
                        args += ['--env', f'{key}={value}']
                    if db == 'postgres':
                        args += ['--entrypoint', 'sh', IMAGES[db], '-c',
                                 'cp /effect-tls/server-key.pem /tmp/effect-key.pem && chown postgres:postgres /tmp/effect-key.pem && chmod 600 /tmp/effect-key.pem && exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/effect-tls/server.pem -c ssl_key_file=/tmp/effect-key.pem']
                    else:
                        args += [IMAGES[db], '--require-secure-transport=ON', '--ssl-ca=/effect-tls/ca.pem',
                                 '--ssl-cert=/effect-tls/server.pem', '--ssl-key=/effect-tls/server-key.pem']
                    # Own the unique name before launching so partial startup is also cleaned.
                    created.append(name)
                    call(args)
                    mapped = call(['docker', 'port', name, f'{port}/tcp']).split(':')[-1]
                    prefix = 'PG' if db == 'postgres' else 'MYSQL'
                    env[f'EFFECT_{prefix}_TLS_' + ('PORT' if fixture == 'valid' else 'WRONG_HOST_PORT')] = mapped
                    deadline = time.monotonic() + 90
                    while True:
                        health = ['pg_isready', '-U', 'postgres'] if db == 'postgres' else ['mysqladmin', 'ping', '--silent']
                        if subprocess.run(['docker', 'exec', name, *health], capture_output=True, timeout=10).returncode == 0:
                            break
                        if time.monotonic() >= deadline:
                            raise TimeoutError(f'{db}/{fixture} readiness exceeded 90 seconds')
                        time.sleep(1)
                    print(f'{db}/{fixture} ready', flush=True)
            for package in ['effect_postgres', 'effect_mysql']:
                result = subprocess.run(['dart', 'test', 'test/tls_acceptance_test.dart', '-r', 'json'],
                                        cwd=ROOT / 'packages' / package, env=env, text=True,
                                        capture_output=True, timeout=90)
                (build / f'{package}-tls.jsonl').write_text(result.stdout)
                events = []
                for line in result.stdout.splitlines():
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
                ends = [e for e in events if e.get('type') == 'testDone' and not e.get('hidden')]
                suite = {'exit_code': result.returncode, 'passed': sum(e.get('result') == 'success' and not e.get('skipped') for e in ends),
                         'skipped': sum(bool(e.get('skipped')) for e in ends),
                         'failed': sum(e.get('result') != 'success' and not e.get('skipped') for e in ends)}
                report['suites'][package] = suite
                print(package, suite, flush=True)
                if result.returncode or suite['passed'] != 3 or suite['skipped'] or suite['failed']:
                    raise RuntimeError(f'{package} TLS acceptance failed: inspect build/{package}-tls.jsonl')
            report['success'] = True
    except BaseException as error:
        report['failure_type'] = type(error).__name__
        raise
    finally:
        report['cleanup'] = []
        for name in reversed(created):
            result = subprocess.run(['docker', 'rm', '--force', '--volumes', name], capture_output=True, timeout=30)
            report['cleanup'].append({'name': name, 'exit_code': result.returncode})
        report['containers_removed'] = all(entry['exit_code'] == 0 for entry in report['cleanup'])
        report['success'] = report['success'] and report['containers_removed']
        sources = [Path(__file__), *ROOT.glob('packages/effect_*/test/tls_acceptance_test.dart'),
                   *ROOT.glob('lib/**/*.dart'), *ROOT.glob('packages/effect_*/lib/**/*.dart')]
        report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)}
        report['finished_at_utc'] = now()
        output.write_text(json.dumps(report, indent=2) + '\n')
    if not report['success']:
        raise RuntimeError('TLS acceptance cleanup failed')


if __name__ == '__main__':
    main()
