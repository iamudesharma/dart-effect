"""Shared roadmap rendering for the repository README and static website."""
from pathlib import Path
import json
import sys

HERE = Path(__file__).resolve().parent
START = '<!-- roadmap:start -->'
END = '<!-- roadmap:end -->'
LABELS = {'completed': 'Delivered', 'active': 'In progress',
          'planned': 'Planned', 'awaiting-input': 'Awaiting input',
          'proposed': 'Proposed'}
PHASES = {'delivered': 'Released', 'next': 'Next priorities',
          'later': 'Future proposals'}


def readme_section(goals):
    counts = {status: sum(g['status'] == status for g in goals)
              for status in LABELS}
    rows = ['| Priority | Milestone | Status |', '| --- | --- | --- |']
    rows += [f"| {PHASES[g['phase']]} | {g['title']} | {LABELS[g['status']]} |"
             for g in goals]
    return '\n'.join([
        START, '## Roadmap and progress', '',
        '**Roadmap updated: 9 October 2026.** All five packages are published: '
        '`effect_core`, `effect_sql`, `effect_mysql` and `effect_openai` at '
        '`0.0.1`; `effect_postgres` at `0.0.2`.', '',
        f"**{counts['completed']} delivered milestones · {counts['active']} in progress · "
        f"{counts['planned']} planned · {counts['awaiting-input']} awaiting input · "
        f"{counts['proposed']} future proposals.**", '',
        'Recorded validation includes 207 VM and 167 browser tests across dated '
        'package runs, real PostgreSQL/MySQL acceptance and two native live '
        'Responses smoke checks. Broader live AI, production database and native '
        'Flutter acceptance remain open.', '', *rows, '',
        'Next priorities are ordered above; work has not started on those '
        'milestones. Broader OpenAI acceptance needs an API-enabled test account. '
        'Future proposals need API design and scope agreement before implementation; '
        'they have no promised release version or date.', '',
        'Follow the [detailed roadmap](https://effect-dart.ginjustice4.chatgpt.site/roadmap/) '
        'for prerequisites and completion criteria, '
        '[verified progress](https://effect-dart.ginjustice4.chatgpt.site/progress/) '
        'for evidence, and the [feature matrix](docs/effect-port/feature-matrix.md) '
        'for operation-level support. Delivered means the documented scope is '
        'implemented and verified, not full Effect-TS parity or universal production acceptance.',
        END])


if __name__ == '__main__':
    goals = json.loads((HERE / 'content/goals.json').read_text())
    path = HERE.parent / 'README.md'
    text = path.read_text()
    section = readme_section(goals)
    if '--write' in sys.argv:
        if START in text:
            text = text[:text.index(START)] + section + text[text.index(END) + len(END):]
        else:
            text = text.replace('## Local development', section + '\n\n## Local development')
        path.write_text(text)
    elif section not in text:
        raise SystemExit('README roadmap is stale: run python3 website/roadmap.py --write')
