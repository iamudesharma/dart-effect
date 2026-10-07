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
