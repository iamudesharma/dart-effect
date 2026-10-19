#!/usr/bin/env python3
"""Audit merged core/cache without modifying production code or old evidence."""
from pathlib import Path
import datetime, hashlib, json, subprocess
ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'build/core-memory-audit'

def fingerprints():
    files=[*ROOT.glob('lib/**/*.dart'),*ROOT.glob('packages/*/lib/**/*.dart'),ROOT/'tool/core_memory_audit.dart',ROOT/'tool/http_body_memory_audit.dart',ROOT/'tool/performance_memory.dart',Path(__file__)]
    return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
def run(name,args,cwd=ROOT,tests=False):
    p=subprocess.run(args,cwd=cwd,text=True,capture_output=True,timeout=180)
    (BUILD/(name+'.log')).write_text(p.stdout+p.stderr)
    if p.returncode: raise RuntimeError(f'{name} failed; inspect {BUILD/(name+".log")}')
    row={'command':args,'exit_code':p.returncode}
    if tests:
        done=[]
        for line in p.stdout.splitlines():
            try:e=json.loads(line)
            except ValueError:continue
            if e.get('type')=='testDone' and not e.get('hidden'):done.append(e)
        row.update(passed=sum(e.get('result')=='success' and not e.get('skipped') for e in done),
            failed=sum(e.get('result')!='success' and not e.get('skipped') for e in done),skipped=sum(bool(e.get('skipped')) for e in done))
        assert row['passed'] and not row['failed'] and not row['skipped'],(name,row)
    print(name,row,flush=True)
    return row,p.stdout

def data(output):return json.loads(next(line for line in reversed(output.splitlines()) if line.startswith('{')))
def main():
    BUILD.mkdir(parents=True,exist_ok=True); initial=fingerprints()
    report={'recorded_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'source_revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        'production_code_modified':False,'scope':'Merged core, cache and HTTP dynamic probes; SQL/OpenAI adapters static review only. No Flutter/device frame profiling or live provider/DB soak.',
        'checks':{},'source_sha256':initial}
    for name,args,cwd,tests in [
        ('core-resolve',['dart','pub','get','--offline'],ROOT,False),
        ('cache-resolve',['dart','pub','get','--offline'],ROOT/'packages/effect_cache',False),
        ('http-resolve',['dart','pub','get','--offline'],ROOT/'packages/effect_http',False),
        ('audit-analysis',['dart','analyze','--fatal-infos','tool/core_memory_audit.dart','tool/http_body_memory_audit.dart'],ROOT,False),
        ('core-vm',['dart','test','-r','json'],ROOT,True),
        ('core-chrome',['dart','test','-p','chrome','-r','json'],ROOT,True),
        ('cache-vm',['dart','test','-r','json'],ROOT/'packages/effect_cache',True),
        ('cache-chrome',['dart','test','-p','chrome','-r','json'],ROOT/'packages/effect_cache',True),
        ('http-vm',['dart','test','-r','json'],ROOT/'packages/effect_http',True),
        ('http-chrome',['dart','test','-p','chrome','test/portable_test.dart','-r','json'],ROOT/'packages/effect_http',True),
        ('fixtures',['dart','run','tool/check_fixtures.dart'],ROOT,False)]:
        report['checks'][name]=run(name,args,cwd,tests)[0]
    report['jit']=data(run('scheduling-jit',['dart','run','tool/core_memory_audit.dart'])[1])
    run('compile-aot',['dart','compile','exe','tool/core_memory_audit.dart','-o',str(BUILD/'audit')])
    report['aot']=data(run('scheduling-aot',[str(BUILD/'audit')])[1])
    report['timing_aot']=data(run('timing-aot',[str(BUILD/'audit'),'--timing'])[1])
    report['memory_runs']=[data(run('memory-'+str(i),['dart','--enable-vm-service=0','run','tool/core_memory_audit.dart','--memory'])[1]) for i in range(3)]
    report['http_body']=data(run('http-body',['dart','--packages=packages/effect_http/.dart_tool/package_config.json','--enable-vm-service=0','run','tool/http_body_memory_audit.dart'])[1])
    assert fingerprints()==initial,'Sources changed during audit'
    report['completed_at_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    report['audit_completed']=True
    report['note']='Audit completion is not a clean bill of health: reproduced gaps are documented in core-memory-audit.md. Timings are synthetic macOS VM/AOT measurements, not Flutter frame/SLO proof.'
    (ROOT/'docs/effect-port/core-memory-audit.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
