"""Exercise packaged Claude commands without user Python or real provider data."""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
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
original = {'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'echo synthetic-user'}]}]},
            'statusLine': {'type': 'command', 'command': 'echo SYNTHETIC_RENDERER', 'padding': 2},
            'env': {'USER_SETTING': 'keep'}, 'userOption': {'preserve': True}}
environment = dict(os.environ)
environment.update(PATH=os.path.join(os.environ['SystemRoot'], 'System32'), HOME=str(fixture), USERPROFILE=str(fixture),
                   CLAUDE_CONFIG_DIR=str(homes[0]), LOCALAPPDATA=str(local), BASH_ENV='', ENV='',
                   PYTHONHOME=str(fixture/'untrusted-python'), PYTHONPATH=str(fixture/'untrusted-modules'))

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
    for home in homes:
        home.mkdir()
        (home/'settings.json').write_text(json.dumps(original), encoding='utf-8')
        report = json.loads(helper('--ensure', home, runtime))
        assert report['state']=='ready' and report['hooksConfigured']
        assert not (home/'pacer/runtime').exists()
    versions = [path for path in runtime.iterdir() if path.is_dir()]
    assert len(versions)==1 and (versions[0]/'python.exe').is_file()
    assert all(str(versions[0]/'python.exe').replace('\\','/') in hook_command(home) for home in homes)
    checks.append('two Claude homes share one owned LocalAppData runtime; no runtime copied into a Claude home')

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
        assert output.strip()==b'SYNTHETIC_RENDERER'
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
    assert all(not (home/'pacer/installation.json').exists() for home in homes)
    checks.append('shared uninstall discovers the second home, leaves exactly user settings, and deletes the owned runtime root')

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'schemaVersion':1,'syntheticOnly':True,'noUserPython':True,'checks':checks}, indent=2), encoding='utf-8')
    for check in checks:
        print('PASS '+check)
finally:
    if fixture.exists():
        assert fixture.resolve().is_relative_to((workspace/'out').resolve()) and fixture.name.startswith('pacer-claude-runtime-')
        shutil.rmtree(fixture)
