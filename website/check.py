#!/usr/bin/env python3
"""Check static routes, assets, search data, headings and browser script syntax."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote
import json, subprocess, tempfile

ROOT=Path(__file__).resolve().parent/'dist'
class Document(HTMLParser):
    def __init__(self,text):
        super().__init__();self.links=[];self.ids=[];self.h1=0;self.lang=False;self.script=None;self.scripts=[];self.index='';self.feed(text)
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if tag=='html':self.lang=a.get('lang')=='en'
        if 'id' in a:self.ids.append(a['id'])
        if tag=='h1':self.h1+=1
        if tag in ('a','link') and a.get('href'):self.links.append(a['href'])
        if tag in ('img','script') and a.get('src'):self.links.append(a['src'])
        if tag=='script':self.script=a.get('type','script');self.scripts.append('')
    def handle_endtag(self,tag):
        if tag=='script':self.script=None
    def handle_data(self,data):
        if self.script:
            if self.script=='application/json':self.index+=data
            else:self.scripts[-1]+=data
files=list(ROOT.rglob('*.html')); documents={}
for file in files:
    text=file.read_text();assert '\x00' not in text,file
    d=Document(text);documents[file]=d
    assert d.lang and d.h1==1 and len(set(d.ids))==len(d.ids),file
    entries=json.loads(d.index);assert len(entries)>=10,file
    assert all(p.get('title') and p.get('url') and p.get('text') for p in entries),file
    for script in filter(None,d.scripts):
        with tempfile.NamedTemporaryFile(suffix='.js',mode='w') as source:
            source.write(script);source.flush()
            subprocess.run(['node','--check',source.name],check=True,capture_output=True)
for file,d in documents.items():
    for link in d.links:
        parts=urlsplit(link)
        if parts.scheme or parts.netloc:continue
        target=ROOT/unquote(parts.path).lstrip('/') if parts.path.startswith('/') else file.parent/unquote(parts.path)
        if not parts.path:target=file
        if target.is_dir():target=target/'index.html'
        assert target.is_file(),(file,link,target)
        if parts.fragment and target.suffix=='.html':assert unquote(parts.fragment) in documents[target].ids,(file,link)
print(f'PASS: {len(files)} pages; internal routes, assets, anchors, search JSON, one h1 and script syntax.')

# Release and development inventories must never collapse into one registry claim.
data=json.loads((ROOT/'site-data.json').read_text())
released=[p for p in data['packages'] if not p.get('unpublished')]
development=[p for p in data['packages'] if p.get('unpublished')]
assert len(released)==6 and len(development)==13
assert all(p['url'].startswith('https://pub.dev/packages/') for p in released)
assert all('url' not in p and p['version']=='0.1.0-dev.1' for p in development)
for p in development:
    text=(ROOT/'packages'/p['slug']/'index.html').read_text()
    assert 'Unpublished · 0.1.0-dev.1' in text
    assert 'path: /path/to/effect_dart/packages/'+p['name'] in text and '<pre><code>' in text
assert data['development_validation']['packages_analyzed']==19
assert data['development_validation']['vm_flutter_passed_without_duplicate_native_suites']==283
assert data['development_validation']['chrome_passed']==226
assert data['vm_tests']==230 and data['browser_tests']==184
print('PASS: 6 released / 13 unpublished guides; installation examples and dated validation totals remain separate.')

assert data['cache_validation']=={'vm':35, 'chrome':34, 'unpublished':True}
assert next(p for p in development if p['name']=='effect_cache')['vm']==35
print('PASS: cache follow-up uses its own evidence and remains unpublished.')

assert len([p for p in development if p.get('draft')]) == 12
assert not next(p for p in development if p['name']=='effect_cache')['draft']
assert 'Draft PR #13' in data['draft_toolkit_snapshot']['status']
print('PASS: only cache is ready; twelve other package guides are draft snapshots.')
