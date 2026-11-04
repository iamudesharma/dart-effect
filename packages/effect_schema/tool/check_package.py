"""Verify an isolated publish candidate with hosted dependencies; never publish."""
from pathlib import Path
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='effect-schema-candidate-') as folder:
    candidate = Path(folder)
    for name in ('lib', 'test', 'example', 'README.md', 'CHANGELOG.md', 'LICENSE',
                 'pubspec.yaml', 'analysis_options.yaml', '.pubignore'):
        item = source / name
        if item.is_dir():
            shutil.copytree(item, candidate / name)
        else:
            shutil.copy2(item, candidate / name)
    for command in (
        ['dart', 'pub', 'get'], ['dart', 'analyze'], ['dart', 'test'],
        ['dart', 'run', 'example/main.dart'],
        ['dart', 'pub', 'publish', '--dry-run'],
    ):
        subprocess.run(command, cwd=candidate, check=True)
