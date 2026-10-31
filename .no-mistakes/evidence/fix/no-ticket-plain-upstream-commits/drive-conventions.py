import os, pathlib, subprocess, tempfile, shutil, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M69MFQ8X8XAHRAZ9PNXNTDR2')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.test-conventions-',dir=root))
results=[]
transcript=[]
def run(args,env=None):
    p=subprocess.run([str(a) for a in args],cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    if p.returncode: raise RuntimeError(f'{args}: exit {p.returncode}\n{p.stdout}')
    return p.stdout
def case(name,origin='https://github.com/vendor/upstream.git',upstream=None,declaration='github.com/our-org\n',plain=True,ticket='no-ticket',explicit=False,promote=False):
    home=lab/name
    for d in ('data','state','config','projects'): (home/d).mkdir(parents=True)
    project=home/'projects'/'sample'
    run(['git','init','-q',project])
    if origin: run(['git','-C',project,'remote','add','origin',origin])
    if upstream: run(['git','-C',project,'remote','add','upstream',upstream])
    if declaration is not None: (home/'config'/'our-organizations').write_text(declaration)
    env={k:v for k,v in os.environ.items() if k not in ('FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE')}
    env['FM_HOME']=str(home)
    ident='scenario-'+name
    if promote:
        task=home/'data'/ident
        task.mkdir()
        (task/'brief.md').write_text("You are a crewmate.\n\n# Task\n## Captain's intent\nInvestigate the upstream bug.\n\n## Firstmate spec\nReport findings.\n")
        (home/'state'/f'{ident}.meta').write_text(f'window=fm-{ident}\nkind=scout\nproject={project}\nworktree={project}\n')
        args=[root/'bin/fm-promote.sh',ident,'--mode','no-mistakes','--ticket',ticket,'--commit-type','fix','--yolo','off']
        output=run(args,env)
        generated=task/'ship-instructions.md'
    else:
        args=[root/'bin/fm-brief.sh',ident,'sample','--mode','no-mistakes','--ticket',ticket,'--commit-type','fix']
        if explicit: args+=['--project',project]
        output=run(args,env)
        generated=home/'data'/ident/'brief.md'
    text=generated.read_text()
    # Oracle: author intent, amended by the two recorded declined findings.
    # Reject a ticket-bearing subject for a declared third-party destination,
    # or removal of the legacy subject when ownership is ours/undetermined.
    expected=f'fix(<scope>): <message>' if plain else f'fix/{ticket}(<scope>): <message>'
    assert f'must read `{expected}`' in text, (name,expected)
    assert f'fix/{ticket}-{ident}' in text, (name,'branch changed')
    if plain:
        assert 'never add a ticket segment' in text
        assert "leave the published branch's pipeline commits alone" in text
        assert 'edit it ONCE only if it carries a ticket segment or a pipeline-internal' in text
        assert f'insert `/{ticket}`' not in text
    else: assert f'insert `/{ticket}`' in text
    if ticket!='no-ticket':
        assert f'Ticket: {ticket}' in text
        assert f'read ticket {ticket} in full' in text
    if promote:
        meta=(home/'state'/f'{ident}.meta').read_text()
        assert 'kind=ship\n' in meta
        assert f'must read `{expected}`' in (home/'data'/ident/'brief.md').read_text()
    dest=evidence/f'{name}.md'
    dest.write_text(text)
    relevant=[line for line in text.splitlines() if any(token in line for token in ('Every commit subject','never add a ticket','edit it ONCE','leave the published','Ship branch:','Ticket:','read ticket '+ticket))]
    transcript.append(f'CASE {name}\norigin={origin}\nupstream={upstream}\ndeclaration={declaration!r}\ncommand='+' '.join(str(a).replace(str(lab),'<disposable>') for a in args)+'\nexit=0\n'+'\n'.join(relevant)+'\n')
    results.append({'case':name,'result':'pass','generated_contract':str(dest)})
try:
    case('third-party-fallback')
    case('third-party-explicit',explicit=True)
    case('third-party-real-ticket',ticket='ENG-42')
    case('owned',origin='git@github.com:OUR-ORG/ours.git',plain=False)
    case('owner-prefix-adversary',origin='https://github.com/our-org-extra/upstream.git')
    case('fork-to-third-party',origin='https://github.com/our-org/fork.git',upstream='git@github.com:vendor/upstream.git')
    case('outside-origin-owned-upstream',upstream='https://github.com/our-org/upstream.git',plain=False)
    case('missing-declaration',declaration=None,plain=False)
    case('malformed-declaration',declaration='github.com/our-org\nnot-a-path\n',plain=False)
    case('missing-remote',origin=None,plain=False)
    case('promote-third-party',promote=True)
    case('promote-owned',origin='https://github.com/our-org/ours.git',plain=False,promote=True)
    case('promote-real-ticket',ticket='ENG-42',promote=True)
    (evidence/'convention-cli-transcript.txt').write_text('\n'.join(transcript))
    (evidence/'convention-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2))
finally:
    shutil.rmtree(lab)
