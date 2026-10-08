#!/usr/bin/env python3
"""Validate standalone release candidates; never publish or bypass validation."""
import datetime, json, pathlib, shutil, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = {'effect_core': ROOT, **{p.name: p for p in sorted((ROOT/'packages').iterdir()) if (p/'pubspec.yaml').exists()}}
OUT = ROOT/'build/release'
OUT.mkdir(parents=True, exist_ok=True)
records = []
with tempfile.TemporaryDirectory(prefix='effect-pub-dry-run-') as temporary:
    stage = pathlib.Path(temporary)
    for name, source in SOURCES.items():
        target = stage/name
        target.mkdir()
        for filename in ['pubspec.yaml', 'README.md', 'CHANGELOG.md', 'LICENSE', 'analysis_options.yaml', '.pubignore']:
            shutil.copyfile(source/filename, target/filename)
        for directory in ['lib', 'test', 'example', 'doc']:
            if (source/directory).exists():
                shutil.copytree(source/directory, target/directory)
        dependencies = [dep for dep in SOURCES if dep != name and f'  {dep}:' in (target/'pubspec.yaml').read_text()]
        if dependencies:
            (target/'pubspec_overrides.yaml').write_text('dependency_overrides:\n'+''.join(f'  {dep}:\n    path: ../{dep}\n' for dep in dependencies))
        (target/'.gitignore').write_text('.dart_tool/\nbuild/\npubspec.lock\npubspec_overrides.yaml\n')
        for args in [['git','init','--quiet'], ['git','add','.'], ['git','-c','user.name=Release Validation','-c','user.email=validation@example.invalid','commit','--quiet','-m','Standalone dry-run source']]:
            subprocess.run(args, cwd=target, check=True, capture_output=True)
    for name in SOURCES:
        target = stage/name
        record = {'package': name, 'version': '0.0.1', 'checks': {}}
        for label, args in [('resolution',['dart','pub','get','--offline']), ('analysis',['dart','analyze']), ('publish_dry_run',['dart','pub','publish','--dry-run'])]:
            result = subprocess.run(args, cwd=target, text=True, capture_output=True)
            log = result.stdout+result.stderr
            (OUT/f'{name}-standalone-{label}.log').write_text(log)
            record['checks'][label] = result.returncode
            if label == 'publish_dry_run':
                record['dependency_override_hint'] = 'Non-dev dependencies are overridden' in log
                record['zero_warnings'] = 'Package has 0 warnings' in log
                record['archive_has_required_files'] = all(f'── {filename} ' in log for filename in ['pubspec.yaml','LICENSE','README.md','CHANGELOG.md'])
            print(name, label, result.returncode, flush=True)
        records.append(record)
report = {'finished_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'packages': records, 'temporary_exports_removed': True, 'published': False}
(ROOT/'build/standalone-dry-runs.json').write_text(json.dumps(report, indent=2)+'\n')
if any(any(code != 0 for code in r['checks'].values()) or not r['zero_warnings'] or not r['archive_has_required_files'] for r in records):
    raise SystemExit('Standalone validation failed; inspect build/release logs.')
