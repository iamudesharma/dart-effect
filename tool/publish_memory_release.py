#!/usr/bin/env python3
"""Explicitly authorized release only; requires fresh acceptance and staged archives."""
import datetime
import hashlib
import json
import os
import time
from pathlib import Path
import subprocess
from verify_memory_publication import ROOT, VERSIONS, hosted


def main():
    evidence = json.loads((ROOT/'docs/effect-port/release-2026-10-21-validation.json').read_text())
    tls = json.loads((ROOT/'docs/effect-port/release-2026-10-21-tls.json').read_text())
    cache = json.loads((ROOT/'build/cache-release-validation.json').read_text())
    assert evidence['success'] and tls['success'] and cache['success']
    assert evidence['live_sql']['containers_removed'] and tls['containers_removed']
    for file, digest in evidence['source_sha256'].items():
        assert hashlib.sha256((ROOT/file).read_bytes()).hexdigest() == digest, file
    staged = json.loads((ROOT/'build/release-staging.json').read_text())['packages']
    journal_path = ROOT/'build/release-publication-journal.json'
    journal = json.loads(journal_path.read_text()) if journal_path.exists() else {}
    for name, version in VERSIONS.items():
        if name in journal:
            assert journal[name]['version'] == version
            print(name, 'already published in this release journal', flush=True)
            continue
        target = Path(staged[name]['directory'])
        source = ROOT if name == 'effect_core' else ROOT/'packages'/name
        # Refuse to publish staged content different from validated source.
        for file in target.rglob('*'):
            if file.is_file() and (file.suffix=='.dart' or file.name in ['pubspec.yaml','README.md','LICENSE','CHANGELOG.md','analysis_options.yaml']):
                assert file.read_bytes() == (source/file.relative_to(target)).read_bytes(), str(file)
        (target/'pubspec_overrides.yaml').unlink(missing_ok=True)
        (target/'pubspec.lock').unlink(missing_ok=True)
        for label, command in [('resolve',['dart','pub','get']), ('analyze',['dart','analyze','--fatal-infos']), ('dry-run',['dart','pub','publish','--dry-run']), ('publish',['dart','pub','publish','--force'])]:
            print(name, version, label, flush=True)
            result = subprocess.run(command, cwd=target, capture_output=True, text=True, timeout=180)
            if label == 'resolve' and result.returncode and "doesn't match any versions" in result.stdout+result.stderr:
                for attempt in range(8):
                    # Refresh only stale version-list metadata from the real registry for published siblings.
                    cache_root = Path(os.environ.get('PUB_CACHE', str(Path.home()/'.pub-cache')))
                    for sibling in journal:
                        metadata_path = cache_root/'hosted/pub.dev/.cache'/f'{sibling}-versions.json'
                        fresh = json.loads(hosted(f'https://pub.dev/api/packages/{sibling}'))
                        if any(v['version'] == journal[sibling]['version'] for v in fresh['versions']):
                            fresh['_fetchedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                            metadata_path.write_text(json.dumps(fresh))
                    time.sleep(15)
                    result = subprocess.run(command, cwd=target, capture_output=True, text=True, timeout=180)
                    if not result.returncode: break
            (ROOT/f'build/release-{label}-{name}.log').write_text(result.stdout+result.stderr)
            if result.returncode: raise RuntimeError(f'{name} {label} failed; inspect private build log')
            if label == 'dry-run': assert '0 warnings' in result.stdout
        metadata = json.loads(hosted(f'https://pub.dev/api/packages/{name}/versions/{version}'))
        assert metadata['version']==version
        journal[name]={'version':version, 'published':metadata['published'], 'archive_sha256':metadata['archive_sha256'], 'checked_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
        journal_path.write_text(json.dumps(journal,indent=2)+'\n')
        print(name, version, 'publication confirmed by registry', flush=True)


if __name__ == '__main__':
    main()
