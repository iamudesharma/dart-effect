#!/usr/bin/env python3
"""Build a portable static site from versioned documentation and test evidence."""
from pathlib import Path
import datetime, hashlib, html, json, re, shutil
from roadmap import LABELS, PHASES, readme_section

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / 'dist'
GITHUB = 'https://github.com/iamudesharma/dart-effect'
SOURCE = GITHUB + '/blob/dart-effect/'
REPORTS = ['rename-validation.json', 'sql-validation.json', 'openai-validation.json', 'openai-live-validation.json', 'release-0.0.1-validation.json', 'publication-0.0.1.json', 'postgres-pub-score.json', 'sql-tls-validation.json']
releases = json.loads((HERE / 'content/releases.json').read_text())
for file, digest in releases['source_sha256'].items():
    if hashlib.sha256((ROOT / file).read_bytes()).hexdigest() != digest:
        raise SystemExit(f'Published runtime source changed: {file}; verify the release snapshot before building.')
reports = {name: json.loads((ROOT / 'docs/effect-port' / name).read_text()) for name in REPORTS}
for name, report in reports.items():
    for file, digest in report.get('source_sha256', {}).items():
        current = hashlib.sha256((ROOT / file).read_bytes()).hexdigest()
        if current != digest:
            exception = releases['historical_source_exceptions'].get(file, {})
            if current != exception.get('current_sha256') or digest not in exception.get('previous_sha256', []):
                raise SystemExit(f'Stale validation evidence: {name}: {file}; run the relevant checks before building.')
release = reports['release-0.0.1-validation.json']
core = {name: release['suites'][name]['passed'] for name in ['core_vm', 'core_chrome', 'sql_chrome']}
ai = {name: release['suites'][name]['passed'] for name in ['openai_vm', 'openai_chrome']}
sql = {name: release['suites'][name] for name in ['effect_sql', 'effect_postgres', 'effect_mysql']}
sql['effect_postgres'] = reports['postgres-pub-score.json']['postgres_acceptance']['tests']
assert reports['sql-validation.json']['containers_removed']
assert all(v['exit_code'] == 0 and v['failed'] == 0 and v['skipped'] == 0 for v in sql.values())
recorded = max(datetime.datetime.fromisoformat(report.get('verified_at_utc', report.get('finished_at_utc'))) for report in reports.values())
recorded_date = f'{recorded.day} {recorded.strftime("%B %Y")}'
vm = core['core_vm'] + ai['openai_vm'] + sum(v['passed'] for v in sql.values())
chrome = core['core_chrome'] + core['sql_chrome'] + ai['openai_chrome']
goals = json.loads((HERE / 'content/goals.json').read_text())
allowed = set(LABELS)
assert readme_section(goals) in (ROOT / 'README.md').read_text(), 'Run python3 website/roadmap.py --write'
assert all(g['phase'] in PHASES for g in goals)
assert all(g.get('dependency') and g.get('acceptance') for g in goals if g['status'] != 'completed')
assert len({g['id'] for g in goals}) == len(goals) and all(g['status'] in allowed for g in goals)
packages = [
    {'name': 'effect_core', 'slug': 'effect-core', 'icon': 'E', 'text': 'Lazy effects, typed failures and structured concurrency. The foundation for every service.', 'platform': 'VM + web', 'vm': core['core_vm'], 'chrome': core['core_chrome'], 'doc': ROOT/'README.md'},
    {'name': 'effect_sql', 'slug': 'effect-sql', 'icon': 'SQL', 'text': 'Shared connection lifetimes, exclusive transactions and nested savepoints.', 'platform': 'Portable contracts', 'vm': sql['effect_sql']['passed'], 'chrome': core['sql_chrome'], 'doc': ROOT/'packages/effect_sql/README.md'},
    {'name': 'effect_postgres', 'slug': 'effect-postgres', 'icon': 'PG', 'text': 'PostgreSQL and PG through the established postgres Dart driver.', 'platform': 'Native server', 'vm': sql['effect_postgres']['passed'], 'chrome': None, 'doc': ROOT/'packages/effect_postgres/README.md'},
    {'name': 'effect_mysql', 'slug': 'effect-mysql', 'icon': 'MY', 'text': 'MySQL with prepared binding, scoped connections and explicit TLS behavior.', 'platform': 'Native server', 'vm': sql['effect_mysql']['passed'], 'chrome': None, 'doc': ROOT/'packages/effect_mysql/README.md'},
    {'name': 'effect_openai', 'slug': 'effect-openai', 'icon': 'AI', 'text': 'Typed OpenAI requests, Responses and Chat streams, cancellation and scoped clients.', 'platform': 'VM + web', 'vm': ai['openai_vm'], 'chrome': ai['openai_chrome'], 'doc': ROOT/'packages/effect_openai/README.md'},
]
for package in packages:
    package.update(releases['packages'][package['name']])

docs = [
    ('getting-started', 'Getting started', HERE/'content/getting-started.md'),
    ('runtime', 'Runtime & types', ROOT/'docs/effect-port/architecture.md'),
    ('features', 'Supported features', ROOT/'docs/effect-port/feature-matrix.md'),
    ('testing', 'Testing & conformance', ROOT/'docs/effect-port/testing.md'),
    ('acceptance-plan', 'Sequential acceptance plan', ROOT/'docs/effect-port/acceptance-plan.md'),
    ('sql', 'Database integrations', ROOT/'docs/effect-port/sql-adapters.md'),
    ('openai', 'OpenAI integration', ROOT/'docs/effect-port/openai-adapter.md'),
]
ROUTES = {p.resolve(): '/docs/'+slug+'/' for slug, _, p in docs}
ROUTES.update({p['doc'].resolve(): '/packages/'+p['slug']+'/' for p in packages})
ROUTES[(ROOT/'README.md').resolve()] = '/docs/getting-started/'
ROUTES[(ROOT/'docs/effect-port/progress.md').resolve()] = '/progress/'
ROUTES[(ROOT/'docs/effect-port/rename-validation.json').resolve()] = '/evidence/rename-validation.json'
ROUTES[(ROOT/'docs/effect-port/sql-validation.json').resolve()] = '/evidence/sql-validation.json'
ROUTES[(ROOT/'docs/effect-port/openai-validation.json').resolve()] = '/evidence/openai-validation.json'
for name in REPORTS:
    ROUTES[(ROOT/'docs/effect-port'/name).resolve()] = '/evidence/'+name

def esc(value): return html.escape(str(value), quote=True)
def link_url(url, file):
    if url.startswith(('https://', 'http://', 'mailto:', '#', '/')): return url
    target, _, fragment = url.partition('#')
    local = (file.parent/target).resolve()
    if ROOT/'references' in local.parents: return None
    result = ROUTES.get(local)
    if result is None:
        try: result = SOURCE + str(local.relative_to(ROOT))
        except ValueError: return None
    return result + ('#'+fragment if fragment else '')

def inline(text, file):
    tokens = []
    def store(value):
        tokens.append(value)
        return f'\x00{len(tokens)-1}\x00'
    text = re.sub(r'`([^`]+)`', lambda m: store('<code>'+esc(m[1])+'</code>'), text)
    def make_link(m):
        url = link_url(m[2], file)
        label = esc(m[1])
        return store(f'<a href="{esc(url)}">{label}</a>' if url else label)
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', make_link, text)
    text = esc(text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', text)
    for i in reversed(range(len(tokens))): text = text.replace(f'\x00{i}\x00', tokens[i])
    return text

def highlight(code):
    pattern = r'//[^\n]*|(?:r)?\'(?:\\.|[^\'\\])*\'|"(?:\\.|[^"\\])*"|\b(?:final|const|await|async|return|if|try|finally|import|void|case|switch)\b|\b(?:Effect|Runtime|Unit|Success|Failure|Context|Layer|OpenAIClient|EffectOpenAIClient|ServiceKey)\b'
    result = []; previous = 0
    for m in re.finditer(pattern, code):
        result.append(esc(code[previous:m.start()]))
        token = m[0]
        kind = 'comment' if token.startswith('//') else 'string' if token.startswith(('\'', '"', "r'")) else 'type' if token[0].isupper() else 'keyword'
        result.append(f'<span class="code-{kind}">{esc(token)}</span>'); previous=m.end()
    result.append(esc(code[previous:])); return ''.join(result)

def markdown(file):
    lines = file.read_text().splitlines(); result=[]; i=0; counts={}
    while i<len(lines):
        line=lines[i]
        if not line.strip(): i+=1; continue
        if line.startswith('```'):
            language=line[3:]; block=[]; i+=1
            while i<len(lines) and not lines[i].startswith('```'): block.append(lines[i]); i+=1
            code='\n'.join(block)
            result.append('<pre><code>'+ (highlight(code) if language=='dart' else esc(code)) +'</code></pre>'); i+=1;continue
        if re.match(r'^#{1,3} ',line):
            level=len(line)-len(line.lstrip('#')); text=line[level+1:]
            slug=re.sub('[^a-z0-9]+','-',text.lower()).strip('-'); counts[slug]=counts.get(slug,0)+1
            if counts[slug]>1: slug+=f'-{counts[slug]}'
            result.append(f'<h{level} id="{slug}">'+inline(text,file)+f'</h{level}>');i+=1;continue
        if line.startswith('|') and i+1<len(lines) and re.match(r'^\|[ :\- |]+\|$',lines[i+1]):
            def row(text, tag): return '<tr>'+''.join('<'+tag+'>'+inline(c.strip(),file)+'</'+tag+'>' for c in text.strip('|').split('|'))+'</tr>'
            table='<thead>'+row(line,'th')+'</thead><tbody>';i+=2
            while i<len(lines) and lines[i].startswith('|'): table+=row(lines[i],'td');i+=1
            result.append('<div class="table-scroll"><table>'+table+'</tbody></table></div>');continue
        if re.match(r'^[-*] ',line):
            block='<ul>'
            while i<len(lines) and re.match(r'^[-*] ',lines[i]): block+='<li>'+inline(lines[i][2:],file)+'</li>';i+=1
            result.append(block+'</ul>');continue
        para=[line];i+=1
        while i<len(lines) and lines[i].strip() and not re.match(r'^(#{1,3} |```|\||[-*] )',lines[i]): para.append(lines[i]);i+=1
        result.append('<p>'+inline(' '.join(para),file)+'</p>')
    return '\n'.join(result)

logo='<svg viewBox="0 0 30 32" aria-hidden="true"><path d="M6 4h20L22 10H2zm0 11h17l-4 6H2zm0 11h10l-4 6H2z" fill="currentColor"/></svg>'
nav_items=[('Docs','/docs/getting-started/'),('Packages','/packages/'),('Progress','/progress/'),('Roadmap','/roadmap/')]
search_index=[{'title': label, 'url': '/docs/'+slug+'/', 'description': 'Documentation · '+label, 'text': file.read_text()} for slug,label,file in docs]
search_index += [{'title':p['name'],'url':'/packages/'+p['slug']+'/', 'description':p['text'],'text':p['doc'].read_text()} for p in packages]
search_index += [{'title':'Progress & verification','url':'/progress/','description':'Recorded tests, evidence and acceptance boundaries','text':'test VM browser validation evidence PostgreSQL MySQL OpenAI'}, {'title':'Roadmap & goals','url':'/roadmap/','description':'Delivered work, planned milestones and acceptance gates','text':json.dumps(goals)}]
script='''
const dialog = document.querySelector('#search-dialog');
const input = document.querySelector('#search-input');
const results = document.querySelector('#search-results');
const index = JSON.parse(document.querySelector('#search-index').textContent);
function renderSearch() {
  const query = input.value.toLowerCase().trim();
  const score = p => p.title.toLowerCase().includes(query) ? 2 : p.description.toLowerCase().includes(query) ? 1 : 0;
  const matches = index.filter(p => !query || (p.title+' '+p.text).toLowerCase().includes(query)).sort((a,b)=>score(b)-score(a)).slice(0,10);
  results.replaceChildren();
  for (const page of matches) {
    const a = document.createElement('a'); a.href=page.url;
    const title=document.createElement('strong'); title.textContent=page.title;
    const description=document.createElement('span'); description.textContent=page.description;
    a.append(title,description); results.append(a);
  }
  if (!matches.length) { const p=document.createElement('p'); p.className='empty'; p.textContent='No matching guide. Try “resources”, “SQL” or “OpenAI”.'; results.append(p); }
}
document.querySelectorAll('[data-search]').forEach(b=>b.addEventListener('click',()=>{dialog.showModal();renderSearch();input.focus();}));
document.querySelector('#search-close').addEventListener('click',()=>dialog.close());
input.addEventListener('input',renderSearch);
document.addEventListener('keydown',e=>{if((e.metaKey||e.ctrlKey)&&e.key==='k'){e.preventDefault();if(dialog.open){dialog.close();}else{dialog.showModal();renderSearch();input.focus();}}});
dialog.addEventListener('click',e=>{if(e.target===dialog){const r=dialog.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)dialog.close();}});
document.querySelectorAll('[data-goal-filter]').forEach(button=>button.addEventListener('click',()=>{
  const filter=button.dataset.goalFilter; let count=0;
  document.querySelectorAll('[data-goal-filter]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));
  document.querySelectorAll('[data-goal]').forEach(g=>{g.hidden=filter!=='all'&&g.dataset.goal!==filter;if(!g.hidden)count++;});
  document.querySelectorAll('[data-goal-group]').forEach(group=>{group.hidden=![...group.querySelectorAll('[data-goal]')].some(g=>!g.hidden);});
  document.querySelector('#goals-empty').hidden=count!==0;
  document.querySelector('#goal-count').textContent=count+' '+(count===1?'goal':'goals')+' shown';
}));
'''

def page(route, title, body, active=''):
    def nav(): return ''.join(f'<a href="{url}"'+(' aria-current="page"' if active==label else '')+f'>{label}</a>' for label,url in nav_items)
    search_json=json.dumps(search_index,ensure_ascii=False).replace('<','\\u003c')
    text=f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="Effect Dart: lazy typed effects, Dart package guides, verified progress and project roadmap."><meta name="theme-color" content="#101112"><title>{esc(title)} · Effect Dart</title><link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/styles.css"></head><body><a class="skip" href="#main">Skip to content</a><header class="header"><div class="wrap head-inner"><a class="brand" href="/" aria-label="Effect Dart home">{logo}Effect <em>Dart</em></a><nav class="nav" aria-label="Primary">{nav()}</nav><div class="head-right"><button class="search-button" data-search aria-haspopup="dialog"><span>Search docs</span><kbd>⌘ K</kbd></button><a class="github" href="{GITHUB}">GitHub</a><details class="mobile-nav"><summary>Menu</summary><div>{nav()}<a href="{GITHUB}">GitHub</a></div></details></div></div></header><main id="main">{body}</main><footer class="footer"><div class="wrap footer-inner"><div><a class="brand" href="/">{logo}Effect <em>Dart</em></a><p>Independent. Effect-inspired. Built for Dart.<br>Development source · MIT · Not affiliated with Effect-TS.</p></div><div class="footer-links"><a href="/docs/getting-started/">Documentation</a><a href="/progress/">Verification</a><a href="{GITHUB}">Source</a><a href="https://effect.website">Effect-TS</a></div></div></footer><dialog class="search-dialog" id="search-dialog" aria-labelledby="search-label"><div class="search-head"><label id="search-label" class="skip" for="search-input">Search documentation</label><input id="search-input" type="search" placeholder="Search documentation…" aria-label="Search documentation"><button id="search-close" aria-label="Close search">Esc</button></div><div class="search-results" id="search-results" aria-live="polite"></div><div class="search-hint">Search package guides and documentation. Escape closes search.</div></dialog><script type="application/json" id="search-index">{search_json}</script><script>{script}</script></body></html>'''
    target=OUT/route.lstrip('/')/'index.html';target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text)

def stats():return f'<div class="stats"><div class="stat"><strong>5</strong><span>Published packages</span></div><div class="stat"><strong>{vm}</strong><span>Recorded VM tests</span></div><div class="stat"><strong>{chrome}</strong><span>Recorded browser tests</span></div><div class="stat"><strong>0</strong><span>Core runtime dependencies</span></div></div>'
def cards(featured=False):
    content=''
    for i,p in enumerate(packages):
        cls='package-card featured' if featured and i==0 else 'package-card'
        main=f'<div><div class="package-icon">{p["icon"]}</div><h3>{p["name"]}</h3><p>{p["text"]}</p><div class="card-bottom"><span>v{p["version"]} · {p["vm"]} VM tests recorded</span><span class="platform">{p["platform"]}</span></div></div>'
        extra='<div class="mini-code"><span class="code-type">Effect</span>&lt;A, E, R&gt;<br><span class="code-comment">// value · failure · environment</span><br><br>lazy · reusable · scoped</div>' if featured and i==0 else ''
        content+=f'<a class="{cls}" href="/packages/{p["slug"]}/">{main}{extra}</a>'
    return '<div class="package-grid">'+content+'</div>'
def release_table():
    rows = ''.join(f'<tr><td><a href="/packages/{p["slug"]}/">{p["name"]}</a></td><td><code>{p["version"]}</code></td><td><a href="{p["url"]}">View on pub.dev</a></td></tr>' for p in packages)
    return '<div class="table-scroll"><table><thead><tr><th>Package</th><th>Latest release</th><th>Registry</th></tr></thead><tbody>'+rows+'</tbody></table></div>'

def top(title,description,label):return f'<div class="wrap page-top"><p class="eyebrow">{label}</p><h1>{title}</h1><p class="lead">{description}</p></div>'

snippet='''final runtime = Runtime(Unit.value);

final program = Effect.sync<int, String, Unit>(
  () => 21,
).flatMap((n) => Effect.succeed(n * 2));

try {
  final value = await runtime.runFuture(program);
  print(value); // 42
} finally {
  await runtime.shutdown();
}'''
hero=f'''<div class="announcement"><span>NOW ON PUB.DEV</span>Five published packages. One Dart runtime. <a href="/progress/">See what’s verified.</a></div><div class="wrap"><section class="hero"><div><p class="eyebrow">Effect-inspired. Dart-native.</p><h1>Build reliable<br><span class="muted">Dart APIs.</span></h1><p class="lead">Make async work predictable. Compose typed failures, scoped resources and services in one lazy runtime.</p><div class="actions"><a class="button primary" href="/docs/getting-started/">Get started</a><a class="button" href="/progress/">Explore progress</a></div><p class="small">Dart ≥3.13 · Core v{packages[0]["version"]} · Available on pub.dev</p></div><div class="terminal"><div class="terminal-top"><span class="file">hello_effect.dart</span><span>CORE RUNTIME</span></div><pre><code>{highlight(snippet)}</code></pre><div class="terminal-footer"><span class="dot"></span>Lazy until run. Cleanup before return.</div></div></section><section class="section"><div class="section-header"><div><span class="label">The project today</span><h2>Progress you can inspect.</h2></div><p>Recorded checks from {recorded_date}.<br>Evidence follows the code, not a completion percentage.</p></div>{stats()}<p class="small">Counts combine dated release and patch validation runs. Local OpenAI transport and two native live Responses streams are verified; broader live acceptance remains open.</p></section><section class="section"><div class="section-header"><div><span class="label">One foundation, focused integrations</span><h2>Pick the service you need.</h2></div><a class="button" href="/packages/">All packages</a></div>{cards(True)}</section><section class="section split"><div><span class="label">A small mental model</span><h2>Values. Failures. Requirements.</h2><div class="type-signature">Effect&lt;<b>A</b>, <b>E</b>, <b>R</b>&gt;</div><div class="definitions"><div><h3>A · Value</h3><p>What the computation returns.</p></div><div><h3>E · Failure</h3><p>Its expected error family.</p></div><div><h3>R · Environment</h3><p>The services it requires.</p></div></div><div class="scope-note">Dart covariance means R is not a complete static proof of service provision. Typed selectors and runtime checks keep the boundary explicit.</div></div><div><div class="milestone"><span class="number">01</span><div><h3>Describe the work</h3><p>Construct a lazy effect. Compose without starting I/O.</p></div></div><div class="milestone"><span class="number">02</span><div><h3>Provide the lifetime</h3><p>Use scoped resources and layers to own your services.</p></div></div><div class="milestone"><span class="number">03</span><div><h3>Run and observe</h3><p>Inspect Success or Failure after child work and cleanup finish.</p></div></div></div></section><section class="section"><div class="section-header"><div><span class="label">What’s next</span><h2>A roadmap with honest boundaries.</h2></div><a class="button" href="/roadmap/">View goals</a></div><div class="two-cards"><div class="info-card"><span class="badge">Verified smoke check</span><h3>Live OpenAI Responses</h3><p>Two native live streams passed through ChatGPT plan access, including Unicode and terminal completion. Broader endpoint acceptance awaits an API-enabled test account.</p></div><div class="info-card"><span class="badge">SQL acceptance in progress</span><h3>Next: service acceptance and examples</h3><p>Trusted SQL CA-chain checks passed. Connection-loss recovery is next; runnable API/Flutter guides remain planned. Configuration, schemas, cache, stream operators and observability are future proposals.</p><a class="text-link" href="/roadmap/">Prerequisites and completion criteria</a></div></div></section></div>'''
page('/', 'Reliable Dart APIs',hero)
page('/packages/', 'Packages',top('One runtime. Focused packages.','Use core on its own, then add the database or AI integration your application needs. Each package has an explicit platform and acceptance boundary.','The ecosystem')+'<div class="wrap page-body">'+cards()+ release_table()+ '<div class="scope-note"><strong>Install from pub.dev.</strong> Start with core and add only the integrations you need. PostgreSQL 0.0.2 has a <a href="https://pub.dev/packages/effect_postgres/score">verified 160/160 score</a>; package score is separate from production acceptance.</div></div>','Packages')
rows=''.join(f'<tr><td><a href="/packages/{p["slug"]}/">{p["name"]}</a></td><td>{p["vm"]}</td><td>{p["chrome"] if p["chrome"] is not None else "Native only"}</td><td><span class="badge">Recorded passing</span></td><td>{p["platform"]}</td></tr>' for p in packages)
progress=top('Progress, backed by evidence.','The five packages are implemented within their documented scope. These are recorded checks against the current source, not a claim of complete Effect-TS parity.','Project status')+f'''<div class="wrap page-body">{stats()}<p class="small">Latest recorded evidence: {recorded_date}. Published runtime hashes matched at site build; documented historical metadata changes are recorded in the release snapshot. Totals combine package-specific runs; tests were not all run in one suite.</p><section class="section"><div class="section-header"><div><span class="label">Verification by package</span><h2>What actually passed.</h2></div></div><div class="table-scroll"><table class="evidence-table"><thead><tr><th>Package</th><th>VM tests</th><th>Chrome tests</th><th>Status</th><th>Platform</th></tr></thead><tbody>{rows}</tbody></table></div><div class="two-cards"><div class="info-card"><h3>Database acceptance</h3><p>Real PostgreSQL and MySQL driver suites passed with no skips, against isolated pinned database containers. Test containers were removed.</p><a class="button" href="/evidence/sql-validation.json">View database evidence</a></div><div class="info-card"><h3>OpenAI transport & live smoke acceptance</h3><p>Eight loopback HTTP/SSE tests and portable Chrome checks passed. Two native live Responses streams also passed with Unicode, terminal completion and awaited cleanup. This is a recorded manual smoke check, separate from the unit-test totals.</p><a class="button" href="/evidence/openai-live-validation.json">View live evidence</a><a class="button" href="/evidence/openai-validation.json">View local evidence</a></div></div></section><section class="section"><div class="section-header"><div><span class="label">The remaining boundary</span><h2>Implemented isn’t the same as production-accepted.</h2></div></div><div class="two-cards"><div class="info-card"><h3>Verified locally</h3><ul><li>Lazy reuse, typed failures and structured cleanup</li><li>Real database transactions and cancellation contracts</li><li>Actual SDK HTTP requests and SSE parsing</li><li>Two native live Responses streams with text and Unicode</li><li>Core type fixtures and runnable examples</li><li>Clean Git checkout builds without Node/npm references</li></ul></div><div class="info-card"><h3>Still needs acceptance</h3><ul><li>Other OpenAI endpoints and live failure scenarios</li><li>Production CA chains, failover and long network partitions</li><li>Load/soak and database version matrices</li><li>Live browser API transport</li><li>Native Flutter/device acceptance</li></ul></div></div><div class="actions"><a class="button" href="/roadmap/">Next milestones</a><a class="button" href="/evidence/rename-validation.json">Core & SQL evidence</a></div></section></div>'''
progress = progress.replace('<section class="section">', '<section class="section"><div class="section-header"><div><span class="label">Published releases</span><h2>Available on pub.dev.</h2></div></div>'+release_table()+'<p>All five initial releases are published. PostgreSQL 0.0.2 adds API documentation and earns <a href="https://pub.dev/packages/effect_postgres/score">160/160 pub points</a>. Registry score is separate from real service acceptance.</p><div class="actions"><a class="button" href="/evidence/publication-0.0.1.json">Publication evidence</a><a class="button" href="/evidence/postgres-pub-score.json">PostgreSQL patch evidence</a></div></section><section class="section">', 1)
tls=reports['sql-tls-validation.json']
assert tls['success'] and tls['containers_removed']
assert all(s['passed']==3 and s['skipped']==0 and s['failed']==0 and s['exit_code']==0 for s in tls['suites'].values())
progress += '<section class="wrap section"><span class="label">Next-priority acceptance</span><h2>Trusted SQL CA chains: first task delivered.</h2><p>Three real PostgreSQL and three real MySQL TLS checks passed with no skips: root/intermediate trust, unrelated-root rejection and hostname mismatch. Four owned containers were removed. These six checks are separate from the dated release totals above; failover, partitions, soak and production-provider acceptance remain open.</p><a class="button" href="/docs/acceptance-plan/">Ordered tasks and completion criteria</a><a class="button" href="/evidence/sql-tls-validation.json">TLS acceptance evidence</a></section>'
page('/progress/','Progress',progress,'Progress')
status_labels={key:(label, 'planned' if key in {'planned','proposed'} else 'pending' if key=='awaiting-input' else '') for key,label in LABELS.items()}
goal_html=''
for phase,heading in PHASES.items():
    articles=''
    for goal in (g for g in goals if g['phase']==phase):
        label,cls=status_labels[goal['status']]
        criteria=''
        if goal['status']!='completed':
            criteria=f'<p><strong>Prerequisite:</strong> {esc(goal["dependency"])}</p><p><strong>Done when:</strong> {esc(goal["acceptance"])}</p>'
        if goal.get('tasks'):
            criteria += '<h4>Sequential tasks</h4><ul>' + ''.join(f'<li>{esc(t["id"])} · {esc(t["title"])} — {LABELS[t["status"]]}</li>' for t in goal['tasks']) + '</ul>'
        articles+=f'<article class="goal" data-goal="{goal["status"]}"><div class="goal-content"><span class="label">{esc(goal["area"])}</span><h3>{esc(goal["title"])}</h3><p>{esc(goal["detail"])}</p>{criteria}<a class="text-link" href="{goal["proof"]}">Read the details</a></div><div class="goal-meta"><span class="badge {cls}">{label}</span></div></article>'
    goal_html+=f'<section class="section" data-goal-group><h2>{heading}</h2><div class="goal-list">{articles}</div></section>'
counts={status:sum(g['status']==status for g in goals) for status in LABELS}
summary=' · '.join(f'{counts[key]} {label.lower()}' for key,label in LABELS.items())
roadmap=top('What we have shipped. What comes next.','A focused Dart roadmap: reusable core, PostgreSQL, MySQL and OpenAI. Next priorities are ordered; future proposals require scope and API design before work begins.','Roadmap & goals')+f'''<div class="wrap page-body"><div class="scope-note"><strong>{esc(summary)}.</strong><p>Roadmap updated 9 October 2026. Production SQL acceptance is in progress: trusted CA chains passed; connection-loss recovery is next. Publication is complete; production acceptance remains a separate gate.</p></div><p>Delivered = implemented and verified within documented scope. Planned = next priority, not started. Awaiting input = blocked on an external prerequisite. Proposed = an idea to assess, without a committed release or date. In progress is reserved for work that has actually started.</p><div class="filters" aria-label="Filter goals">'''+''.join(f'<button class="filter" data-goal-filter="{key}" aria-pressed="{str(key=="all").lower()}">{label}</button>' for key,label in [('all','All goals'),('active','In progress'),('awaiting-input','Awaiting input'),('planned','Planned'),('proposed','Proposed'),('completed','Delivered')])+f'''</div><p class="small" id="goal-count" aria-live="polite">{len(goals)} goals shown</p>{goal_html}<div class="empty" id="goals-empty" hidden>No goals match this status. Choose another status to see delivered work and upcoming milestones.</div><div class="scope-note">New integrations are selected for real Dart application needs and established pub.dev drivers. RPC, workflows, cluster, CLI and the full Node package inventory are outside the current plan. Realtime AI and automatic tool execution need separate design and authorization before entering the roadmap.</div><p class="small">Statuses are versioned editorial records, not a live activity feed. Update the shared roadmap data and README together with each milestone; record acceptance evidence before marking it delivered.</p><a class="button" href="/progress/">Inspect verification evidence</a></div>'''
page('/roadmap/','Roadmap & goals',roadmap,'Roadmap')

def doc_page(route,title,file,package=None):
    sidebar='<aside class="sidebar" aria-label="Documentation"><div class="sidebar-group"><p class="label">Learn</p>'
    sidebar+=''.join(f'<a href="/docs/{slug}/"'+(' aria-current="page"' if file==p else '')+f'>{label}</a>' for slug,label,p in docs)
    sidebar+='</div><div class="sidebar-group"><p class="label">Packages</p>'+''.join(f'<a href="/packages/{p["slug"]}/"'+(' aria-current="page"' if package==p else '')+f'>{p["name"]}</a>' for p in packages)+'</div></aside>'
    proof=''
    if package: proof=f'<div class="scope-note"><strong>{package["vm"]} VM tests recorded.</strong> {package["platform"]} · v{package["version"]} · <a href="{package["url"]}">View on pub.dev</a> · <a href="/progress/">Verification details</a></div>'
    body=f'<div class="wrap docs-layout">{sidebar}<article class="prose"><div class="bread"><a href="/docs/getting-started/">Documentation</a> / {esc(title)}</div>{proof}{markdown(file)}<div class="doc-foot"><a href="{SOURCE+str(file.relative_to(ROOT))}">View this guide in source</a> · <a href="/progress/">View verification</a></div></article></div>'
    page(route,title,body,'Packages' if package else 'Docs')
for slug,title,file in docs: doc_page('/docs/'+slug+'/',title,file)
for p in packages: doc_page('/packages/'+p['slug']+'/',p['name'],p['doc'],p)
(OUT/'evidence').mkdir(exist_ok=True)
for name in REPORTS: shutil.copyfile(ROOT/'docs/effect-port'/name,OUT/'evidence'/name)
(OUT/'favicon.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><rect width="40" height="40" rx="9" fill="#101112"/><path d="M10 8h23l-5 7H5zm0 12h18l-5 7H5zm0 12h10l-4 5H5z" fill="#ffa26a"/></svg>')
(OUT/'404.html').write_text((OUT/'index.html').read_text().replace('<title>Reliable Dart APIs · Effect Dart</title>','<title>Page not found · Effect Dart</title>').replace(hero,top('This page is not here.','Start with the docs or return to the project overview.','404')+'<div class="wrap page-body"><a class="button primary" href="/">Back to overview</a></div>'))
(OUT/'robots.txt').write_text('User-agent: *\nDisallow: /\n')
(OUT/'site-data.json').write_text(json.dumps({'packages':[{k:v for k,v in p.items() if k!='doc'} for p in packages],'goals':goals,'vm_tests':vm,'browser_tests':chrome,'recorded_at':recorded.date().isoformat(),'source_evidence_verified':True,'releases_verified_at':releases['verified_at_utc']},indent=2)+'\n')
print(f'Built {len(list(OUT.rglob("index.html")))} routes; {vm} recorded VM tests, {chrome} browser tests; published runtime and dated evidence hashes verified.')
