#!/usr/bin/env python3
"""Fresh implementation evidence; never rewrites the earlier audit/release reports."""
from pathlib import Path
import datetime, hashlib, json, subprocess, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT/'build/memory-fixes'

def fingerprints():
    files = [*ROOT.glob('lib/**/*.dart'), *ROOT.glob('test/**/*.dart'), *ROOT.glob('packages/*/lib/**/*.dart'), *ROOT.glob('packages/*/test/**/*.dart'), ROOT/'pubspec.yaml', *ROOT.glob('packages/*/pubspec.yaml'), *ROOT.glob('packages/*/pubspec_overrides.yaml'), ROOT/'tool/memory_fixes_probe.dart', ROOT/'tool/http_body_memory_audit.dart', ROOT/'tool/performance_memory.dart', ROOT/'tool/sql_integration.py', ROOT/'tool/cache_validation.py', Path(__file__)]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}

def run(name, args, cwd=ROOT, tests=False):
    p = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=300)
    (BUILD/(name+'.log')).write_text(p.stdout+p.stderr)
    if p.returncode:
        raise RuntimeError(f'{name} failed: {BUILD/(name+".log")}')
    row = {'command': args, 'exit_code': p.returncode}
    if tests:
        ends=[]
        for line in p.stdout.splitlines():
            try: e=json.loads(line)
            except ValueError: continue
            if e.get('type')=='testDone' and not e.get('hidden'): ends.append(e)
        row.update(passed=sum(e.get('result')=='success' and not e.get('skipped') for e in ends), failed=sum(e.get('result')!='success' and not e.get('skipped') for e in ends), skipped=sum(bool(e.get('skipped')) for e in ends))
        assert row['passed'] and not row['failed'] and not row['skipped'], (name,row)
    print(name, row, flush=True)
    return row, p.stdout

def data(output):
    return json.loads(next(line for line in reversed(output.splitlines()) if line.startswith('{')))

def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    initial=fingerprints()
    report={'started_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(), 'base_revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(), 'source_sha256':initial, 'checks':{}, 'success':False}
    for pkg in ['', 'effect_cache', 'effect_http', 'effect_sql', 'effect_postgres', 'effect_mysql', 'effect_openai']:
        cwd=ROOT/'packages'/pkg if pkg else ROOT
        report['checks'][f'{pkg or "core"}-resolve']=run(f'{pkg or "core"}-resolve', ['dart','pub','get','--offline'],cwd)[0]
    report['checks']['analysis']=run('analysis', ['dart','analyze','--fatal-infos'])[0]
    for pkg in ['', 'effect_cache', 'effect_http', 'effect_sql', 'effect_openai']:
        cwd=ROOT/'packages'/pkg if pkg else ROOT
        name=pkg or 'core'
        for platform in ['vm','chrome']:
            args=['dart','test','-p',platform,'-r','json']
            if pkg=='effect_http' and platform=='chrome': args+=['test/portable_test.dart','test/memory_test.dart']
            report['checks'][f'{name}-{platform}']=run(f'{name}-{platform}',args,cwd,True)[0]
    for pkg in ['effect_postgres','effect_mysql']:
        report['checks'][f'{pkg}-classification']=run(f'{pkg}-classification',['dart','test','test/classification_test.dart','-r','json'],ROOT/'packages'/pkg,True)[0]
    report['checks']['fixtures']=run('fixtures',['dart','run','tool/check_fixtures.dart'])[0]
    for example in sorted((ROOT/'example').glob('*.dart')):
        report['checks'][f'core-example-{example.stem}']=run(f'core-example-{example.stem}',['dart','run',str(example)])[0]
    for pkg in ['effect_cache', 'effect_openai']:
        cwd=ROOT/'packages'/pkg if pkg else ROOT
        name=pkg or 'core'
        report['checks'][f'{name}-example']=run(f'{name}-example',['dart','run','example/main.dart'],cwd)[0]
    class Fixture(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.end_headers(); self.wfile.write(b'memory-validation')
        def log_message(self, *args): pass
    server=ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    worker=threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    try:
        row, text=run('effect_http-example',['dart','run','example/main.dart',f'http://127.0.0.1:{server.server_port}/'],ROOT/'packages/effect_http')
        assert '200: memory-validation' in text
        report['checks']['effect_http-example']=row
    finally:
        server.shutdown(); server.server_close(); worker.join()
    report['checks']['web-compile']=run('web-compile',['dart','compile','js','example/web.dart','-o',str(BUILD/'core.js')])[0]
    report['jit']=data(run('jit',['dart','run','tool/memory_fixes_probe.dart'])[1])
    run('compile-aot',['dart','compile','exe','tool/memory_fixes_probe.dart','-o',str(BUILD/'probe')])
    report['aot']=data(run('aot',[str(BUILD/'probe')])[1])
    report['timing_aot']=data(run('timing-aot',[str(BUILD/'probe'),'--timing'])[1])
    report['memory']=[data(run(f'memory-{i}',['dart','--enable-vm-service=0','run','tool/memory_fixes_probe.dart','--memory'])[1]) for i in range(3)]
    raw_http=data(run('http-body',['dart','--packages=packages/effect_http/.dart_tool/package_config.json','--enable-vm-service=0','run','tool/http_body_memory_audit.dart'])[1])
    report['http_body']={'measurements':raw_http['measurements'], 'scope':'Current production HttpResult implementation, constructor-only retained heap; original read-only probe reused without editing historical tools. Excludes request accumulation, transient peak copies, decoding and transport allocations.'}
    sql=ROOT/'build/memory-fixes-sql.json'
    report['live_sql']=json.loads(sql.read_text()) if sql.exists() else {'executed':False}
    if sql.exists():
        for file, digest in report['live_sql']['source_sha256'].items():
            if file.startswith(('lib/', 'packages/effect_sql/', 'packages/effect_postgres/', 'packages/effect_mysql/')):
                assert hashlib.sha256((ROOT/file).read_bytes()).hexdigest()==digest, f'Stale SQL evidence: {file}'
        assert report['live_sql']['containers_removed']
        assert all(v['exit_code']==0 and v['failed']==0 for v in report['live_sql']['suites'].values())
    assert fingerprints()==initial, 'Source changed during validation'
    report['success']=True
    report['finished_at_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    report['limits']='Local VM/Chrome, HTTP/SDK fixtures and native AOT probes. Live SQL only if included explicitly. No live OpenAI provider, Flutter frame/device or production soak guarantee. Pending limits bound owned records, not caller-retained payloads or arbitrary error/value bytes.'
    (ROOT/'docs/effect-port/memory-fixes-validation.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__': main()
