#!/usr/bin/env python3
"""Release checks without overwriting historical acceptance evidence."""
import hashlib
import json
import os
from pathlib import Path
from remaining_performance_validation import main as core_sql, suite
from remaining_performance import ROOT, BUILD, now, run


def main():
    historical = ROOT / 'docs/effect-port/remaining-performance-validation.json'
    retained = historical.read_bytes()
    report = {'started_at_utc': now(), 'success': False}
    try:
        try:
            core_sql()
            report = json.loads(historical.read_text())
        finally:
            historical.write_bytes(retained)
        report['scope'] = 'effect_core 0.0.2 / effect_http 0.0.1 release acceptance'
        env = os.environ.copy()
        for package in ['effect_http', 'effect_openai']:
            cwd = ROOT / 'packages' / package
            run(['dart', 'analyze'], cwd, env)
            report['checks'].append({'package': package, 'command': ['dart', 'analyze'], 'exit_code': 0})
            report['suites'][package + '_vm'] = suite(['dart', 'test'], cwd, env, package + '-release-vm')
            tests = ['test/portable_test.dart'] if package == 'effect_http' else ['test/client_test.dart', 'test/sdk_test.dart']
            report['suites'][package + '_chrome'] = suite(['dart', 'test', '-p', 'chrome', *tests], cwd, env, package + '-release-chrome')
        for path in [Path(__file__), ROOT / 'pubspec.yaml', *ROOT.glob('packages/*/pubspec.yaml'),
                     *ROOT.glob('packages/effect_http/lib/**/*.dart'), *ROOT.glob('packages/effect_http/test/**/*.dart'),
                     *ROOT.glob('packages/effect_http/example/**/*.dart'), *ROOT.glob('packages/effect_openai/lib/**/*.dart'),
                     *ROOT.glob('packages/effect_openai/test/**/*.dart')]:
            report['source_sha256'][str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
        report['success'] = True
    except Exception:
        report['success'] = False
        raise
    finally:
        report['finished_at_utc'] = now()
        (ROOT / 'docs/effect-port/release-0.0.2-validation.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
