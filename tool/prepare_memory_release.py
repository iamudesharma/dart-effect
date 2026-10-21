#!/usr/bin/env python3
"""Stage the seven release archives outside ancestor ignore rules; never publish."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from verify_memory_publication import ROOT, VERSIONS


def main():
    directory = Path(tempfile.mkdtemp(prefix='effect-memory-release-'))
    report = {'staging_directory': str(directory), 'packages': {}}
    for name, version in VERSIONS.items():
        source = ROOT if name == 'effect_core' else ROOT/'packages'/name
        target = directory/name
        target.mkdir()
        for entry in ['lib', 'test', 'example', 'pubspec.yaml', 'README.md', 'CHANGELOG.md', 'LICENSE', 'analysis_options.yaml', '.pubignore']:
            origin = source/entry
            if origin.is_dir(): shutil.copytree(origin, target/entry)
            elif origin.is_file(): shutil.copy2(origin, target/entry)
        # Preflight against the exact candidate siblings before hosted publication.
        dependencies = [n for n in VERSIONS if f'  {n}:' in (source/'pubspec.yaml').read_text()]
        if dependencies:
            (target/'pubspec_overrides.yaml').write_text('dependency_overrides:\n'+''.join(f'  {n}:\n    path: {ROOT if n == "effect_core" else ROOT/"packages"/n}\n' for n in dependencies))
        # Root exclusion must also cover the temporary development overrides.
        with (target/'.pubignore').open('a') as f: f.write('\npubspec_overrides.yaml\npubspec.lock\n')
        report['packages'][name] = {'version': version, 'directory': str(target)}
    (ROOT/'build/release-staging.json').write_text(json.dumps(report, indent=2)+'\n')
    for name, data in report['packages'].items():
        result = subprocess.run(['dart','pub','publish','--dry-run'],cwd=data['directory'],text=True,capture_output=True,timeout=180)
        (ROOT/f'build/release-dry-run-{name}.log').write_text(result.stdout+result.stderr)
        if result.returncode: raise RuntimeError(f'{name} preflight failed; inspect build log')
        assert '0 warnings' in result.stdout
        print(name, 'candidate dry-run passed (local sibling overrides where needed)', flush=True)


if __name__ == '__main__':
    main()
