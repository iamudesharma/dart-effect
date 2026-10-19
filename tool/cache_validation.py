#!/usr/bin/env python3
"""Reproducible cache checks. Local SDK/pub/Chrome prerequisites; never publishes."""
from pathlib import Path
import argparse,datetime, hashlib, json, shutil, subprocess, tempfile

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--report', type=Path, default=ROOT/'docs/effect-port/cache-validation.json')
options=parser.parse_args()
PACKAGE=ROOT/'packages/effect_cache'
BUILD=ROOT/'build/cache-validation'

def fingerprints():
    paths=[*ROOT.glob('lib/**/*.dart'), *PACKAGE.glob('lib/**/*.dart'),
        *PACKAGE.glob('test/**/*.dart'), *PACKAGE.glob('example/**/*.dart'),
        PACKAGE/'pubspec.yaml', PACKAGE/'README.md', PACKAGE/'CHANGELOG.md',
        ROOT/'tool/cache_performance.dart',ROOT/'tool/performance_memory.dart',Path(__file__)]
    return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}

def run(name, args, cwd=PACKAGE, tests=False):
    result=subprocess.run(args,cwd=cwd,capture_output=True,text=True,timeout=180)
    output=result.stdout+result.stderr
    (BUILD/(name+'.log')).write_text(output)
    row={'command':args,'exit_code':result.returncode}
    if tests:
        rows=[]
        for line in result.stdout.splitlines():
            try: value=json.loads(line)
            except ValueError: continue
            if value.get('type')=='testDone' and not value.get('hidden'): rows.append(value)
        row.update(passed=sum(v.get('result')=='success' and not v.get('skipped') for v in rows),
            failed=sum(v.get('result')!='success' and not v.get('skipped') for v in rows),
            skipped=sum(bool(v.get('skipped')) for v in rows))
        assert row['passed'] and not row['failed'] and not row['skipped'],(name,row)
    if result.returncode: raise RuntimeError(f'{name} failed: see {BUILD/(name+".log")}')
    print(name, row, flush=True)
    return row, output

def last_json(output):
    return json.loads(next(line for line in reversed(output.splitlines()) if line.startswith('{')))

def main():
    BUILD.mkdir(parents=True,exist_ok=True)
    initial=fingerprints()
    report={'started_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'success':False,'package':'effect_cache','version':'0.1.0-dev.1',
        'publication':'unpublished; hosted-only consumption awaits compatible core release',
        'suites':{},'source_sha256':initial}
    try:
        for name,args,cwd,tests in [
            ('resolve',['dart','pub','get','--offline'],PACKAGE,False),
            ('format',['dart','format','--output=none','--set-exit-if-changed','lib','test','example'],PACKAGE,False),
            ('analyze',['dart','analyze','--fatal-infos'],PACKAGE,False),
            ('vm',['dart','test','-r','json'],PACKAGE,True),
            ('chrome',['dart','test','-p','chrome','-r','json'],PACKAGE,True),
            ('example',['dart','run','example/main.dart'],PACKAGE,False),
            ('web_compile',['dart','compile','js','example/main.dart','-o',str(BUILD/'example.js')],PACKAGE,False),
            ('core_analyze',['dart','analyze','--fatal-infos','lib'],ROOT,False),
            ('core_tests_analyze',['dart','analyze','--fatal-infos','test'],ROOT,False),
            ('core_examples_analyze',['dart','analyze','--fatal-infos','example'],ROOT,False),
            ('profile_analyze',['dart','analyze','--fatal-infos','tool/cache_performance.dart'],ROOT,False),
            ('core_vm',['dart','test','-r','json'],ROOT,True),
            ('fixtures',['dart','run','tool/check_fixtures.dart'],ROOT,False)]:
            report['suites'][name]=run(name,args,cwd,tests)[0]
        report['jit']=last_json(run('jit',['dart','run','tool/cache_performance.dart'],ROOT)[1])
        run('aot_compile',['dart','compile','exe','tool/cache_performance.dart','-o',str(BUILD/'cache-performance')],ROOT)
        report['aot']=last_json(run('aot',[str(BUILD/'cache-performance')],ROOT)[1])
        report['memory']=[last_json(run('memory-'+str(i),['dart','--enable-vm-service=0','run','tool/cache_performance.dart','--memory'],ROOT)[1]) for i in range(3)]
        # Ancestor .pubignore excludes packages/ for the core archive. Stage the
        # standalone package outside that tree so pub can inspect its real files.
        with tempfile.TemporaryDirectory(prefix='effect-cache-dryrun-') as d:
            target=Path(d)/'effect_cache'
            shutil.copytree(PACKAGE,target,ignore=shutil.ignore_patterns('.dart_tool','pubspec_overrides.yaml'))
            (target/'pubspec_overrides.yaml').write_text('dependency_overrides:\n  effect_core:\n    path: '+str(ROOT)+'\n')
            row,output=run('isolated_dry_run',['dart','pub','publish','--dry-run'],target)
            assert '0 warnings and 1 hint' in output and 'pubspec_overrides.yaml' in output
            report['dry_run']={**row,'warnings':0,'hints':1,
                'hint':'Development core path override; not a hosted-only consumer verification',
                'archive_scope':'Isolated package copy; no ancestor core .pubignore; overrides/lockfile excluded by package .pubignore'}
        assert fingerprints()==initial,'Sources changed during validation'
        report['success']=True
    finally:
        report['finished_at_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
        options.report.write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__': main()
