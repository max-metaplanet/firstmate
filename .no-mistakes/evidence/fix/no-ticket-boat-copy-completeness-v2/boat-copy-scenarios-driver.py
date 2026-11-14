import json, os, shlex, subprocess, sys, tempfile
from pathlib import Path
repo = Path(sys.argv[1]); base = Path(tempfile.mkdtemp(prefix='fm-boat-scn.'))
fixture = repo / 'tests/fixtures/boat-cli.py'
def git(root, *a): return subprocess.run(['git','-C',str(root),*a],check=True,capture_output=True).stdout.decode().strip()
def case(name):
    p = base/name; work = p/'work'; work.mkdir(parents=True)
    git(work,'init','-q','-b','main'); git(work,'config','user.name','F'); git(work,'config','user.email','f@example.invalid')
    (work/'tracked.txt').write_text('x\n')
    state = p/'home/state/boat-offload'; (state/'jobs').mkdir(parents=True); (state/'fixture.json').write_text('{}')
    w = p/'boat'; w.write_text('#!/bin/sh\nexec python3 '+shlex.quote(str(fixture))+' '+shlex.quote(str(state))+' "$@"\n'); w.chmod(0o755)
    user = p/'user'; (user/'.config/boat').mkdir(parents=True); (user/'.config/boat/api-key').write_text('boat_fixture_secret')
    env = dict(os.environ, HOME=str(user), FM_HOME=str(p/'home'), FM_BOAT_BIN=str(w)); [env.pop(k,None) for k in ('FM_BOAT_REUSE_ONLY','FM_TASK_ID','FM_TASK_GENERATION','NO_MISTAKES_EXECUTION_REF','NO_MISTAKES_EXECUTION_SOCKET','NODE_OPTIONS')]
    return p, work, state, env
def commit(work, msg):
    git(work,'add','-f','--all'); git(work,'commit','-qm',msg); return git(work,'rev-parse','HEAD')
def launch(p, env, cmd='exit 0', opts=()):
    r = subprocess.run(['bash',str(repo/'bin/fm-boat-run.sh'),'run','--worktree',str(p/'work'),'--output',str(p/'output'),*opts,'--','bash','-c',cmd],env=env,capture_output=True,timeout=60)
    return r
def show(title, p, state, r):
    print('\n=== '+title); print('exit:', r.returncode)
    for l in (r.stdout+r.stderr).decode().splitlines():
        if 'boat-offload' in l or 'REMOTE' in l or 'refused' in l or 'incomplete' in l: print('  |', l)
    print('provider calls made:', (state/'calls.jsonl').exists())
    m = p/'output/upload/history-exclusions.json'
    if m.exists(): print('exclusion manifest:', m.read_text().strip())
    if (p/'output/result.json').exists(): print('result.history:', json.loads((p/'output/result.json').read_text()).get('history'))
PG = ('COMPANY_NAME="Vercel Inc."\nSITE_NAME="Next.js Commerce"\nSHOPIFY_STORE_DOMAIN="[your-shopify-store-subdomain].myshopify.com"\n'
      '# bearer token, which core answers 401. Use the origin directly.\nMAIL_API_URL=https://metaplanet.jp\nREQUIRE_SECRET_IN_DEV=false\n'
      'SHOP_BASE_CURRENCY=JPY\nUSE_IN_MEMORY_TRACKER=false\nVERBOSE_CART_DISCOUNT_DEBUG=false\nSERVER_LOG_LEVEL=INFO\nSERVER_LOG_FORMAT=human\n'
      'NEXT_PUBLIC_CLIENT_LOG_ENABLED=false\nNEXT_PUBLIC_CLIENT_LOG_LEVEL=INFO\nNEXT_PUBLIC_CLIENT_LOG_FORMAT=human\nNEXT_PUBLIC_DEBUG_AUTO_LOG=false\n'
      'NEXT_PUBLIC_DEBUG_LOG_INTERVAL=5000\n# Debug log API secret (required for POST and GET requests to /api/debug-logs, passed as ?secret=)\nSHOPIFY_STOREFRONT_ACCESS_TOKEN=\n')
results = {}
# S1 synthetic: reviewed PlanetGear + root templates arrive byte-identical; real .env / .env.local / unknown populated not admitted
p, work, state, env = case('s1')
(work/'apps/planetgear').mkdir(parents=True); (work/'apps/planetgear/.env.example').write_text(PG)
(work/'.env.example').write_text('DATABASE_URL=\nAPI_TOKEN=\n'); (work/'.env').write_text('REAL=never-print-1\n'); (work/'.env.local').write_text('X=never-print-2\n')
commit(work,'c')
import hashlib; h = hashlib.sha256(PG.encode()).hexdigest()
r = launch(p, env, 'echo REMOTE pg-sha=$(sha256sum apps/planetgear/.env.example|cut -c1-64); echo REMOTE root=$(cat .env.example|tr "\\n" ";"); echo REMOTE env-present=$(ls -a | grep -c "^\\.env$"); echo REMOTE envlocal-present=$(ls -a | grep -c "^\\.env.local$")')
show('S1 synthetic: reviewed templates admitted byte-identical; .env/.env.local stay home (expected pg-sha='+h+')', p, state, r)
out = r.stdout.decode()
results['S1'] = r.returncode==0 and ('pg-sha='+h) in out and 'env-present=0' in out and 'envlocal-present=0' in out and b'never-print' not in r.stdout+r.stderr
# S2 adversarial: unknown populated default / changed reviewed value / private key comment in PlanetGear template
for tag, bad in [('unknown-populated', PG+'NEXT_PUBLIC_FOO=true\n'), ('changed-reviewed', PG.replace('SERVER_LOG_LEVEL=INFO','SERVER_LOG_LEVEL=never-print-DEBUG')),
                 ('secret-value', PG.replace('SHOPIFY_STOREFRONT_ACCESS_TOKEN=','SHOPIFY_STOREFRONT_ACCESS_TOKEN=shpat_never0print0aaaaaaaaaaaaaaaaaaaaaaa')),
                 ('key-block-comment', PG+'# -----BEGIN RSA PRIVATE KEY-----\n')]:
    for hist in (False, True):
        p, work, state, env = case('s2-'+tag+'-'+str(hist))
        (work/'apps/planetgear').mkdir(parents=True); (work/'apps/planetgear/.env.example').write_text(bad)
        c = commit(work,'c'); git(work,'update-ref','refs/remotes/origin/main',c)
        r = launch(p, env, 'echo REMOTE pg-present=$(test -e apps/planetgear/.env.example && echo yes || echo no)', ('--history-depth','1') if hist else ())
        show('S2 %s history=%s'%(tag,hist), p, state, r)
        m = p/'output/upload/history-exclusions.json'
        ev = json.loads(m.read_text())['objects'] if m.exists() else []
        okm = any(o['path']=='apps/planetgear/.env.example' and o['rule']=='template-content' and set(o)=={'oid','path','commit','rule'} for o in ev)
        clean = b'never-print' not in r.stdout+r.stderr and (not m.exists() or 'never-print' not in m.read_text())
        if hist: results['S2-'+tag+'-hist'] = r.returncode==2 and not (state/'calls.jsonl').exists() and okm and clean
        else: results['S2-'+tag+'-synthetic'] = r.returncode==0 and b'pg-present=no' in r.stdout and okm and clean and b'history' not in r.stderr
# S3 report reproduction: historical root .env.example blobs must travel with selected history
p, work, state, env = case('s3')
(work/'.env.example').write_text('API_URL=\n'); c1 = commit(work,'v1'); old1 = git(work,'rev-parse','HEAD:.env.example')
(work/'.env.example').write_text('API_URL=\nLOG=\n'); commit(work,'v2'); old2 = git(work,'rev-parse','HEAD:.env.example')
(work/'.env.example').write_text('API_URL=\nLOG=\nMODE=\n'); c3 = commit(work,'v3')
git(work,'update-ref','refs/remotes/origin/main',c3)
r = launch(p, env, f'git cat-file -e {old1} && git cat-file -e {old2} && git log -p --oneline -- .env.example >/dev/null && git fsck --full --no-reflogs && test -z "$(git config extensions.partialclone)" && git clone -q . ../cl && echo REMOTE historical-blobs-ok', ('--history-depth','3'))
show('S3 history-depth=3: historical .env.example blobs %s %s present, fsck clean, no promisor, ordinary clone works'%(old1[:8],old2[:8]), p, state, r)
results['S3'] = r.returncode==0 and b'historical-blobs-ok' in r.stdout
# S4 adversarial: historical real .env refuses locally before allocation with content-free manifest
p, work, state, env = case('s4')
(work/'.env').write_text('PASSWORD=never-print-hist\n'); c1 = commit(work,'leak')
git(work,'rm','-q','.env'); c2 = commit(work,'remove'); git(work,'update-ref','refs/remotes/origin/main',c2)
r = launch(p, env, 'echo REMOTE should-not-run', ('--history-depth','2'))
show('S4 historical .env in selected history', p, state, r)
ev = json.loads((p/'output/upload/history-exclusions.json').read_text())['objects']
results['S4'] = r.returncode==2 and not (state/'calls.jsonl').exists() and any(o['path']=='.env' and o['commit']==c1 and o['rule']=='excluded-path' for o in ev) and b'never-print' not in r.stdout+r.stderr and 'never-print' not in json.dumps(ev) and not (p/'output/upload/source.tar.gz').exists()
# S5 adversarial: blanket test-file admission must not happen — test fixture with a credential
p, work, state, env = case('s5')
(work/'tests').mkdir(); (work/'tests/fixture.env').write_text('AWS_SECRET=never-print-fixture\n'); (work/'tests/.env.test').write_text('K=never-print-fixture2\n')
commit(work,'tests')
r = launch(p, env, 'echo REMOTE fixture-env=$(test -e tests/.env.test && echo yes || echo no)')
show('S5 test .env.test not blanket-admitted', p, state, r)
results['S5'] = r.returncode==0 and b'fixture-env=no' in r.stdout
print('\n=== SUMMARY'); [print(k, 'PASS' if v else 'FAIL') for k,v in results.items()]
subprocess.run(['rm','-rf',str(base)])
sys.exit(0 if all(results.values()) else 1)
