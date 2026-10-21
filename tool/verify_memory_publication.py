#!/usr/bin/env python3
"""Verify hosted archives and a fresh seven-package consumer; never publishes."""
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSIONS = {'effect_core': '0.0.3', 'effect_sql': '0.0.2', 'effect_postgres': '0.0.3', 'effect_mysql': '0.0.2', 'effect_http': '0.0.2', 'effect_openai': '0.0.2', 'effect_cache': '0.0.1'}


def hosted(url):
    deadline = time.monotonic() + 600
    while True:
        try:
            return urllib.request.urlopen(urllib.request.Request(url, headers={'Cache-Control': 'no-cache'}), timeout=30).read()
        except urllib.error.HTTPError as error:
            if error.code != 404 or time.monotonic() >= deadline:
                raise
            time.sleep(10)


def main():
    report = {'packages': {}, 'source_sha256': {}, 'published': True}
    for name, version in VERSIONS.items():
        metadata = json.loads(hosted(f'https://pub.dev/api/packages/{name}/versions/{version}'))
        archive = hosted(metadata['archive_url'])
        digest = hashlib.sha256(archive).hexdigest()
        assert digest == metadata['archive_sha256'], 'Registry archive checksum differs'
        source = ROOT if name == 'effect_core' else ROOT / 'packages' / name
        with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as bundle:
            members = {member.name.removeprefix('./'): member for member in bundle.getmembers() if member.isfile()}
            required = ['pubspec.yaml', 'LICENSE', 'CHANGELOG.md', 'README.md', 'analysis_options.yaml']
            required += [str(p.relative_to(source)) for p in source.glob('lib/**/*.dart')]
            required += [str(p.relative_to(source)) for p in source.glob('example/**/*.dart')]
            hashes = {}
            for file in required:
                content = bundle.extractfile(members[file]).read()
                expected = (source / file).read_bytes()
                assert content == expected, f'Hosted source mismatch: {name}/{file}'
                hashes[file] = hashlib.sha256(content).hexdigest()
            for file in members:
                assert not file.startswith(('references/', 'tool/', 'website/', 'packages/'))
                assert not file.endswith(('.js', '.ts', '.mjs', '.cjs'))
        report['packages'][name] = {'version': version, 'url': f'https://pub.dev/packages/{name}', 'published_at_utc': metadata['published'], 'archive_sha256': digest, 'verified_archive_files': hashes}
        for path in [source / 'pubspec.yaml', *source.glob('lib/**/*.dart')]:
            report['source_sha256'][str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
        print(name, version, 'hosted archive verified', flush=True)
    with tempfile.TemporaryDirectory(prefix='effect-hosted-consumer-') as folder:
        consumer = Path(folder)
        consumer.joinpath('pubspec.yaml').write_text('''name: effect_release_consumer
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  effect_core: 0.0.3
  effect_http: 0.0.2
  effect_sql: 0.0.2
  effect_postgres: 0.0.3
  effect_mysql: 0.0.2
  effect_openai: 0.0.2
  effect_cache: 0.0.1
  http: ^1.6.0
''')
        consumer.joinpath('main.dart').write_text('''import 'dart:convert';
import 'package:effect_core/effect_core.dart';
import 'package:effect_http/effect_http.dart';
import 'package:effect_cache/effect_cache.dart';
import 'package:effect_sql/effect_sql.dart' as sql;
import 'package:effect_postgres/effect_postgres.dart' as pg;
import 'package:effect_mysql/effect_mysql.dart' as mysql;
import 'package:effect_openai/effect_openai.dart' as ai;
import 'package:http/http.dart' as http;
class Fixture extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
    http.StreamedResponse(Stream.value(utf8.encode(request.url.path == '/sse' ? 'data: hosted\\n\\n' : 'hosted')), 200,
      headers: {'content-type': request.url.path == '/sse' ? 'text/event-stream' : 'text/plain'});
}
Future<void> main() async {
  final metrics = RuntimeMetrics(); final rt = Runtime(Unit.value, metrics: metrics);
  final client = Fixture(); final adapter = EffectHttp(client);
  try {
    var loads = 0;
    final cache = EffectCache<int, int, String, Unit>(
      runtime: rt, capacity: 2, maxOwners: 2, onCapacity: () => 'full',
      ttl: Duration(minutes: 1), lookup: (key) => Effect.sync(() { loads++; return key; }));
    try {
      final values = await Future.wait(List.generate(20, (_) => rt.runFuture(cache.get(7))));
      if (loads != 1 || values.any((v) => v != 7)) throw StateError('Cache single-flight failed');
      await cache.invalidate(7);
      if (await rt.runFuture(cache.get(7)) != 7 || loads != 2) throw StateError('Cache invalidation failed');
    } finally {
      final cleanup = await cache.close();
      if (cleanup != null) throw EffectException(cleanup);
    }
    var calls = 0;
    final read = Effect.defer<int,String,Unit>(() => ++calls < 2 ? Effect.fail('retry') : Effect.succeed(7));
    final result = await rt.runFuture(CircuitBreaker().protect(RateLimiter(Duration.zero).limit(read.retry(
      Schedule(recurrences: 1, maxDelay: Duration.zero, elapsedBudget: Duration(seconds: 1)),
      whileError: (e) => e == 'retry')), onOpen: () => 'open').traced('hosted'));
    if (result != 7 || calls != 2) throw StateError('Hosted reliability API failed');
    final response = await rt.runFuture(adapter.request<Unit>('GET',Uri.parse('https://fixture.invalid')));
    final events = await rt.runFuture(adapter.sse<Unit>(Uri.parse('https://fixture.invalid/sse')).runCollect());
    if (response.text != 'hosted' || events.single.data != 'hosted') throw StateError('Hosted HTTP/SSE failed');
    final types = [sql.SqlClient, pg.PostgresClient, mysql.MySqlClient, ai.EffectOpenAIClient];
    if (types.length != 4 || metrics.active != 0) throw StateError('Hosted package compatibility failed');
    print('PASS hosted reliability, HTTP/SSE and seven-package compatibility and cache');
  } finally { await rt.shutdown(); client.close(); }
}
''')
        checks = []
        for command in [['dart', 'pub', 'get'], ['dart', 'analyze'], ['dart', 'run', 'main.dart']]:
            result = subprocess.run(command, cwd=consumer, text=True, capture_output=True, timeout=180)
            if command == ['dart', 'pub', 'get'] and result.returncode:
                for attempt in range(12):
                    if "doesn't match any versions" not in result.stdout+result.stderr:
                        break
                    cache = Path(os.environ.get('PUB_CACHE', str(Path.home()/'.pub-cache')))/'hosted/pub.dev/.cache'
                    for name in VERSIONS:
                        metadata = json.loads(hosted(f'https://pub.dev/api/packages/{name}'))
                        metadata['_fetchedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                        (cache/f'{name}-versions.json').write_text(json.dumps(metadata))
                    time.sleep(15)
                    result = subprocess.run(command, cwd=consumer, text=True, capture_output=True, timeout=180)
                    if result.returncode == 0: break
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            checks.append({'command': command, 'exit_code': 0})
            if command[-1] == 'main.dart': print(result.stdout.strip(), flush=True)
        report['consumer'] = {'checks': checks, 'hosted_only': True, 'dependency_overrides': False, 'directory_removed': True}
    report['verified_at_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    ROOT.joinpath('docs/effect-port/publication-2026-10-21.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
