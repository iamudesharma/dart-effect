#!/usr/bin/env python3
"""Run a generated, ignored macOS shell around the tracked Dart profile harness."""
from pathlib import Path
import datetime
import hashlib
import json
import platform
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'benchmarks/openai_flutter'
APP = ROOT / 'build/openai_flutter_profile'


def command(args, cwd=ROOT, timeout=180):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'Native profile command failed: {args}\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}')
    return result.stdout


def main():
    if platform.system() != 'Darwin':
        raise SystemExit('Native harness targets macOS; mobile/browser acceptance is separate.')
    report = {'started_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'flutter': command(['flutter', '--version']).strip(),
              'scope': 'Native macOS profile-mode minimal animation with loopback workloads, 3 SDK and 3 Effect runs, alternating order; no live API or mobile/web device proof.',
              'runs': {'sdk': [], 'effect': []}, 'success': False}
    try:
        command(['flutter', 'create', '--no-pub', '--platforms=macos', '--project-name=effect_openai_profile', str(APP)])
        (APP / 'lib/main.dart').write_bytes((SOURCE / 'lib/main.dart').read_bytes())
        (APP / 'lib/performance.dart').write_bytes((ROOT / 'packages/effect_openai/tool/performance.dart').read_bytes())
        (APP / 'pubspec.yaml').write_bytes((SOURCE / 'pubspec.yaml').read_bytes())
        for file in ['DebugProfile.entitlements', 'Release.entitlements']:
            path = APP / 'macos/Runner' / file
            entitlements = plistlib.loads(path.read_bytes())
            # Development-only generated harness writes evidence outside its container.
            entitlements['com.apple.security.app-sandbox'] = False
            entitlements['com.apple.security.network.client'] = True
            entitlements['com.apple.security.network.server'] = True
            path.write_bytes(plistlib.dumps(entitlements))
        command(['flutter', 'pub', 'get', '--offline'], APP)
        command(['flutter', 'analyze', 'lib'], APP)
        for repetition in range(3):
            for implementation in (['sdk', 'effect'] if repetition % 2 == 0 else ['effect', 'sdk']):
                output = ROOT / 'build' / f'flutter-{implementation}-{repetition}.json'
                output.unlink(missing_ok=True)
                command(['flutter', 'run', '--profile', '--no-dds', '--no-devtools', '-d', 'macos', '--no-pub',
                         f'--dart-define=PERF_IMPLEMENTATION={implementation}',
                         f'--dart-define=PERF_OUTPUT={output}'], APP)
                result = json.loads(output.read_text())
                if result.get('failed') or result['frames'] < 100 or result['openFixtureSockets']:
                    raise RuntimeError(f'Invalid Flutter profile result: {result}')
                report['runs'][implementation].append(result)
                print(implementation, repetition, 'frames', result['frames'],
                      'build p95 us', result['buildP95Micros'], flush=True)
        report['success'] = True
    finally:
        files = [Path(__file__), SOURCE / 'lib/main.dart', SOURCE / 'pubspec.yaml',
                 ROOT / 'packages/effect_openai/tool/performance.dart',
                 *ROOT.glob('lib/**/*.dart'), *ROOT.glob('packages/effect_openai/lib/**/*.dart')]
        report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
        report['finished_at_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (ROOT / 'docs/effect-port/openai-flutter-performance.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
