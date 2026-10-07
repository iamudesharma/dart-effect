#!/usr/bin/env python3
"""Build a portable static site from versioned documentation and test evidence."""
from pathlib import Path
import datetime, hashlib, html, json, re, shutil

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / 'dist'
GITHUB = 'https://github.com/iamudesharma/dart-effect'
SOURCE = GITHUB + '/blob/dart-effect/'
REPORTS = ['rename-validation.json', 'sql-validation.json', 'openai-validation.json']
reports = {name: json.loads((ROOT / 'docs/effect-port' / name).read_text()) for name in REPORTS}
for name, report in reports.items():
    for file, digest in report.get('source_sha256', {}).items():
        if hashlib.sha256((ROOT / file).read_bytes()).hexdigest() != digest:
            raise SystemExit(f'Stale validation evidence: {name}: {file}; run the relevant checks before building.')
core = reports['rename-validation.json']['tests']
ai = reports['openai-validation.json']['checks']['tests']
sql = reports['sql-validation.json']['suites']
assert reports['sql-validation.json']['containers_removed']
assert all(v['exit_code'] == 0 and v['failed'] == 0 and v['skipped'] == 0 for v in sql.values())
recorded = max(datetime.datetime.fromisoformat(report.get('verified_at_utc', report.get('finished_at_utc'))) for report in reports.values())
recorded_date = f'{recorded.day} {recorded.strftime("%B %Y")}'
vm = core['core_vm'] + ai['openai_vm'] + sum(v['passed'] for v in sql.values())
chrome = core['core_chrome'] + core['sql_chrome'] + ai['openai_chrome']
goals = json.loads((HERE / 'content/goals.json').read_text())
allowed = {'completed', 'active', 'planned', 'awaiting-input'}
assert len({g['id'] for g in goals}) == len(goals) and all(g['status'] in allowed for g in goals)
packages = [
    {'name': 'effect_core', 'slug': 'effect-core', 'icon': 'E', 'text': 'Lazy effects, typed failures and structured concurrency. The foundation for every service.', 'platform': 'VM + web', 'vm': core['core_vm'], 'chrome': core['core_chrome'], 'doc': ROOT/'README.md'},
    {'name': 'effect_sql', 'slug': 'effect-sql', 'icon': 'SQL', 'text': 'Shared connection lifetimes, exclusive transactions and nested savepoints.', 'platform': 'Portable contracts', 'vm': sql['effect_sql']['passed'], 'chrome': core['sql_chrome'], 'doc': ROOT/'packages/effect_sql/README.md'},
    {'name': 'effect_postgres', 'slug': 'effect-postgres', 'icon': 'PG', 'text': 'PostgreSQL and PG through the established postgres Dart driver.', 'platform': 'Native server', 'vm': sql['effect_postgres']['passed'], 'chrome': None, 'doc': ROOT/'packages/effect_postgres/README.md'},
    {'name': 'effect_mysql', 'slug': 'effect-mysql', 'icon': 'MY', 'text': 'MySQL with prepared binding, scoped connections and explicit TLS behavior.', 'platform': 'Native server', 'vm': sql['effect_mysql']['passed'], 'chrome': None, 'doc': ROOT/'packages/effect_mysql/README.md'},
    {'name': 'effect_openai', 'slug': 'effect-openai', 'icon': 'AI', 'text': 'Typed OpenAI requests, Responses and Chat streams, cancellation and scoped clients.', 'platform': 'VM + web', 'vm': ai['openai_vm'], 'chrome': ai['openai_chrome'], 'doc': ROOT/'packages/effect_openai/README.md'},
]
docs = [
    ('getting-started', 'Getting started', HERE/'content/getting-started.md'),
    ('runtime', 'Runtime & types', ROOT/'docs/effect-port/architecture.md'),
    ('features', 'Supported features', ROOT/'docs/effect-port/feature-matrix.md'),
    ('testing', 'Testing & conformance', ROOT/'docs/effect-port/testing.md'),
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
  document.querySelector('#goals-empty').hidden=count!==0;
  document.querySelector('#goal-count').textContent=count+' '+(count===1?'goal':'goals')+' shown';
}));
'''

def page(route, title, body, active=''):
    def nav(): return ''.join(f'<a href="{url}"'+(' aria-current="page"' if active==label else '')+f'>{label}</a>' for label,url in nav_items)
    search_json=json.dumps(search_index,ensure_ascii=False).replace('<','\\u003c')
    text=f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="Effect Dart: lazy typed effects, Dart package guides, verified progress and project roadmap."><meta name="theme-color" content="#101112"><title>{esc(title)} · Effect Dart</title><link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/styles.css"></head><body><a class="skip" href="#main">Skip to content</a><header class="header"><div class="wrap head-inner"><a class="brand" href="/" aria-label="Effect Dart home">{logo}Effect <em>Dart</em></a><nav class="nav" aria-label="Primary">{nav()}</nav><div class="head-right"><button class="search-button" data-search aria-haspopup="dialog"><span>Search docs</span><kbd>⌘ K</kbd></button><a class="github" href="{GITHUB}">GitHub</a><details class="mobile-nav"><summary>Menu</summary><div>{nav()}<a href="{GITHUB}">GitHub</a></div></details></div></div></header><main id="main">{body}</main><footer class="footer"><div class="wrap footer-inner"><div><a class="brand" href="/">{logo}Effect <em>Dart</em></a><p>Independent. Effect-inspired. Built for Dart.<br>Development source · MIT · Not affiliated with Effect-TS.</p></div><div class="footer-links"><a href="/docs/getting-started/">Documentation</a><a href="/progress/">Verification</a><a href="{GITHUB}">Source</a><a href="https://effect.website">Effect-TS</a></div></div></footer><dialog class="search-dialog" id="search-dialog" aria-labelledby="search-label"><div class="search-head"><label id="search-label" class="skip" for="search-input">Search documentation</label><input id="search-input" type="search" placeholder="Search documentation…" aria-label="Search documentation"><button id="search-close" aria-label="Close search">Esc</button></div><div class="search-results" id="search-results" aria-live="polite"></div><div class="search-hint">Search package guides and documentation. Escape closes search.</div></dialog><script type="application/json" id="search-index">{search_json}</script><script>{script}</script></body></html>'''
    target=OUT/route.lstrip('/')/'index.html';target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text)

def stats():return f'<div class="stats"><div class="stat"><strong>5</strong><span>Implemented packages</span></div><div class="stat"><strong>{vm}</strong><span>Recorded VM tests</span></div><div class="stat"><strong>{chrome}</strong><span>Recorded browser tests</span></div><div class="stat"><strong>0</strong><span>Core runtime dependencies</span></div></div>'
def cards(featured=False):
    content=''
    for i,p in enumerate(packages):
        cls='package-card featured' if featured and i==0 else 'package-card'
        main=f'<div><div class="package-icon">{p["icon"]}</div><h3>{p["name"]}</h3><p>{p["text"]}</p><div class="card-bottom"><span>{p["vm"]} VM tests recorded</span><span class="platform">{p["platform"]}</span></div></div>'
        extra='<div class="mini-code"><span class="code-type">Effect</span>&lt;A, E, R&gt;<br><span class="code-comment">// value · failure · environment</span><br><br>lazy · reusable · scoped</div>' if featured and i==0 else ''
        content+=f'<a class="{cls}" href="/packages/{p["slug"]}/">{main}{extra}</a>'
    return '<div class="package-grid">'+content+'</div>'
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
hero=f'''<div class="announcement"><span>DEVELOPMENT UPDATE</span>Five packages. One Dart runtime. <a href="/progress/">See what’s verified.</a></div><div class="wrap"><section class="hero"><div><p class="eyebrow">Effect-inspired. Dart-native.</p><h1>Build reliable<br><span class="muted">Dart APIs.</span></h1><p class="lead">Make async work predictable. Compose typed failures, scoped resources and services in one lazy runtime.</p><div class="actions"><a class="button primary" href="/docs/getting-started/">Get started</a><a class="button" href="/progress/">Explore progress</a></div><p class="small">Dart ≥3.13 · v0.1.0-dev.1 · Development source</p></div><div class="terminal"><div class="terminal-top"><span class="file">hello_effect.dart</span><span>CORE RUNTIME</span></div><pre><code>{highlight(snippet)}</code></pre><div class="terminal-footer"><span class="dot"></span>Lazy until run. Cleanup before return.</div></div></section><section class="section"><div class="section-header"><div><span class="label">The project today</span><h2>Progress you can inspect.</h2></div><p>Recorded checks from {recorded_date}.<br>Evidence follows the code, not a completion percentage.</p></div>{stats()}<p class="small">Counts combine dated validation runs for the current source. Local OpenAI transport is verified; live model acceptance is still open.</p></section><section class="section"><div class="section-header"><div><span class="label">One foundation, focused integrations</span><h2>Pick the service you need.</h2></div><a class="button" href="/packages/">All packages</a></div>{cards(True)}</section><section class="section split"><div><span class="label">A small mental model</span><h2>Values. Failures. Requirements.</h2><div class="type-signature">Effect&lt;<b>A</b>, <b>E</b>, <b>R</b>&gt;</div><div class="definitions"><div><h3>A · Value</h3><p>What the computation returns.</p></div><div><h3>E · Failure</h3><p>Its expected error family.</p></div><div><h3>R · Environment</h3><p>The services it requires.</p></div></div><div class="scope-note">Dart covariance means R is not a complete static proof of service provision. Typed selectors and runtime checks keep the boundary explicit.</div></div><div><div class="milestone"><span class="number">01</span><div><h3>Describe the work</h3><p>Construct a lazy effect. Compose without starting I/O.</p></div></div><div class="milestone"><span class="number">02</span><div><h3>Provide the lifetime</h3><p>Use scoped resources and layers to own your services.</p></div></div><div class="milestone"><span class="number">03</span><div><h3>Run and observe</h3><p>Inspect Success or Failure after child work and cleanup finish.</p></div></div></div></section><section class="section"><div class="section-header"><div><span class="label">What’s next</span><h2>A roadmap with honest boundaries.</h2></div><a class="button" href="/roadmap/">View goals</a></div><div class="two-cards"><div class="info-card"><span class="badge pending">Awaiting input</span><h3>Live OpenAI acceptance</h3><p>Local SDK requests and streams are tested. A supplied API key and enabled model are needed to verify live generation.</p></div><div class="info-card"><span class="badge planned">Planned</span><h3>Production & release readiness</h3><p>Database hardening and a first pub.dev release are future milestones. The current packages remain development candidates.</p></div></div></section></div>'''
page('/', 'Reliable Dart APIs',hero)
page('/packages/', 'Packages',top('One runtime. Focused packages.','Use core on its own, then add the database or AI integration your application needs. Each package has an explicit platform and acceptance boundary.','The ecosystem')+'<div class="wrap page-body">'+cards()+ '<div class="scope-note"><strong>Development source, not a published release.</strong> Packages are not on pub.dev yet. Follow the local dependency setup in Getting started.</div></div>','Packages')
rows=''.join(f'<tr><td><a href="/packages/{p["slug"]}/">{p["name"]}</a></td><td>{p["vm"]}</td><td>{p["chrome"] if p["chrome"] is not None else "Native only"}</td><td><span class="badge">Recorded passing</span></td><td>{p["platform"]}</td></tr>' for p in packages)
progress=top('Progress, backed by evidence.','The five packages are implemented within their documented scope. These are recorded checks against the current source, not a claim of complete Effect-TS parity.','Project status')+f'''<div class="wrap page-body">{stats()}<p class="small">Latest recorded evidence: {recorded_date}. Recorded implementation hashes matched at site build. Totals combine package-specific runs; tests were not all run in one suite.</p><section class="section"><div class="section-header"><div><span class="label">Verification by package</span><h2>What actually passed.</h2></div></div><div class="table-scroll"><table class="evidence-table"><thead><tr><th>Package</th><th>VM tests</th><th>Chrome tests</th><th>Status</th><th>Platform</th></tr></thead><tbody>{rows}</tbody></table></div><div class="two-cards"><div class="info-card"><h3>Database acceptance</h3><p>Real PostgreSQL and MySQL driver suites passed with no skips, against isolated pinned database containers. Test containers were removed.</p><a class="button" href="/evidence/sql-validation.json">View database evidence</a></div><div class="info-card"><h3>OpenAI transport acceptance</h3><p>Eight loopback HTTP/SSE tests exercise actual SDK clients and sockets. Portable lifecycle and wire tests also passed in Chrome.</p><a class="button" href="/evidence/openai-validation.json">View AI evidence</a></div></div></section><section class="section"><div class="section-header"><div><span class="label">The remaining boundary</span><h2>Implemented isn’t the same as production-accepted.</h2></div></div><div class="two-cards"><div class="info-card"><h3>Verified locally</h3><ul><li>Lazy reuse, typed failures and structured cleanup</li><li>Real database transactions and cancellation contracts</li><li>Actual SDK HTTP requests and SSE parsing</li><li>Core type fixtures and runnable examples</li><li>Clean Git checkout builds without Node/npm references</li></ul></div><div class="info-card"><h3>Still needs acceptance</h3><ul><li>Live OpenAI API and real model output</li><li>Production CA chains, failover and long network partitions</li><li>Load/soak and database version matrices</li><li>Live browser API transport</li><li>Package publication and broader ecosystem coverage</li></ul></div></div><div class="actions"><a class="button" href="/roadmap/">Next milestones</a><a class="button" href="/evidence/rename-validation.json">Core & SQL evidence</a></div></section></div>'''
page('/progress/','Progress',progress,'Progress')
status_labels={'completed':('Delivered',''),'active':('In progress',''),'planned':('Planned','planned'),'awaiting-input':('Awaiting input','pending')}
goal_html=''
for goal in goals:
    label,cls=status_labels[goal['status']]
    goal_html+=f'<article class="goal" data-goal="{goal["status"]}"><div class="goal-content"><span class="label">{esc(goal["area"])}</span><h3>{esc(goal["title"])}</h3><p>{esc(goal["detail"])}</p><a class="text-link" href="{goal["proof"]}">Read the details</a></div><div class="goal-meta"><span class="badge {cls}">{label}</span><span class="small">Tracked in the repository</span></div></article>'
active=sum(g['status']=='active' for g in goals)
roadmap=top('The work in view.','Delivered implementation, current work and the acceptance milestones ahead. This roadmap records agreed scope; it is not a live agent activity feed.','Roadmap & goals')+f'''<div class="wrap page-body"><div class="scope-note"><strong>{active} goals currently in progress.</strong> The requested implementation is delivered. The next acceptance milestones need credentials or planning before work starts.</div><div class="filters" aria-label="Filter goals">'''+''.join(f'<button class="filter" data-goal-filter="{key}" aria-pressed="{str(key=="all").lower()}">{label}</button>' for key,label in [('all','All goals'),('active','In progress'),('awaiting-input','Awaiting input'),('planned','Planned'),('completed','Delivered')])+f'''</div><p class="small" id="goal-count" aria-live="polite">{len(goals)} goals shown</p><div class="goal-list">{goal_html}</div><div class="empty" id="goals-empty" hidden>No goals are currently in progress. Choose another status to see delivered work and upcoming milestones.</div><p class="small">Updated with this website release. Milestones have no invented deadlines or automatic scheduling.</p></div>'''
page('/roadmap/','Roadmap & goals',roadmap,'Roadmap')

def doc_page(route,title,file,package=None):
    sidebar='<aside class="sidebar" aria-label="Documentation"><div class="sidebar-group"><p class="label">Learn</p>'
    sidebar+=''.join(f'<a href="/docs/{slug}/"'+(' aria-current="page"' if file==p else '')+f'>{label}</a>' for slug,label,p in docs)
    sidebar+='</div><div class="sidebar-group"><p class="label">Packages</p>'+''.join(f'<a href="/packages/{p["slug"]}/"'+(' aria-current="page"' if package==p else '')+f'>{p["name"]}</a>' for p in packages)+'</div></aside>'
    proof=''
    if package: proof=f'<div class="scope-note"><strong>{package["vm"]} VM tests recorded.</strong> {package["platform"]} · v0.1.0-dev.1 · <a href="/progress/">Verification details</a></div>'
    body=f'<div class="wrap docs-layout">{sidebar}<article class="prose"><div class="bread"><a href="/docs/getting-started/">Documentation</a> / {esc(title)}</div>{proof}{markdown(file)}<div class="doc-foot"><a href="{SOURCE+str(file.relative_to(ROOT))}">View this guide in source</a> · <a href="/progress/">View verification</a></div></article></div>'
    page(route,title,body,'Packages' if package else 'Docs')
for slug,title,file in docs: doc_page('/docs/'+slug+'/',title,file)
for p in packages: doc_page('/packages/'+p['slug']+'/',p['name'],p['doc'],p)
(OUT/'evidence').mkdir(exist_ok=True)
for name in REPORTS: shutil.copyfile(ROOT/'docs/effect-port'/name,OUT/'evidence'/name)
(OUT/'favicon.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><rect width="40" height="40" rx="9" fill="#101112"/><path d="M10 8h23l-5 7H5zm0 12h18l-5 7H5zm0 12h10l-4 5H5z" fill="#ffa26a"/></svg>')
(OUT/'404.html').write_text((OUT/'index.html').read_text().replace('<title>Reliable Dart APIs · Effect Dart</title>','<title>Page not found · Effect Dart</title>').replace(hero,top('This page is not here.','Start with the docs or return to the project overview.','404')+'<div class="wrap page-body"><a class="button primary" href="/">Back to overview</a></div>'))
(OUT/'robots.txt').write_text('User-agent: *\nDisallow: /\n')
(OUT/'site-data.json').write_text(json.dumps({'packages':[{k:v for k,v in p.items() if k!='doc'} for p in packages],'goals':goals,'vm_tests':vm,'browser_tests':chrome,'recorded_at':recorded.date().isoformat(),'source_evidence_verified':True},indent=2)+'\n')
print(f'Built {len(list(OUT.rglob("index.html")))} routes; {vm} recorded VM tests, {chrome} browser tests; evidence source hashes match.')
