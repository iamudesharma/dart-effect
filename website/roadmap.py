"""Shared roadmap rendering for the repository README and static website."""
from pathlib import Path
import json
import datetime
import sys

HERE = Path(__file__).resolve().parent
START = '<!-- roadmap:start -->'
END = '<!-- roadmap:end -->'
LABELS = {'completed': 'Delivered', 'active': 'In progress',
          'planned': 'Planned', 'awaiting-input': 'Awaiting input',
          'proposed': 'Proposed'}
PHASES = {'delivered': 'Delivered within scope', 'next': 'Next priorities',
          'later': 'Future proposals'}


def roadmap_date(goals):
    date = datetime.date.fromisoformat(max(g.get("updated_at", "2026-10-09") for g in goals))
    return f"{date.day} {date.strftime('%B %Y')}"


def readme_section(goals):
    counts = {status: sum(g['status'] == status for g in goals)
              for status in LABELS}
    rows = ['| Priority | Milestone | Status |', '| --- | --- | --- |']
    rows += [f"| {PHASES[g['phase']]} | {g['title']} | {LABELS[g['status']]} |"
             for g in goals]
    return '\n'.join([
        START, '## Roadmap and progress', '',
        f'**Roadmap updated: {roadmap_date(goals)}.** Six existing packages are published: '
        '`effect_core` and `effect_postgres` at `0.0.2`; `effect_sql`, `effect_mysql`, '
        '`effect_openai` and `effect_http` at `0.0.1`.', '',
        f"**{counts['completed']} delivered milestones · {counts['active']} in progress · "
        f"{counts['planned']} planned · {counts['awaiting-input']} awaiting input · "
        f"{counts['proposed']} future proposals.**", '',
        'Unpublished toolkit validation: 19 analyzers, 283 VM/Flutter tests and 226 Chrome tests. Thirteen new packages are 0.1.0-dev.1; core is 0.0.3-dev.1 and HTTP is 0.0.2-dev.1. These versions are not published. Historical release validation includes 230 VM and 184 browser tests, '
        'real PostgreSQL/MySQL acceptance, and separately dated two native live '
        'Responses smoke checks. Broader live AI, production database and native '
        'Flutter acceptance remain open.', '', *rows, '',
        'Next priorities are ordered above; production SQL acceptance is in progress. '
        'Trusted CA-chain and hostname checks passed for both drivers; recovery, network faults and soak remain open. Broader OpenAI acceptance needs an API-enabled test account. '
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
