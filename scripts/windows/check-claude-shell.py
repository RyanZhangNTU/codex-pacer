"""Check the Windows adapter before compiling, using only synthetic data."""
import argparse
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import uuid

parser=argparse.ArgumentParser()
parser.add_argument('--bash',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
fixture=root/'out'/('pacer-shell-check-'+uuid.uuid4().hex[:8])
home=fixture/'Claude 用户 space'
system=Path(os.environ['SystemRoot'])/'System32'
bash=args.bash or Path(os.environ['ProgramFiles'])/'Git/bin/bash.exe'
powershell=system/'WindowsPowerShell/v1.0/powershell.exe'
environment=dict(os.environ)
for key in ('MSYS_NO_PATHCONV','MSYS2_ARG_CONV_EXCL','MSYS2_ENV_CONV_EXCL','PYTHONHOME','PYTHONPATH'):
    environment.pop(key,None)
environment.update(PATH=str(system),HOME=str(fixture),USERPROFILE=str(fixture),LOCALAPPDATA=str(fixture/'local'),BASH_ENV='',ENV='')
probe=r'''
import ctypes,importlib.util,json,os,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1]); output=Path(sys.argv[2])
facts={'defaultShellIsCmd':subprocess.run('exit /b 23',shell=True,input=b'',capture_output=True,timeout=2).returncode==23}
spec=importlib.util.spec_from_file_location('pacer_shell_check',home/'pacer/hook.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
for elevated in (False,True):
    for enabled in (False,True):
        assert module.owner_allowed(True,False,elevated,enabled)
        assert module.owner_allowed(False,True,elevated,enabled)==(elevated and enabled)
        assert not module.owner_allowed(False,False,elevated,enabled)
facts['ownerPolicyCasesPassed']=True
original_owner=module.own_file
original_run=subprocess.run
def observe(arguments,*positional,**options):
    if options.get('timeout')==10:
        facts['rendererTimeoutIsTen']=True
        facts['rendererUsesCmd']=isinstance(arguments,list) and Path(arguments[0]).name.lower()=='cmd.exe'
        facts['rendererUsesExpectedShell']=isinstance(arguments,list) and Path(arguments[0]).name.lower()==sys.argv[3]+'.exe'
        facts['rendererInputIsBytes']=isinstance(options.get('input'),bytes)
        facts['rendererShellFalse']=options.get('shell') is False
    return original_run(arguments,*positional,**options)
subprocess.run=observe
def owner(handle):
    sid=module.w.LPVOID();descriptor=module.w.LPVOID()
    if module.get_security(handle,1,1,ctypes.byref(sid),None,None,None,ctypes.byref(descriptor))==0:
        try:
            facts['ownerMatchesUser']=bool(module.equal_sid(sid,module.owners[0][1]))
            facts['ownerMatchesTokenOwner']=bool(module.equal_sid(sid,module.owners[1][1]))
            facts['ownerMatchesAdministrators']=bool(module.equal_sid(sid,module.administrator_sid))
            facts['tokenOwnerIsUser']=bool(module.equal_sid(module.owners[0][1],module.owners[1][1]))
            facts['tokenElevated']=module.elevated
            facts['administratorsEnabled']=module.administrators_enabled
        finally:module.local_free(descriptor)
    return original_owner(handle)
module.own_file=owner
try:
    expected=sys.argv[3]
    sys.argv=[str(home/'pacer/hook.py'),'statusline',str(home),expected]
    module.run()
    facts['completed']=True
except Exception as error:
    facts['errorType']=type(error).__name__;facts['winerror']=getattr(error,'winerror',None)
finally:
    subprocess.run=original_run
    output.write_text(json.dumps(facts,sort_keys=True),encoding='utf-8')
'''

def quote_ps(value):return "'"+str(value).replace("'","''")+"'"

try:
    (home/'pacer').mkdir(parents=True)
    shared=(root/'native/Sources/PacerCore/Resources/claude_hook.py').read_bytes()
    adapter=(root/'windows/InstallerSupport/Resources/windows_claude_bootstrap.py').read_bytes()
    (home/'pacer/hook.py').write_bytes(b"SHARED_SOURCE = '"+base64.b64encode(shared)+b"'\n"+adapter)
    program=fixture/'probe.py';program.write_text(probe,encoding='utf-8')
    for executor,renderer in [
        ('bash','if [ -n "$BASH_VERSION" ]; then printf "%s" SYNTHETIC_RENDERER; fi'),
        ('powershell',"Write-Output ('SYNTHETIC_' + 'RENDERER')")]:
        (home/'pacer/installation.json').write_text(json.dumps({'previousStatusLine':{'type':'command','command':renderer}}),encoding='utf-8')
        report=fixture/(executor+'.json')
        env=dict(environment)
        values=[str(Path(sys.executable).resolve()).replace('\\','/'),'-S',str(program).replace('\\','/'),str(home).replace('\\','/'),str(report).replace('\\','/'),executor]
        if executor=='bash':
            assert bash.is_file(), 'Git Bash is required for this contract'
            env['CLAUDE_CODE_GIT_BASH_PATH']=str(bash.resolve())
            command=[str(bash),'--noprofile','--norc','-c',' '.join(shlex.quote(value) for value in values)]
        else:
            # Model Claude's no-Git fallback without changing the machine.
            env['CLAUDE_CODE_GIT_BASH_PATH']=str(fixture/'missing-bash.exe')
            command=[str(powershell),'-NoProfile','-NonInteractive','-Command','& '+' '.join(quote_ps(value) for value in values)]
        payload=b'{"rate_limits":{"five_hour":{"used_percentage":45,"resets_at":1890000000}}}'
        result=subprocess.run(command,input=payload,env=env,capture_output=True,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
        facts=json.loads(report.read_bytes()) if report.exists() else {'reportMissing':True}
        facts.update(executor=executor,exit=result.returncode,outputBytes=len(result.stdout),errorBytes=len(result.stderr),rendererMatches=result.stdout.strip()==b'SYNTHETIC_RENDERER')
        print(json.dumps(facts,sort_keys=True),flush=True)
        assert result.returncode==0 and not result.stderr and facts.get('completed') and facts['rendererMatches'], 'Synthetic shell forwarding failed; only fixed facts were logged'
        assert facts['defaultShellIsCmd'] and not facts['rendererUsesCmd'] and facts['rendererUsesExpectedShell']
        assert facts['rendererTimeoutIsTen'] and facts['rendererInputIsBytes'] and facts['rendererShellFalse']
finally:
    if fixture.exists():
        assert fixture.resolve().is_relative_to((root/'out').resolve()) and fixture.name.startswith('pacer-shell-check-')
        shutil.rmtree(fixture)
