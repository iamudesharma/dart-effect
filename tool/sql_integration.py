#!/usr/bin/env python3
"""Isolated real-driver acceptance, with pinned images and guaranteed teardown."""
import datetime,hashlib,json,os,pathlib,subprocess,tempfile,time,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
IMAGES={
 'postgres':'postgres@sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73',
 'mysql':'mysql@sha256:6ea90827b1100f8f2ae306a539f86d2c264a26ed435a2a9f75551dd5c3aeb242',
}
report={'started_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'images':IMAGES,'suites':{},'containers_removed':False}
created=[]
def call(args,**kwargs):return subprocess.run(args,check=True,text=True,capture_output=True,**kwargs).stdout.strip()
def run_suite(package,env):
 result=subprocess.run(['dart','test','-r','json'],cwd=ROOT/'packages'/package,env=env,text=True,capture_output=True)
 events=[]
 for line in result.stdout.splitlines():
  try:events.append(json.loads(line))
  except json.JSONDecodeError:pass
 ends=[e for e in events if e.get('type')=='testDone' and not e.get('hidden')]
 report['suites'][package]={'exit_code':result.returncode,'passed':sum(e.get('result')=='success' and not e.get('skipped') for e in ends),'skipped':sum(bool(e.get('skipped')) for e in ends),'failed':sum(e.get('result')!='success' and not e.get('skipped') for e in ends)}
 (ROOT/'build'/f'{package}-integration.jsonl').write_text(result.stdout)
 print(package,report['suites'][package],flush=True)
 if result.returncode:print(result.stderr);raise RuntimeError(f'{package} failed; inspect build/{package}-integration.jsonl')
try:
 call(['docker','info','--format','{{.ServerVersion}}'])
 with tempfile.TemporaryDirectory(prefix='blot-sql-') as temporary:
  env=os.environ.copy();token=uuid.uuid4().hex[:10]
  for db,port in [('postgres',5432),('mysql',3306)]:
   name=f'blot-{db}-test-{token}'
   args=['docker','run','--detach','--name',name,'--label','blot.effect.test=true','--publish',f'127.0.0.1::{port}']
   options={'POSTGRES_PASSWORD':'blot_test_password','POSTGRES_DB':'blot_test'} if db=='postgres' else {'MYSQL_ROOT_PASSWORD':'blot_test_password','MYSQL_DATABASE':'blot_test'}
   for key,value in options.items():args += ['--env',f'{key}={value}']
   call(args+[IMAGES[db]]);created.append(name)
   mapped=call(['docker','port',name,f'{port}/tcp']).split(':')[-1]
   env['BLOT_PG_PORT' if db=='postgres' else 'BLOT_MYSQL_PORT']=mapped
   deadline=time.monotonic()+90
   while True:
    health=['pg_isready','--username','postgres','--dbname','blot_test'] if db=='postgres' else ['mysqladmin','ping','--host','127.0.0.1','-pblot_test_password','--silent']
    ready=subprocess.run(['docker','exec',name,*health],capture_output=True).returncode==0
    if ready:break
    if time.monotonic()>deadline:raise TimeoutError(f'{db} startup exceeded 90 seconds')
    time.sleep(1)
   if db=='mysql':
    cert=pathlib.Path(temporary)/'server-cert.pem'
    call(['docker','cp',f'{name}:/var/lib/mysql/server-cert.pem',str(cert)])
    env['BLOT_MYSQL_CERT_PATH']=str(cert)
  (ROOT/'build').mkdir(exist_ok=True)
  for package in ['blot_sql','blot_postgres','blot_mysql']:run_suite(package,env)
finally:
 cleanup=[]
 for name in reversed(created):
  result=subprocess.run(['docker','rm','--force','--volumes',name],capture_output=True,text=True)
  cleanup.append({'name':name,'exit_code':result.returncode})
 report['cleanup']=cleanup;report['containers_removed']=all(r['exit_code']==0 for r in cleanup)
 report['source_sha256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted([*ROOT.glob('lib/**/*.dart'),*ROOT.glob('packages/*/lib/**/*.dart'),*ROOT.glob('packages/*/test/**/*.dart')])}
 report['finished_at_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 output=ROOT/'docs/effect-port/sql-validation.json';output.write_text(json.dumps(report,indent=2)+'\n')
