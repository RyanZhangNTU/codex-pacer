"""Exercise packaged Claude commands without user Python or real provider data."""
import argparse
import base64
import concurrent.futures
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--bundle', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
workspace = Path(__file__).resolve().parents[2]
fixture = workspace / 'out' / ('pacer-claude-runtime-' + uuid.uuid4().hex[:8])
app = fixture / '安装 空格' / 'Engine'
homes = [fixture / 'Claude 一号', fixture / 'Claude 二号']
local = fixture / '本地 数据'
runtime = local / 'CodexPacer' / 'ClaudeRuntime'
checks = []
timings = []
original = {'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'echo synthetic-user'}]}]},
            'statusLine': {'type': 'command', 'command': 'echo SYNTHETIC_RENDERER', 'padding': 2},
            'env': {'USER_SETTING': 'keep'}, 'userOption': {'preserve': True}}
environment = dict(os.environ)
system = Path(os.environ['SystemRoot'])/'System32'
environment.update(PATH=str(system)+os.pathsep+str(system/'WindowsPowerShell/v1.0'), HOME=str(fixture), USERPROFILE=str(fixture),
                   CLAUDE_CONFIG_DIR=str(homes[0]), LOCALAPPDATA=str(local), BASH_ENV='', ENV='',
                   PYTHONHOME=str(fixture/'untrusted-python'), PYTHONPATH=str(fixture/'untrusted-modules'))
for key in ('MSYS_NO_PATHCONV','MSYS2_ARG_CONV_EXCL','MSYS2_ENV_CONV_EXCL'):
    environment.pop(key,None)
assert all(shutil.which(name,path=environment['PATH']) is None for name in ('python','python3','py'))

def short_path(path):
    function=ctypes.WinDLL('kernel32',use_last_error=True).GetShortPathNameW
    function.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint32]
    function.restype=ctypes.c_uint32
    buffer=ctypes.create_unicode_buffer(32768)
    count=function('\\\\?\\'+str(path),buffer,len(buffer))
    if not 0<count<len(buffer): return None
    return Path(buffer.value.removeprefix('\\\\?\\'))

def direct_safe(path):
    value=str(path).replace('\\','/')
    return len(value)>3 and value[1:3]==':/' and all(c.isalnum() or c in '/._~-:' for c in value)

def fallback_command(python,home,mode):
    values=[python.parent/'pacer-launch.ps1',python,'no-site',home/'pacer/hook.py',mode,home]
    buffer=ctypes.create_unicode_buffer(32768)
    count=ctypes.WinDLL('kernel32',use_last_error=True).GetSystemDirectoryW(buffer,len(buffer))
    assert 0<count<len(buffer)
    shell=str(Path(buffer.value)/'WindowsPowerShell/v1.0/powershell.exe').replace('\\','/')
    return shell+' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File '+ ' '.join('"'+str(value).replace('\\','/')+'"' for value in values)

def select_slow_form(home,python):
    value=settings(home)
    old=hook_command(home)
    for groups in value['hooks'].values():
        for group in groups:
            for entry in group.get('hooks',[]):
                if entry.get('command')==old:entry['command']=fallback_command(python,home,'hook')
    value['statusLine']['command']=fallback_command(python,home,'statusline')
    (home/'settings.json').write_text(json.dumps(value),encoding='utf-8')

def run(arguments, raw=None, shell=None, expected=0):
    result = subprocess.run(arguments, executable=shell, input=raw, env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    assert result.returncode == expected, 'A synthetic runtime command failed; provider contents were not logged'
    assert not result.stderr, 'A runtime command returned diagnostics'
    return result.stdout

def helper(operation, *values, expected=0):
    return run([str(app/'PacerInstallerHooks.exe'), operation, *map(str, values)], expected=expected)

def settings(home):
    return json.loads((home/'settings.json').read_bytes())

def hook_command(home):
    return settings(home)['hooks']['SessionStart'][0]['hooks'][0]['command']

def failure_probe(home, python):
    # Only fixed stage names, booleans and numeric Win32 facts leave this
    # synthetic fixture. Never forward paths, settings bytes or command output.
    probe = r'''
import ctypes,importlib.util,json,os,sys
from pathlib import Path
home=Path(sys.argv[1]); spec=importlib.util.spec_from_file_location('pacer_probe',home/'pacer/hook.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
facts={'stage':'owners'}
try:
    module.current_owners()
    original_info=module.file_information
    def information(handle, pointer):
        result=original_info(handle,pointer)
        facts['fileInfo']=bool(result)
        if result:
            facts['links']=pointer._obj.links;facts['attributes']=pointer._obj.attributes
        else: facts['infoError']=ctypes.get_last_error()
        return result
    module.file_information=information
    facts['stage']='read-manifest'
    descriptor=module.private_open(home/'pacer/installation.json',os.O_RDONLY)
    with os.fdopen(descriptor,'rb') as stream: manifest=json.load(stream)
    facts['previousRenderer']=isinstance(manifest.get('previousStatusLine'),dict)
    facts['stage']='create-write-file'
    path=home/'pacer/synthetic-probe.tmp'
    descriptor=module.private_open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY)
    os.close(descriptor);path.unlink()
    facts['stage']='shared-statusline'
    capture=home/'pacer/synthetic-renderer-probe.out'
    original_stdout=sys.stdout
    try:
        with capture.open('w') as stream:
            sys.stdout=stream;sys.argv=[str(home/'pacer/hook.py'),'statusline',str(home)]
            module.run()
    finally: sys.stdout=original_stdout
    rendered=capture.read_bytes();capture.unlink()
    facts['rendererBytes']=len(rendered);facts['rendererMatches']=rendered.strip()==b'SYNTHETIC_RENDERER'
    facts['stage']='probe-complete'
except Exception as error:
    facts['error']=ctypes.get_last_error();facts['errno']=getattr(error,'errno',None)
    facts['errorType']=type(error).__name__
print(json.dumps(facts,sort_keys=True))
'''
    raw=b'{"rate_limits":{"five_hour":{"used_percentage":45,"resets_at":1890000000}}}'
    return run([str(python), '-S', '-c', probe, str(home)],raw).decode('ascii').strip()

def execute(command, value, shell):
    raw = json.dumps(value, ensure_ascii=False).encode('utf-8')
    if shell == 'cmd':
        cmd = str(Path(os.environ['SystemRoot'])/'System32/cmd.exe')
        return run('"'+cmd+'" /d /s /c "'+command+'"', raw, cmd)
    if shell == 'bash':
        bash = Path(os.environ.get('ProgramFiles', 'C:/Program Files'))/'Git/bin/bash.exe'
        assert bash.is_file(), 'Git Bash is required for the Windows command contract check'
        return run([str(bash), '--noprofile', '--norc', '-c', command], raw)
    powershell = Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
    return run([str(powershell), '-NoProfile', '-NonInteractive', '-Command', command], raw)

try:
    fixture.mkdir(parents=True)
    assert fixture.resolve().is_relative_to((workspace/'out').resolve())
    shutil.copytree(args.bundle, app)
    modes={}
    for home in homes:
        home.mkdir()
        (home/'settings.json').write_text(json.dumps(original), encoding='utf-8')
        report = json.loads(helper('--ensure', home, runtime))
        assert report['state']=='ready' and report['hooksConfigured']
        modes[str(home)]=report['launchMode']
        assert not (home/'pacer/runtime').exists()
    versions = [path for path in runtime.iterdir() if path.is_dir()]
    assert len(versions)==1 and (versions[0]/'python.exe').is_file()
    for home in homes:
        python=versions[0]/'python.exe'
        if modes[str(home)]=='shortPath':
            assert hook_command(home).startswith(str(short_path(python)).replace('\\','/')+' -S ')
        else:assert str(python).replace('\\','/') in hook_command(home)
    checks.append('two Claude homes share one owned LocalAppData runtime; no runtime copied into a Claude home')
    probe = json.loads(failure_probe(homes[0], versions[0]/'python.exe'))
    assert probe.get('stage')=='probe-complete' and probe.get('rendererMatches'), json.dumps(probe,sort_keys=True)
    long_home = fixture/'Claude home'
    # Hosted CI can have a much shorter checkout root than a local worktree.
    while len(str(long_home))<=300:
        long_home = long_home.parent/'长路径 空格 segment'/'Claude home'
    assert len(str(long_home))>260
    long_home.mkdir(parents=True)
    (long_home/'settings.json').write_text(json.dumps(original),encoding='utf-8')
    assert json.loads(helper('--ensure',long_home,runtime))['state']=='ready'
    assert execute(hook_command(long_home),{'session_id':'fixture-long-path','hook_event_name':'UserPromptSubmit',
        'prompt_id':'fixture-long-prompt'},'cmd')==b''
    long_rows=[json.loads(line) for line in (long_home/'pacer/events.jsonl').read_bytes().splitlines()]
    assert any(row.get('kind')=='prompt' and row.get('promptId')=='fixture-long-prompt' for row in long_rows)
    checks.append('actual configured hook runs from a Chinese/space Claude home beyond MAX_PATH')

    # Inputs follow the common fields/UserPromptSubmit/PreToolUse examples in
    # https://code.claude.com/docs/en/hooks; bodies below are synthetic.
    for shell in ('cmd','bash','powershell'):
        home = homes[0]
        command = hook_command(home)
        session = 'fixture-'+shell
        assert execute(command, {'session_id':session, 'transcript_path':str(fixture/'synthetic.jsonl'),
            'cwd':str(fixture/'synthetic-project'), 'permission_mode':'default',
            'hook_event_name':'UserPromptSubmit', 'prompt':'SYNTHETIC_PRIVATE_BODY',
            'prompt_id':'fixture-prompt-'+shell}, shell)==b''
        assert execute(command, {'session_id':session, 'hook_event_name':'PreToolUse', 'tool_name':'Read',
            'tool_use_id':'fixture-tool-'+shell, 'tool_input':{'file_path':'SYNTHETIC_PRIVATE_TOKEN'}}, shell)==b''
        assert execute(command, {'session_id':session, 'hook_event_name':'PermissionRequest',
            'tool_name':'Read', 'tool_use_id':'fixture-tool-'+shell}, shell)==b''
        line = settings(home)['statusLine']['command']
        output = execute(line, {'rate_limits':{'five_hour':{'used_percentage':45,'resets_at':1890000000}},
                               'access_token':'SYNTHETIC_PRIVATE_TOKEN'}, shell)
        assert output.strip()==b'SYNTHETIC_RENDERER', ('Previous renderer failed in '+shell+
            '; outputBytes='+str(len(output))+'; cache='+str((home/'pacer/claude-statusline.json').exists())+
            '; spool='+str((home/'pacer/events.jsonl').exists())+'; '+failure_probe(home,versions[0]/'python.exe'))
    rows = [json.loads(line) for line in (homes[0]/'pacer/events.jsonl').read_bytes().splitlines()]
    for shell in ('cmd','bash','powershell'):
        owned = [row for row in rows if row.get('sessionId')=='fixture-'+shell]
        assert {'prompt','toolStart','approval'} <= {row.get('kind') for row in owned}
        assert all(row.get('promptId')=='fixture-prompt-'+shell for row in owned if row.get('kind')!='metadata')
    cache = json.loads((homes[0]/'pacer/claude-statusline.json').read_bytes())
    assert cache['payload']['rate_limits']['five_hour']['used_percentage']==45
    for home in homes:
        for path in (home/'pacer').glob('*.json*'):
            assert b'SYNTHETIC_PRIVATE_BODY' not in path.read_bytes() and b'SYNTHETIC_PRIVATE_TOKEN' not in path.read_bytes()
    checks.append('identical configured commands work in cmd, Git Bash and PowerShell; UTF-8 input, Chinese/space paths, tool/approval ownership and previous renderer preserved')
    checks.append('isolated PATH has no python/python3/py; prompt bodies, tool input and tokens absent from spool and quota cache')

    # The native argv probe reports only fixed booleans. No command line or
    # provider path leaves the synthetic fixture. Old /D/C becomes D:/C even
    # on machines where cmd happens to interpret the converted text usefully.
    native=versions[0]/'python.exe'
    program='import base64,json,sys;print(json.dumps({"convertedD":sys.argv[1].lower()=="d:/c","unchanged":sys.argv[1]=="/D/C","absolutePathPreserved":sys.argv[2]==base64.b64decode(sys.argv[3]).decode("utf-8")}))'
    absolute=str(native).replace('\\','/')
    probe='"'+absolute+'" -S -c \''+program+'\' /D/C "'+absolute+'" '+base64.b64encode(absolute.encode('utf-8')).decode('ascii')
    facts=json.loads(execute(probe,{},'bash'))
    assert facts['absolutePathPreserved'] and facts['convertedD']!=facts['unchanged'], facts
    print('Native argv probe '+json.dumps(facts,sort_keys=True))

    routes=[]
    if modes[str(homes[0])]=='shortPath':routes.append(('shortPath',homes[0],runtime))
    safe=fixture if direct_safe(fixture) else short_path(fixture)
    direct_runtime=None
    if safe is not None and direct_safe(safe):
        direct_home=safe/'ClaudeDirect';direct_home.mkdir()
        (direct_home/'settings.json').write_text(json.dumps(original),encoding='utf-8')
        direct_runtime=safe/'Direct/CodexPacer/ClaudeRuntime'
        direct_report=json.loads(helper('--ensure',direct_home,direct_runtime))
        assert direct_report['state']=='ready' and direct_report['launchMode']=='direct'
        routes.append(('direct',direct_home,direct_runtime))
    slow_home=long_home.parent/"PowerShell O'Neil (fallback) 用户";slow_home.mkdir()
    (slow_home/'settings.json').write_text(json.dumps(original),encoding='utf-8')
    assert json.loads(helper('--ensure',slow_home,runtime))['state']=='ready'
    select_slow_form(slow_home,native)
    slow_status=json.loads(helper('--inspect',slow_home,runtime))
    assert slow_status['hooksConfigured'] and slow_status['statusLineConfigured']
    routes.append(('powershell',slow_home,runtime))
    for mode,home,_ in routes:
        for shell in ('cmd','bash','powershell'):
            elapsed=[]
            for index in range(5):
                started=time.perf_counter()
                assert execute(hook_command(home),{'session_id':'fixture-'+mode+'-'+shell,
                    'hook_event_name':'UserPromptSubmit','prompt_id':'timing-'+str(index),
                    'cwd':str(fixture/'synthetic-中文')},shell)==b''
                elapsed.append((time.perf_counter()-started)*1000)
            assert execute(settings(home)['statusLine']['command'],{},shell).strip()==b'SYNTHETIC_RENDERER'
            result={'mode':mode,'executor':shell,'samples':len(elapsed),'hookMedianMs':round(statistics.median(elapsed),1),
                    'hookMinimumMs':round(min(elapsed),1),'hookMaximumMs':round(max(elapsed),1)}
            timings.append(result)
            print('Launch timing '+json.dumps(result,sort_keys=True))
        observed=[json.loads(line) for line in (home/'pacer/events.jsonl').read_bytes().splitlines()]
        assert any(row.get('promptId')=='timing-4' and row.get('project')=='synthetic-中文' for row in observed)
        spool=(home/'pacer/events.jsonl').read_bytes()
        for shell in ('cmd','bash','powershell'):
            assert execute(hook_command(home),{'synthetic_oversize':'x'*(2*1024*1024)},shell)==b''
        assert (home/'pacer/events.jsonl').read_bytes()==spool
    manifest_path=slow_home/'pacer/installation.json'
    before_manifest=manifest_path.read_bytes()
    renderer=fixture/'synthetic-renderer.py'
    rendered='SYNTHETIC_RENDERER 中文'.encode('utf-8')
    renderer.write_text('import json,sys\nassert json.load(sys.stdin.buffer)["synthetic_utf8"]=="\\u4e2d\\u6587"\nsys.stdout.buffer.write(bytes.fromhex('+repr(rendered.hex())+'))\n',encoding='utf-8')
    try:
        manifest=json.loads(before_manifest)
        manifest['previousStatusLine']={'type':'command','command':'"'+str(native)+'" -S "'+str(renderer)+'"'}
        manifest_path.write_text(json.dumps(manifest),encoding='utf-8')
        for shell in ('bash','powershell'):
            assert execute(settings(slow_home)['statusLine']['command'],{'synthetic_utf8':'中文'},shell)==rendered
    finally:manifest_path.write_bytes(before_manifest)
    checks.append('PowerShell fallback forwards UTF-8 input and previous status-line output as unchanged bytes; oversized input retains the shared silent rejection and writes no records')
    checks.append('direct, available 8.3 and forced no-8.3 PowerShell commands exercise hook/statusLine under every executor; per-call latency recorded')

    home = homes[0]
    python = versions[0]/'python.exe'
    script = home/'pacer/hook.py'
    def direct(value):
        return run([str(python), '-S', str(script), 'hook', str(home)], json.dumps(value).encode('utf-8'))
    session = 'fixture-concurrent'
    assert direct({'session_id':session, 'hook_event_name':'UserPromptSubmit', 'prompt_id':'fixture-concurrent-prompt'})==b''
    tools = ['fixture-concurrent-tool-'+str(index) for index in range(20)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        outputs = list(pool.map(lambda tool: direct({'session_id':session, 'hook_event_name':'PreToolUse',
            'tool_use_id':tool, 'tool_name':'Read'}), tools))
    assert all(output==b'' for output in outputs)
    rows = [json.loads(line) for line in (home/'pacer/events.jsonl').read_bytes().splitlines()]
    owned = [row for row in rows if row.get('sessionId')==session]
    assert sum(row.get('kind')=='prompt' for row in owned)==1
    assert {row.get('itemId') for row in owned if row.get('kind')=='toolStart'}==set(tools)
    assert all(row.get('promptId')=='fixture-concurrent-prompt' for row in owned if row.get('kind')=='toolStart')
    spec = importlib.util.spec_from_file_location('pacer_runtime_test', script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.current_owners()
    descriptor = module.private_open(home/'pacer/events.lock', os.O_CREAT|os.O_RDWR)
    module.flock(descriptor, 2)
    before_events = (home/'pacer/events.jsonl').read_bytes()
    started = time.monotonic()
    try:
        assert direct({'session_id':session, 'hook_event_name':'Stop'})==b''
    finally:
        for handle in reversed(module.held_mutexes):
            module.release_mutex(handle); module.close(handle)
        module.held_mutexes.clear()
        os.close(descriptor)
    assert 1.8 < time.monotonic()-started < 4.5
    assert (home/'pacer/events.jsonl').read_bytes()==before_events
    state = home/'pacer/hook-state.json'
    linked = fixture/'synthetic-user-state.json'
    os.link(state, linked)
    before_state = state.read_bytes()
    assert direct({'session_id':session, 'hook_event_name':'Stop'})==b''
    assert state.read_bytes()==before_state and linked.read_bytes()==before_state
    linked.unlink()
    checks.append('twenty concurrent tools retain prompt ownership; contended kernel lock times out without polling; linked state is rejected before truncation')

    # Junctions do not require a developer-mode or elevation prompt. Both ends
    # are synthetic paths in this owned fixture; never follow one during setup.
    unsafe_home = fixture/'Claude junction'
    cmd = str(Path(os.environ['SystemRoot'])/'System32/cmd.exe')
    run([cmd, '/d', '/c', 'mklink', '/J', str(unsafe_home), str(homes[0])])
    unchanged = (homes[0]/'settings.json').read_bytes()
    try:
        assert json.loads(helper('--ensure', unsafe_home, runtime, expected=1))['state']=='failed'
        assert (homes[0]/'settings.json').read_bytes()==unchanged
    finally:
        os.rmdir(unsafe_home)
    foreign_root = fixture/'foreign/ClaudeRuntime'
    foreign_root.mkdir(parents=True)
    foreign_file = foreign_root/'user-file.txt'
    foreign_file.write_bytes(b'synthetic user bytes')
    assert json.loads(helper('--ensure', homes[0], foreign_root, expected=1))['state']=='failed'
    assert foreign_file.read_bytes()==b'synthetic user bytes' and (homes[0]/'settings.json').read_bytes()==unchanged
    checks.append('reparse-point home and unclaimed nonempty runtime are rejected without modifying user bytes')

    before = [(home/'settings.json').read_bytes() for home in homes]
    expected = (app/'Python/_ctypes.pyd').read_bytes()
    (versions[0]/'_ctypes.pyd').write_bytes(b'synthetic damaged runtime')
    assert json.loads(helper('--ensure', homes[0], runtime))['state']=='ready'
    assert (versions[0]/'_ctypes.pyd').read_bytes()==expected
    moved = fixture/'移动 安装'/'Engine'
    moved.parent.mkdir()
    assert app.resolve().is_relative_to(fixture.resolve()) and moved.resolve().is_relative_to(fixture.resolve())
    app.rename(moved)
    app = moved
    assert json.loads(helper('--ensure', homes[0], runtime))['state']=='ready'
    assert [(home/'settings.json').read_bytes() for home in homes]==before
    checks.append('repair restores a damaged runtime; moving the application leaves both configured commands unchanged')

    helper('--check-uninstall-all', runtime, homes[0])
    assert runtime.exists() and [(home/'settings.json').read_bytes() for home in homes]==before
    helper('--uninstall-all', runtime, homes[0])
    assert not runtime.exists()
    assert all(settings(home)==original for home in homes)
    assert settings(long_home)==original and not (long_home/'pacer/installation.json').exists()
    assert settings(slow_home)==original and not (slow_home/'pacer/installation.json').exists()
    if direct_runtime is not None:
        helper('--uninstall-all',direct_runtime,direct_home)
        assert not direct_runtime.exists() and settings(direct_home)==original
    assert all(not (home/'pacer/installation.json').exists() for home in homes)
    checks.append('shared uninstall discovers the second home, leaves exactly user settings, and deletes the owned runtime root')

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'schemaVersion':1,'syntheticOnly':True,'noUserPython':True,'checks':checks,'launchTimings':timings}, indent=2), encoding='utf-8')
    for check in checks:
        print('PASS '+check)
finally:
    if fixture.exists():
        assert fixture.resolve().is_relative_to((workspace/'out').resolve()) and fixture.name.startswith('pacer-claude-runtime-')
        shutil.rmtree(fixture)
